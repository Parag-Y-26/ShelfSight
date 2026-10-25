import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../core/app_controller.dart';
import '../core/configuration.dart';
import '../core/standalone_repository.dart';
import '../core/temp_photo.dart';
import 'frame_encoder.dart';
import 'geometry.dart';
import 'local_tracker.dart';
import 'local_person_detector.dart';

enum MonitorPhase {
  initializing,
  calibrating,
  starting,
  waiting,
  live,
  stopped,
  unavailable,
}

class MonitoringController extends ChangeNotifier {
  MonitoringController(this.app, {PersonDetector Function()? detectorFactory})
    : _detectorFactory = detectorFactory ?? createLocalPersonDetector;
  final AppController app;
  final PersonDetector Function() _detectorFactory;
  PersonDetector? _localDetector;
  BottomCenterIoUTracker? _localTracker;
  StandaloneMobileRepository? _sessionRepository;
  Future<void>? _localFrameFuture;
  Future<void>? _localStopFuture;
  int? _localOwnerGeneration;
  CameraController? camera;
  MonitorPhase phase = MonitorPhase.initializing;
  String? errorKey;
  String? selectedShelfId;
  String? calibrationId;
  String? sessionId;
  String orientation = '';
  int frameWidth = 0, frameHeight = 0;
  bool cameraConfirmed = false;
  bool saving = false;
  List<CameraZone> zones = [];
  List<Map<String, dynamic>> tracks = [], events = [], activeVisits = [];
  double? processingMs;
  int acknowledgedFrames = 0, transmittedBytes = 0;
  DateTime? lastAck;
  Map<String, dynamic> _config = {};
  WebSocketChannel? _socket;
  StreamSubscription<dynamic>? _subscription;
  Timer? _watchdog;
  Timer? _webCaptureTimer;
  bool _capturingWeb = false;
  RawCameraFrame? _pending;
  int? _inflightSequence;
  double? _sourceAspect;
  int _sequence = 0,
      _lastCapturedAtMs = 0,
      _cameraGeneration = 0,
      _sessionGeneration = 0;
  bool _encoding = false, _disposed = false, _releasing = false;

  bool get running => sessionId != null;
  bool get changing =>
      phase == MonitorPhase.initializing ||
      phase == MonitorPhase.starting ||
      saving;
  bool get cameraReady =>
      camera?.value.isInitialized == true && frameWidth > 0 && frameHeight > 0;
  bool get calibrated => calibrationId != null && validZones(zones);
  bool get canStart =>
      cameraReady && calibrated && cameraConfirmed && !changing && !running;
  bool get providerAvailable {
    final capabilities = _config['capabilities'];
    return capabilities is Map && capabilities['visits'] == true;
  }

  Map<String, dynamic> get config => _config.isEmpty ? app.config : _config;

  double? _value(String key, [Map<String, dynamic>? shelf]) => finiteNumber(
    RuntimeConfiguration(config).resolve(
      device: app.deviceOverrides,
      store: app.store == null ? null : {'settings': app.settingsOverrides()},
      shelf:
          shelf == null
              ? null
              : {
                'settings': app.settingsOverrides(
                  shelfId: shelf['id'].toString(),
                ),
              },
    )[key],
  );

  int? get maxDimension {
    final values =
        zones
            .map(
              (zone) =>
                  app.shelves.where((s) => s['id'] == zone.shelfId).firstOrNull,
            )
            .map((shelf) => _value('frame_max_dimension', shelf))
            .whereType<double>()
            .where((v) => v > 0)
            .toList();
    if (values.isNotEmpty) return values.reduce(math.max).floor();
    final v = _value('frame_max_dimension');
    return v != null && v > 0 ? v.floor() : null;
  }

  int? get intervalMs {
    final values =
        zones
            .map(
              (zone) =>
                  app.shelves.where((s) => s['id'] == zone.shelfId).firstOrNull,
            )
            .map((shelf) => _value('monitoring_sample_fps', shelf))
            .whereType<double>()
            .where((v) => v > 0)
            .toList();
    if (values.isNotEmpty) return (1000 / values.reduce(math.max)).ceil();
    final v = _value('monitoring_sample_fps');
    return v != null && v > 0 ? (1000 / v).ceil() : null;
  }

  int? get _ackLimitMs {
    final limits = config['limits'];
    final v = finiteNumber(
      limits is Map ? limits['max_frame_age_seconds'] : null,
    );
    return v != null && v > 0 ? (v * 1000).ceil() : null;
  }

  Future<void> initialize() async {
    if (_disposed || _releasing || camera != null) return;
    final generation = ++_cameraGeneration;
    phase = MonitorPhase.initializing;
    errorKey = null;
    _config = app.config;
    _notify();
    CameraController? candidate;
    try {
      if (app.store == null) {
        phase = MonitorPhase.unavailable;
        errorKey = 'monitorNeedsStore';
        return;
      }
      final descriptions = await availableCameras();
      final back =
          descriptions
              .where((c) => c.lensDirection == CameraLensDirection.back)
              .firstOrNull ??
          (kIsWeb ? descriptions.firstOrNull : null);
      if (back == null) {
        phase = MonitorPhase.unavailable;
        errorKey = 'monitorNoRearCamera';
        return;
      }
      if (_disposed || generation != _cameraGeneration) return;
      candidate = CameraController(
        back,
        ResolutionPreset.medium,
        enableAudio: false,
        imageFormatGroup:
            defaultTargetPlatform == TargetPlatform.iOS
                ? ImageFormatGroup.bgra8888
                : ImageFormatGroup.yuv420,
      );
      await candidate.initialize();
      if (_disposed || generation != _cameraGeneration) {
        await candidate.dispose();
        return;
      }
      camera = candidate;
      orientation = candidate.value.deviceOrientation.name;
      candidate.addListener(_cameraValueChanged);
      phase = MonitorPhase.calibrating;
      if (kIsWeb) {
        await _captureWeb();
        _scheduleWebCapture();
      } else {
        await candidate.startImageStream(_onImage);
      }
    } on CameraException {
      phase = MonitorPhase.unavailable;
      errorKey = 'monitorCameraDenied';
      if (candidate != null && candidate != camera) await candidate.dispose();
    } catch (_) {
      phase = MonitorPhase.unavailable;
      errorKey = 'monitorCameraFailed';
      if (candidate != null && candidate != camera) await candidate.dispose();
    } finally {
      _notify();
    }
  }

  void _scheduleWebCapture() {
    _webCaptureTimer?.cancel();
    final interval = intervalMs;
    if (_disposed || _releasing || camera == null || interval == null) return;
    _webCaptureTimer = Timer(Duration(milliseconds: interval), () async {
      await _captureWeb();
      _scheduleWebCapture();
    });
  }

  Future<void> _captureWeb() async {
    final controller = camera;
    final maximum = maxDimension;
    if (_disposed ||
        _capturingWeb ||
        controller == null ||
        maximum == null ||
        _inflightSequence != null ||
        _encoding) {
      return;
    }
    _capturingWeb = true;
    final generation = _cameraGeneration;
    try {
      final photo = await controller.takePicture();
      final image = img.decodeImage(await consumeTempPhoto(photo.path));
      if (_disposed || generation != _cameraGeneration || image == null) return;
      final size = uprightDimensions(image.width, image.height, 0, maximum);
      final aspect = image.width / image.height;
      final changed =
          _sourceAspect != null && (_sourceAspect! - aspect).abs() > 0.01;
      _sourceAspect = aspect;
      if (changed) {
        _invalidateCalibration();
        if (running) await stop(reason: 'monitorRotationChanged');
      }
      frameWidth = size.width;
      frameHeight = size.height;
      _notify();
      if (!running || _socket == null) return;
      final resized = img.copyResize(
        image,
        width: size.width,
        height: size.height,
      );
      _pending = RawCameraFrame(
        width: resized.width,
        height: resized.height,
        planes: [
          FramePlane(
            bytes: resized.getBytes(order: img.ChannelOrder.bgra),
            rowStride: resized.width * 4,
            pixelStride: 4,
          ),
        ],
        format: 'bgra8888',
        rotation: 0,
        maxDimension: maximum,
        orientation: orientation,
        capturedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _drain();
    } catch (_) {
      if (running) await stop(reason: 'monitorCameraFailed');
    } finally {
      _capturingWeb = false;
    }
  }

  void _cameraValueChanged() {
    final value = camera?.value;
    if (value == null || !value.isInitialized || _disposed) return;
    final next = value.deviceOrientation.name;
    if (next != orientation) {
      orientation = next;
      _invalidateCalibration();
      _sourceAspect = null;
      frameWidth = frameHeight = 0;
      unawaited(stop(reason: 'monitorRotationChanged'));
    }
    if (value.hasError && running) {
      unawaited(stop(reason: 'monitorCameraFailed'));
    }
  }

  void _onImage(CameraImage image) {
    final controller = camera;
    final maxSize = maxDimension;
    if (_disposed || controller == null || maxSize == null) return;
    final rotation = uprightRotation(
      controller.description.sensorOrientation,
      orientation,
    );
    final size = uprightDimensions(
      image.width,
      image.height,
      rotation,
      maxSize,
    );
    final rawAspect =
        rotation % 180 == 0
            ? image.width / image.height
            : image.height / image.width;
    final aspectChanged =
        _sourceAspect != null && (_sourceAspect! - rawAspect).abs() > 0.000001;
    _sourceAspect = rawAspect;
    if (frameWidth != size.width || frameHeight != size.height) {
      if (aspectChanged && running) {
        unawaited(stop(reason: 'monitorRotationChanged'));
      }
      frameWidth = size.width;
      frameHeight = size.height;
      if (aspectChanged) _invalidateCalibration();
      _notify();
    }
    if (!running || (_socket == null && _localDetector == null)) return;
    final interval = intervalMs;
    if (interval == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCapturedAtMs < interval) return;
    _lastCapturedAtMs = now;
    // Copy plugin-owned buffers once. One pending raw frame is replaced by the
    // latest sample; no work queue accumulates when inference/network is slow.
    final frame = RawCameraFrame(
      width: image.width,
      height: image.height,
      format: image.format.group.name,
      rotation: rotation,
      maxDimension: maxSize,
      orientation: orientation,
      capturedAtMs: now,
      planes: image.planes
          .map(
            (p) => FramePlane(
              bytes: Uint8List.fromList(p.bytes),
              rowStride: p.bytesPerRow,
              pixelStride: p.bytesPerPixel ?? 1,
            ),
          )
          .toList(growable: false),
    );
    unawaited(submitFrame(frame));
  }

  /// Single bounded camera-buffer ingress shared by native capture and detector
  /// tests. It cannot start monitoring or write outside the calibrated session.
  Future<void> submitFrame(RawCameraFrame frame) async {
    if (_disposed || !running || frame.orientation != orientation) return;
    _pending = frame;
    if (_localDetector != null) {
      await _drainLocal();
    } else {
      await _drain();
    }
  }

  Future<void> _drainLocal() async {
    if (_disposed || _encoding || !running || _localStopFuture != null) return;
    final frame = _pending,
        detector = _localDetector,
        tracker = _localTracker,
        id = sessionId;
    final repo = _sessionRepository;
    if (frame == null ||
        detector == null ||
        tracker == null ||
        id == null ||
        repo == null) {
      return;
    }
    _pending = null;
    _encoding = true;
    final generation = _sessionGeneration,
        ownerGeneration = _localOwnerGeneration;
    Future<void> process() async {
      final clock = Stopwatch()..start();
      try {
        final thresholds =
            zones
                .map(
                  (z) =>
                      app.shelves
                          .where((s) => s['id'] == z.shelfId)
                          .firstOrNull,
                )
                .map((s) => _value('detection_confidence_threshold', s))
                .whereType<double>()
                .toList();
        final detections = await detector.detect(
          frame,
          threshold: thresholds.reduce(math.min),
        );
        final frameAge =
            DateTime.now().millisecondsSinceEpoch - frame.capturedAtMs;
        if (frameAge < 0 || (_ackLimitMs != null && frameAge > _ackLimitMs!)) {
          if (generation == _sessionGeneration) {
            unawaited(stop(reason: 'monitorAckTimeout'));
          }
          return;
        }
        if (_disposed ||
            generation != _sessionGeneration ||
            app.identityGeneration != ownerGeneration ||
            frame.orientation != orientation) {
          return;
        }
        final now = frame.capturedAtMs / 1000;
        final visits = tracker.update(detections, now);
        final recorded = await repo.recordFrame(
          id,
          visits: visits,
          active: tracker.active(),
          at: now,
          grace: (_value('tracking_grace_sec')!),
        );
        if (_disposed ||
            generation != _sessionGeneration ||
            app.identityGeneration != ownerGeneration) {
          return;
        }
        clock.stop();
        processingMs = clock.elapsedMicroseconds / 1000;
        acknowledgedFrames++;
        // All frames and inference stay in process; no cloud tokens are spent.
        transmittedBytes = 0;
        lastAck = DateTime.now();
        tracks = tracker.visible();
        activeVisits = tracker.active();
        events = [...recorded.reversed, ...events].take(1000).toList();
        phase = MonitorPhase.live;
        if (!app.monitoringActive) app.markMonitoringActive(true);
        app.frameProcessed();
        if (recorded.isNotEmpty) app.ledgerChanged();
        _notify();
      } catch (_) {
        if (generation == _sessionGeneration) {
          unawaited(stop(reason: 'monitorFrameFailed'));
        }
      } finally {
        _encoding = false;
        if (_pending != null && running && _localStopFuture == null) {
          unawaited(_drainLocal());
        }
      }
    }

    final future = process();
    _localFrameFuture = future;
    await future;
    if (identical(_localFrameFuture, future)) _localFrameFuture = null;
  }

  Future<void> _drain() async {
    if (_disposed || _encoding || _inflightSequence != null || !running) return;
    final frame = _pending;
    final socket = _socket;
    final id = sessionId;
    if (frame == null || socket == null || id == null) return;
    final generation = _sessionGeneration;
    _pending = null;
    _encoding = true;
    try {
      final encoded = await compute(encodeCameraFrame, frame);
      if (_disposed ||
          generation != _sessionGeneration ||
          socket != _socket ||
          encoded.orientation != orientation) {
        return;
      }
      final sequence = ++_sequence;
      final message = jsonEncode({
        'type': 'frame',
        'session_id': id,
        'sequence': sequence,
        'captured_at_ms': encoded.capturedAtMs,
        'orientation': encoded.orientation,
        'width': encoded.width,
        'height': encoded.height,
        'image_base64': base64Encode(encoded.jpeg),
      });
      _inflightSequence = sequence;
      transmittedBytes += utf8.encode(message).length;
      socket.sink.add(message);
    } catch (_) {
      if (generation == _sessionGeneration) {
        await stop(reason: 'monitorFrameFailed');
      }
    } finally {
      _encoding = false;
      // An ACK can arrive while the encoder future is completing.
      if (_inflightSequence == null && _pending != null && running) {
        unawaited(_drain());
      }
    }
  }

  void selectShelf(String? id) {
    selectedShelfId = id;
    _notify();
  }

  void setCameraConfirmed(bool value) {
    cameraConfirmed = value;
    _notify();
  }

  void setZone(Rect normalized) {
    if (running || selectedShelfId == null) return;
    final candidate = CameraZone(shelfId: selectedShelfId!, rect: normalized);
    final others = zones.where((z) => z.shelfId != selectedShelfId).toList();
    if (!candidate.valid || others.any(candidate.overlaps)) {
      errorKey = 'monitorZoneOverlap';
      _notify();
      return;
    }
    zones = [...others, candidate];
    calibrationId = null;
    cameraConfirmed = false;
    errorKey = null;
    _notify();
  }

  void setPolygon(List<Offset> vertices) {
    if (running || selectedShelfId == null || vertices.isEmpty) return;
    final xs = vertices.map((p) => p.dx).toList()..sort(),
        ys = vertices.map((p) => p.dy).toList()..sort();
    final zone = CameraZone(
      shelfId: selectedShelfId!,
      rect: Rect.fromLTRB(xs.first, ys.first, xs.last, ys.last),
      polygon: List.unmodifiable(vertices),
    );
    final others = zones.where((z) => z.shelfId != selectedShelfId).toList();
    if (!zone.valid || others.any(zone.overlaps)) {
      errorKey = 'invalidZone';
      _notify();
      return;
    }
    zones = [...others, zone];
    calibrationId = null;
    cameraConfirmed = false;
    errorKey = null;
    _notify();
  }

  void removeZone() {
    if (running) return;
    zones = zones.where((z) => z.shelfId != selectedShelfId).toList();
    calibrationId = null;
    cameraConfirmed = false;
    _notify();
  }

  void resetCalibration() {
    if (running) return;
    _invalidateCalibration();
    errorKey = null;
    phase = MonitorPhase.calibrating;
    _notify();
  }

  void _invalidateCalibration() {
    calibrationId = null;
    zones = [];
    cameraConfirmed = false;
  }

  Future<void> saveCalibration() async {
    final storeId = app.store?['id'];
    if (storeId == null ||
        !cameraReady ||
        !validZones(zones) ||
        running ||
        saving) {
      return;
    }
    saving = true;
    errorKey = null;
    final savedOrientation = orientation;
    final savedWidth = frameWidth, savedHeight = frameHeight;
    final ownerGeneration = app.identityGeneration;
    final repository = app.repository;
    final savedZones = List<CameraZone>.from(zones);
    _notify();
    try {
      final data = await repository.post('/stores/$storeId/calibrations', {
        'orientation': savedOrientation,
        'frame_width': savedWidth,
        'frame_height': savedHeight,
        'zones': savedZones.map((z) => z.toJson()).toList(),
      });
      if (_disposed ||
          ownerGeneration != app.identityGeneration ||
          app.store?['id'] != storeId ||
          orientation != savedOrientation ||
          frameWidth != savedWidth ||
          frameHeight != savedHeight ||
          !listEquals(savedZones, zones)) {
        return;
      }
      if (data is! Map || data['id'] is! String) throw const FormatException();
      calibrationId = data['id'] as String;
      cameraConfirmed = false;
      await app.refresh();
    } catch (_) {
      errorKey = 'monitorCalibrationFailed';
    } finally {
      saving = false;
      _notify();
    }
  }

  Future<void> start() async {
    if (!canStart) return;
    if (app.isStandalone) {
      await _startLocal();
      return;
    }
    if (!app.canUseRemoteMonitoring(zones.map((zone) => zone.shelfId))) {
      errorKey = 'standaloneUnavailable';
      _notify();
      return;
    }
    final storeId = app.store?['id'];
    if (storeId == null) return;
    final savedCalibration = calibrationId;
    final savedOrientation = orientation;
    phase = MonitorPhase.starting;
    errorKey = null;
    final generation = ++_sessionGeneration;
    _notify();
    try {
      final configuration = await app.repository.get('/config');
      if (configuration is! Map) throw const FormatException();
      _config = Map<String, dynamic>.from(configuration);
      if (!providerAvailable) {
        phase = MonitorPhase.unavailable;
        errorKey = 'monitorDetectorUnavailable';
        return;
      }
      final interval = intervalMs, ackLimit = _ackLimitMs;
      if (interval == null || ackLimit == null || maxDimension == null) {
        throw const FormatException();
      }
      if (_disposed ||
          generation != _sessionGeneration ||
          savedCalibration != calibrationId ||
          savedOrientation != orientation) {
        return;
      }
      final data = await app.repository.post('/stores/$storeId/monitoring', {
        'calibration_id': savedCalibration,
        ...app.monitoringSettings,
      });
      if (data is! Map || data['id'] is! String) throw const FormatException();
      final id = data['id'] as String;
      if (_disposed ||
          generation != _sessionGeneration ||
          savedCalibration != calibrationId ||
          savedOrientation != orientation) {
        try {
          await app.repository.post('/monitoring/$id/stop');
        } catch (_) {
          /* server closes on disconnect */
        }
        return;
      }
      sessionId = id;
      final socket = await app.repository.openSocket('/monitoring/$id/stream');
      if (_disposed || generation != _sessionGeneration) {
        await socket.sink.close(1001);
        return;
      }
      _socket = socket;
      _sequence = 0;
      _inflightSequence = null;
      _pending = null;
      tracks = [];
      activeVisits = [];
      lastAck = null;
      processingMs = null;
      acknowledgedFrames = transmittedBytes = 0;
      _lastCapturedAtMs = 0;
      phase = MonitorPhase.waiting;
      final opened = DateTime.now();
      _subscription = socket.stream.listen(
        (dynamic message) => _onMessage(message, generation),
        onDone: () {
          if (generation == _sessionGeneration) {
            unawaited(stop(reason: 'monitorDisconnected'));
          }
        },
        onError: (Object _) {
          if (generation == _sessionGeneration) {
            unawaited(stop(reason: 'monitorDisconnected'));
          }
        },
        cancelOnError: true,
      );
      _watchdog = Timer.periodic(Duration(milliseconds: interval), (_) {
        if (_disposed || generation != _sessionGeneration) return;
        if (DateTime.now().difference(lastAck ?? opened).inMilliseconds >
            ackLimit) {
          unawaited(stop(reason: 'monitorAckTimeout'));
        }
      });
    } catch (_) {
      if (generation == _sessionGeneration) {
        await stop(reason: 'monitorStartFailed');
      }
    } finally {
      _notify();
    }
  }

  Future<void> _startLocal() async {
    final storeId = app.store?['id']?.toString();
    if (storeId == null || kIsWeb) return;
    if (zones.any(
      (z) =>
          app.effectiveSettings(
            app.shelves.where((s) => s['id'] == z.shelfId).firstOrNull,
          )['execution_mode'] !=
          'standalone_mobile',
    )) {
      errorKey = 'localModeMismatch';
      _notify();
      return;
    }
    phase = MonitorPhase.starting;
    errorKey = null;
    final generation = ++_sessionGeneration, owner = app.identityGeneration;
    final savedCalibration = calibrationId;
    final repo = app.localRepository;
    String? createdSessionId;
    _notify();
    try {
      if (_localStopFuture != null) await _localStopFuture;
      final data = await repo.post('/stores/$storeId/monitoring', {
        'calibration_id': savedCalibration,
        ...app.monitoringSettings,
      });
      createdSessionId = data['id'].toString();
      if (_disposed ||
          generation != _sessionGeneration ||
          savedCalibration != calibrationId ||
          owner != app.identityGeneration) {
        await repo.post('/monitoring/${data['id']}/stop');
        return;
      }
      _localDetector = _detectorFactory();
      _localTracker = BottomCenterIoUTracker(
        zones: List.unmodifiable(zones),
        defaults: app.effectiveSettings(),
        shelfSettings: {
          for (final s in app.shelves)
            s['id'].toString(): app.effectiveSettings(s),
        },
      );
      _sessionRepository = repo;
      _localOwnerGeneration = owner;
      sessionId = data['id'];
      _sequence = 0;
      _lastCapturedAtMs = 0;
      _pending = null;
      tracks = [];
      events = [];
      activeVisits = [];
      processingMs = null;
      lastAck = null;
      acknowledgedFrames = transmittedBytes = 0;
      phase = MonitorPhase.waiting;
      app.markMonitoringActive(true);
      final opened = DateTime.now();
      _watchdog = Timer.periodic(Duration(milliseconds: intervalMs!), (_) {
        if (!_disposed &&
            generation == _sessionGeneration &&
            DateTime.now().difference(lastAck ?? opened).inMilliseconds >
                (_ackLimitMs!)) {
          unawaited(stop(reason: 'monitorAckTimeout'));
        }
      });
    } catch (_) {
      if (createdSessionId != null) {
        try {
          await repo.post('/monitoring/$createdSessionId/stop');
        } catch (_) {}
      }
      if (generation == _sessionGeneration) {
        try {
          await _localDetector?.close();
        } catch (_) {}
        _localDetector = null;
        _localTracker = null;
        _sessionRepository = null;
        sessionId = null;
        _watchdog?.cancel();
        _watchdog = null;
        if (app.monitoringActive) app.markMonitoringActive(false);
        phase = MonitorPhase.unavailable;
        errorKey = 'monitorStartFailed';
      }
    }
    _notify();
  }

  void _onMessage(dynamic message, int generation) {
    if (_disposed || generation != _sessionGeneration || message is! String) {
      return;
    }
    try {
      final data = jsonDecode(message);
      if (data is! Map ||
          data['type'] != 'ack' ||
          data['sequence'] != _inflightSequence ||
          _inflightSequence == null) {
        if (data is Map && data['type'] == 'error') {
          unawaited(stop(reason: 'monitorServerRejected'));
        }
        return;
      }
      final ms = finiteNumber(data['processing_ms']);
      if (ms == null ||
          ms < 0 ||
          data['tracks'] is! List ||
          data['events'] is! List) {
        unawaited(stop(reason: 'monitorServerRejected'));
        return;
      }
      _inflightSequence = null;
      if (data['skipped'] == true || data['duplicate'] == true) {
        unawaited(_drain());
        return;
      }
      lastAck = DateTime.now();
      processingMs = ms;
      acknowledgedFrames++;
      tracks = _maps(data['tracks']);
      activeVisits = _maps(data['active_visits']);
      final received = _maps(data['events']);
      final storeId = app.store?['id']?.toString();
      if (storeId != null) {
        unawaited(
          app.cache.recordEvents(storeId, received).catchError((Object _) {}),
        );
      }
      final ids = events.map((e) => e['id']).toSet();
      events = [
        ...received.where((e) => e['id'] is String && ids.add(e['id'])),
        ...events,
      ];
      phase = MonitorPhase.live;
      if (!app.monitoringActive) app.markMonitoringActive(true);
      app.frameProcessed();
      if (received.isNotEmpty) app.ledgerChanged();
      _notify();
      unawaited(_drain());
    } catch (_) {
      unawaited(stop(reason: 'monitorServerRejected'));
    }
  }

  static List<Map<String, dynamic>> _maps(dynamic value) =>
      value is List
          ? value
              .whereType<Map>()
              .map((m) => Map<String, dynamic>.from(m))
              .toList()
          : [];

  Future<void> stop({String? reason}) async {
    app.framesStopped();
    if (_localStopFuture != null) {
      await _localStopFuture;
      return;
    }
    if (_localDetector != null || _localTracker != null) {
      final future = _stopLocal(reason: reason);
      _localStopFuture = future;
      try {
        await future;
      } finally {
        _localStopFuture = null;
      }
      return;
    }
    ++_sessionGeneration;
    final id = sessionId;
    final socket = _socket;
    final subscription = _subscription;
    sessionId = null;
    _socket = null;
    _subscription = null;
    _watchdog?.cancel();
    _watchdog = null;
    _pending = null;
    _inflightSequence = null;
    tracks = [];
    activeVisits = [];
    if (app.monitoringActive) app.markMonitoringActive(false);
    if (!_disposed) {
      phase = MonitorPhase.stopped;
      errorKey = reason;
      _notify();
    }
    final timeout = Duration(milliseconds: _ackLimitMs ?? 0);
    // A deliberate stop is finalized by HTTP first. Unexpected interruption
    // closes the stream first so a failed HTTP call cannot bridge a time gap.
    if (id != null && reason == null) {
      try {
        await app.repository.post('/monitoring/$id/stop').timeout(timeout);
      } catch (_) {
        if (!_disposed) errorKey = 'monitorStopUnconfirmed';
      }
    }
    await subscription?.cancel();
    try {
      await socket?.sink.close(1000).timeout(timeout);
    } catch (_) {}
    if (id != null) {
      try {
        if (reason != null) {
          await app.repository.post('/monitoring/$id/stop').timeout(timeout);
        }
        if (!_disposed) await loadEvents();
      } catch (_) {
        /* disconnection has already finalized observations */
      }
    }
    _notify();
  }

  Future<void> _stopLocal({String? reason}) async {
    ++_sessionGeneration;
    _watchdog?.cancel();
    _watchdog = null;
    final id = sessionId, repo = _sessionRepository, detector = _localDetector;
    sessionId = null;
    _pending = null;
    _localDetector = null;
    _localTracker = null;
    _sessionRepository = null;
    // Serialize with any ledger commit already in progress before finalizing.
    await _localFrameFuture;
    try {
      if (id != null && repo != null) await repo.post('/monitoring/$id/stop');
      app.ledgerChanged();
      if (!_disposed) await loadEvents();
    } catch (_) {
      if (!_disposed) errorKey = 'monitorStopUnconfirmed';
    }
    try {
      await detector?.close();
    } catch (_) {
      if (!_disposed) {
        errorKey ??= 'monitorFrameFailed';
      }
    }
    tracks = [];
    activeVisits = [];
    if (app.monitoringActive) app.markMonitoringActive(false);
    if (!_disposed) {
      phase = MonitorPhase.stopped;
      errorKey ??= reason;
      _notify();
    }
  }

  Future<void> loadEvents() async {
    final id = app.store?['id'];
    if (id == null) return;
    try {
      final result = await app.repository.get('/stores/$id/events');
      if (_disposed || result is! Map) return;
      events = _maps(result['items']).reversed.toList();
      _notify();
    } catch (_) {
      /* the live event list stays visible when offline */
    }
  }

  Future<void> suspend() async {
    if (_releasing) return;
    _releasing = true;
    _webCaptureTimer?.cancel();
    _webCaptureTimer = null;
    ++_cameraGeneration;
    _invalidateCalibration();
    _sourceAspect = null;
    frameWidth = frameHeight = 0;
    final oldCamera = camera;
    camera = null;
    oldCamera?.removeListener(_cameraValueChanged);
    // Release the camera promptly even while the network stop is pending.
    final stopFuture = stop(reason: 'monitorBackgroundStopped');
    try {
      if (oldCamera?.value.isStreamingImages == true) {
        await oldCamera?.stopImageStream();
      }
      await oldCamera?.dispose();
    } catch (_) {
      /* camera may already have been reclaimed by Android */
    }
    _releasing = false;
    _notify();
    // HTTP finalization may fail while offline. It must not delay resuming the
    // camera after Android returns to the foreground.
    unawaited(stopFuture);
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(suspend());
    super.dispose();
  }
}
