import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../vision/geometry.dart';
import '../vision/monitoring_controller.dart';
import '../widgets/shared.dart';
import '../widgets/evaluation_replay.dart';
import '../widgets/zone_editor.dart';

class MonitoringScreen extends ConsumerStatefulWidget {
  const MonitoringScreen({super.key});
  @override
  ConsumerState<MonitoringScreen> createState() => _MonitoringScreenState();
}

class _MonitoringScreenState extends ConsumerState<MonitoringScreen>
    with WidgetsBindingObserver {
  late final MonitoringController _model;
  Offset? _drawStart;
  Rect? _draft;
  bool _polygonMode = false;
  final _points = <Offset>[];
  Future<void>? _suspending;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _model = MonitoringController(ref.read(appControllerProvider))
      ..addListener(_changed);
    unawaited(_model.initialize());
    unawaited(_model.loadEvents());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (!_foreground) {
      _drawStart = null;
      _draft = null;
      _points.clear();
      _suspending ??= _model.suspend().whenComplete(() {
        _suspending = null;
      });
    } else {
      final pending = _suspending;
      if (pending != null) {
        unawaited(
          pending.then((_) {
            if (mounted && _foreground) unawaited(_model.initialize());
          }),
        );
      } else {
        unawaited(_model.initialize());
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _model.removeListener(_changed);
    _model.dispose();
    super.dispose();
  }

  String _number(num value) => NumberFormat.decimalPattern(
    Localizations.localeOf(context).toLanguageTag(),
  ).format(value);

  String _shelfName(String id) =>
      ref
          .read(appControllerProvider)
          .shelves
          .where((s) => s['id'] == id)
          .firstOrNull?['name']
          ?.toString() ??
      tr(context, 'monitorRemovedShelf');

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final model = _model;
    final live = model.phase == MonitorPhase.live && app.monitoringLive;
    final status = switch (model.phase) {
      MonitorPhase.initializing => 'monitorInitializing',
      MonitorPhase.calibrating => 'monitorCalibrationState',
      MonitorPhase.starting => 'monitorStarting',
      MonitorPhase.waiting => 'monitorWaiting',
      MonitorPhase.live => live ? 'monitorLive' : 'monitorStopped',
      MonitorPhase.stopped => 'monitorStopped',
      MonitorPhase.unavailable => 'monitorUnavailable',
    };
    return PageScaffold(
      title: tr(context, 'monitorTitle'),
      actions: [
        IconButton(
          tooltip: tr(context, 'monitorRefreshEvents'),
          onPressed: () => unawaited(model.loadEvents()),
          icon: const Icon(Icons.refresh),
        ),
      ],
      bottom: BrandButton(
        label: tr(context, model.running ? 'monitorStop' : 'monitorStart'),
        icon:
            model.running
                ? Icons.stop_circle_outlined
                : Icons.play_arrow_rounded,
        onPressed:
            model.running
                ? () => unawaited(model.stop())
                : model.canStart
                ? () => unawaited(model.start())
                : null,
      ),
      child: ListView(
        padding: const EdgeInsets.all(Tokens.md),
        children: [
          const EvaluationReplayCard(),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      live ? Icons.sensors : Icons.sensors_off,
                      color: live ? Tokens.teal : Tokens.muted,
                    ),
                    const SizedBox(width: Tokens.sm),
                    Expanded(
                      child: Text(
                        tr(context, status),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                    if (model.changing)
                      const SizedBox(
                        width: Tokens.lg,
                        height: Tokens.lg,
                        child: CircularProgressIndicator(
                          strokeWidth: Tokens.xs / 2,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: Tokens.sm),
                Text(
                  tr(
                    context,
                    app.isStandalone ? 'localMonitorPrivacy' : 'monitorPrivacy',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (model.errorKey != null)
                  ErrorNotice(message: tr(context, model.errorKey!)),
                if (model.camera?.value.isInitialized == true) ...[
                  const SizedBox(height: Tokens.md),
                  _preview(),
                ] else ...[
                  EmptyState(
                    message: tr(context, 'monitorCameraEmpty'),
                    icon: Icons.videocam_outlined,
                  ),
                  if (!model.changing && app.store != null)
                    BrandButton(
                      label: tr(context, 'monitorRetryCamera'),
                      icon: Icons.videocam,
                      onPressed:
                          () => unawaited(
                            model.suspend().then((_) => model.initialize()),
                          ),
                      outlined: true,
                    ),
                ],
                if (model.frameWidth > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: Tokens.sm),
                    child: Text(
                      tr(context, 'monitorCaptureInfo', {
                        'width': _number(model.frameWidth),
                        'height': _number(model.frameHeight),
                        'interval':
                            model.intervalMs == null
                                ? tr(context, 'monitorUnknown')
                                : _number(model.intervalMs!),
                      }),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          if (app.shelves.isNotEmpty && !model.running)
            InfoCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'monitorCalibrate'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: Tokens.sm),
                  Text(tr(context, 'monitorCalibrationHelp')),
                  Wrap(
                    spacing: Tokens.sm,
                    runSpacing: Tokens.sm,
                    children: [
                      ChoiceChip(
                        label: Text(tr(context, 'rectangleZone')),
                        selected: !_polygonMode,
                        onSelected:
                            model.running
                                ? null
                                : (_) => setState(() {
                                  _polygonMode = false;
                                  _points.clear();
                                }),
                      ),
                      ChoiceChip(
                        label: Text(tr(context, 'polygonZone')),
                        selected: _polygonMode,
                        onSelected:
                            model.running
                                ? null
                                : (_) => setState(() {
                                  _polygonMode = true;
                                  _points.clear();
                                }),
                      ),
                      TextButton.icon(
                        onPressed:
                            model.running || model.selectedShelfId == null
                                ? null
                                : () => editCameraZone(
                                  context,
                                  model,
                                  polygon: _polygonMode,
                                ),
                        icon: const Icon(Icons.edit_outlined),
                        label: Text(tr(context, 'manualZone')),
                      ),
                      if (_polygonMode)
                        TextButton(
                          onPressed:
                              model.running || _points.length < 3
                                  ? null
                                  : () {
                                    model.setPolygon(_points);
                                    if (model.errorKey == null) {
                                      setState(_points.clear);
                                    }
                                  },
                          child: Text(tr(context, 'finishPolygon')),
                        ),
                      if (_polygonMode)
                        TextButton(
                          onPressed:
                              model.running || _points.isEmpty
                                  ? null
                                  : () => setState(_points.removeLast),
                          child: Text(tr(context, 'undoVertex')),
                        ),
                    ],
                  ),
                  if (_polygonMode) Text(tr(context, 'polygonHelp')),
                  const SizedBox(height: Tokens.md),
                  DropdownButtonFormField<String>(
                    initialValue:
                        app.shelves.any((s) => s['id'] == model.selectedShelfId)
                            ? model.selectedShelfId
                            : null,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: tr(context, 'monitorSelectShelf'),
                    ),
                    items:
                        app.shelves
                            .map(
                              (s) => DropdownMenuItem<String>(
                                value: s['id'].toString(),
                                child: Text(
                                  s['name']?.toString() ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                    onChanged:
                        model.saving
                            ? null
                            : (id) {
                              setState(_points.clear);
                              model.selectShelf(id);
                            },
                  ),
                  const SizedBox(height: Tokens.sm),
                  Text(
                    tr(context, 'monitorZoneCount', {
                      'count': _number(model.zones.length),
                    }),
                  ),
                  if (model.zones.isNotEmpty)
                    Wrap(
                      spacing: Tokens.sm,
                      runSpacing: Tokens.xs,
                      children:
                          model.zones
                              .map(
                                (zone) => InputChip(
                                  label: Text(_shelfName(zone.shelfId)),
                                  selected:
                                      zone.shelfId == model.selectedShelfId,
                                  onSelected:
                                      (_) => model.selectShelf(zone.shelfId),
                                  onDeleted:
                                      model.saving
                                          ? null
                                          : () {
                                            model.selectShelf(zone.shelfId);
                                            model.removeZone();
                                          },
                                  deleteButtonTooltipMessage: tr(
                                    context,
                                    'monitorRemoveZone',
                                  ),
                                ),
                              )
                              .toList(),
                    ),
                  const SizedBox(height: Tokens.md),
                  BrandButton(
                    label: tr(
                      context,
                      model.calibrated
                          ? 'monitorCalibrationSaved'
                          : 'monitorSaveCalibration',
                    ),
                    icon:
                        model.calibrated
                            ? Icons.check_circle_outline
                            : Icons.save_outlined,
                    onPressed:
                        model.cameraReady &&
                                validZones(model.zones) &&
                                !model.saving &&
                                !model.calibrated
                            ? () => unawaited(model.saveCalibration())
                            : null,
                  ),
                  if (model.calibrated)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: model.cameraConfirmed,
                      onChanged:
                          (value) => model.setCameraConfirmed(value ?? false),
                      title: Text(tr(context, 'monitorCameraFixed')),
                      subtitle: Text(tr(context, 'monitorRecalibrateMoved')),
                    ),
                  TextButton.icon(
                    onPressed:
                        model.saving
                            ? null
                            : () {
                              setState(_points.clear);
                              model.resetCalibration();
                            },
                    icon: const Icon(Icons.crop_free),
                    label: Text(tr(context, 'monitorResetCalibration')),
                  ),
                ],
              ),
            ),
          if (app.shelves.isEmpty)
            InfoCard(
              child: EmptyState(
                message: tr(context, 'monitorNeedsShelves'),
                icon: Icons.shelves,
              ),
            ),
          if (model.acknowledgedFrames > 0)
            InfoCard(
              child: Wrap(
                spacing: Tokens.lg,
                runSpacing: Tokens.md,
                children: [
                  _MeasuredValue(
                    label: tr(context, 'monitorProcessed'),
                    value: _number(model.acknowledgedFrames),
                  ),
                  _MeasuredValue(
                    label: tr(context, 'monitorLatency'),
                    value: tr(context, 'monitorMilliseconds', {
                      'value': _number(model.processingMs ?? 0),
                    }),
                  ),
                  _MeasuredValue(
                    label: tr(context, 'monitorTransferred'),
                    value: tr(context, 'monitorKilobytes', {
                      'value': _number(model.transmittedBytes / 1024),
                    }),
                  ),
                ],
              ),
            ),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'monitorCurrentVisits'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (model.activeVisits.isEmpty)
                  EmptyState(message: tr(context, 'monitorNoActiveVisits')),
                for (final visit in model.activeVisits)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(
                      Icons.person_pin_circle_outlined,
                      color: Tokens.teal,
                    ),
                    title: Text(
                      _shelfName(visit['shelf_id']?.toString() ?? ''),
                    ),
                    subtitle: Text(tr(context, 'monitorAnonymous')),
                    trailing: Text(
                      tr(context, 'monitorSeconds', {
                        'value': _number(
                          finiteNumber(visit['dwell_seconds']) ?? 0,
                        ),
                      }),
                    ),
                  ),
              ],
            ),
          ),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'monitorEvents'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  tr(context, 'monitorEventsHelp'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (model.events.isEmpty)
                  EmptyState(message: tr(context, 'monitorNoEvents')),
                for (final event in model.events)
                  _EventRow(
                    event: event,
                    shelfName: _shelfName(event['shelf_id']?.toString() ?? ''),
                    number: _number,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    final camera = _model.camera!;
    final aspectRatio =
        _model.frameWidth > 0 && _model.frameHeight > 0
            ? _model.frameWidth / _model.frameHeight
            : camera.value.aspectRatio;
    final drawEnabled =
        !_model.running && !_model.changing && _model.selectedShelfId != null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(Tokens.md),
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: LayoutBuilder(
          builder: (context, constraints) {
            Offset point(Offset local) => Offset(
              (local.dx / constraints.maxWidth).clamp(0.0, 1.0),
              (local.dy / constraints.maxHeight).clamp(0.0, 1.0),
            );
            return Stack(
              fit: StackFit.expand,
              children: [
                CameraPreview(camera),
                Semantics(
                  label: tr(context, 'monitorPreviewSemantics'),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown:
                        drawEnabled && _polygonMode
                            ? (details) {
                              if (_points.length < 32) {
                                setState(
                                  () =>
                                      _points.add(point(details.localPosition)),
                                );
                              }
                            }
                            : null,
                    onPanStart:
                        drawEnabled && !_polygonMode
                            ? (details) {
                              _drawStart = point(details.localPosition);
                              setState(() {
                                _draft = null;
                              });
                            }
                            : null,
                    onPanUpdate:
                        drawEnabled && !_polygonMode
                            ? (details) {
                              final start = _drawStart;
                              if (start == null) return;
                              setState(() {
                                _draft = Rect.fromPoints(
                                  start,
                                  point(details.localPosition),
                                );
                              });
                            }
                            : null,
                    onPanEnd:
                        drawEnabled && !_polygonMode
                            ? (_) {
                              final draft = _draft;
                              _drawStart = null;
                              setState(() {
                                _draft = null;
                              });
                              if (draft != null &&
                                  draft.width > 0 &&
                                  draft.height > 0) {
                                _model.setZone(draft);
                              }
                            }
                            : null,
                    onPanCancel: () {
                      _drawStart = null;
                      setState(() {
                        _draft = null;
                      });
                    },
                    child: CustomPaint(
                      painter: _CameraOverlay(
                        draftPoints: _points.toList(),
                        zones: _model.zones,
                        draft: _draft,
                        selectedShelfId: _model.selectedShelfId,
                        names: {
                          for (final shelf in _model.app.shelves)
                            shelf['id'].toString():
                                shelf['name']?.toString() ?? '',
                        },
                        tracks: _model.tracks,
                        trackLabel:
                            (id) => tr(context, 'monitorTrack', {'id': id}),
                        textStyle:
                            Theme.of(context).textTheme.labelSmall ??
                            const TextStyle(),
                      ),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _MeasuredValue extends StatelessWidget {
  const _MeasuredValue({required this.label, required this.value});
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.bodySmall),
      Text(
        value,
        style: Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(color: Tokens.teal),
      ),
    ],
  );
}

class _EventRow extends StatelessWidget {
  const _EventRow({
    required this.event,
    required this.shelfName,
    required this.number,
  });
  final Map<String, dynamic> event;
  final String shelfName;
  final String Function(num) number;
  @override
  Widget build(BuildContext context) {
    final type = event['type'];
    final label = switch (type) {
      'visit' => 'monitorVisitEvent',
      'coverage' => 'monitorCoverageEvent',
      'inventory_adjustment' => 'monitorInventoryEvent',
      _ => 'monitorRecordedEvent',
    };
    final rawTime = event['ended_at'] ?? event['server_timestamp'];
    final timestamp = rawTime is String ? DateTime.tryParse(rawTime) : null;
    final locale = Localizations.localeOf(context).toLanguageTag();
    final time =
        timestamp == null
            ? tr(context, 'monitorUnknown')
            : DateFormat.yMd(locale).add_jm().format(timestamp.toLocal());
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        event['incomplete'] == true
            ? Icons.history_toggle_off
            : Icons.check_circle_outline,
        color: event['incomplete'] == true ? Tokens.warning : Tokens.teal,
      ),
      title: Text(tr(context, label, {'shelf': shelfName})),
      subtitle: Text(
        tr(
          context,
          event['incomplete'] == true
              ? 'monitorEventIncomplete'
              : 'monitorEventTime',
          {'time': time},
        ),
      ),
      trailing:
          type == 'visit' && finiteNumber(event['dwell_seconds']) != null
              ? Text(
                tr(context, 'monitorSeconds', {
                  'value': number(finiteNumber(event['dwell_seconds'])!),
                }),
              )
              : null,
    );
  }
}

class _CameraOverlay extends CustomPainter {
  const _CameraOverlay({
    this.draftPoints = const [],
    required this.zones,
    required this.draft,
    required this.selectedShelfId,
    required this.names,
    required this.tracks,
    required this.trackLabel,
    required this.textStyle,
  });
  final List<CameraZone> zones;
  final List<Offset> draftPoints;
  final Rect? draft;
  final String? selectedShelfId;
  final Map<String, String> names;
  final List<Map<String, dynamic>> tracks;
  final String Function(String) trackLabel;
  final TextStyle textStyle;

  @override
  void paint(Canvas canvas, Size size) {
    Rect pixels(Rect r) => Rect.fromLTWH(
      r.left * size.width,
      r.top * size.height,
      r.width * size.width,
      r.height * size.height,
    );
    for (final zone in zones) {
      final rect = pixels(zone.rect);
      final path =
          Path()..addPolygon([
            for (final p in zone.vertices)
              Offset(p.dx * size.width, p.dy * size.height),
          ], true);
      canvas.drawPath(
        path,
        Paint()..color = Tokens.teal.withValues(alpha: 0.16),
      );
      canvas.drawPath(
        path,
        Paint()
          ..color = Tokens.teal
          ..style = PaintingStyle.stroke
          ..strokeWidth =
              zone.shelfId == selectedShelfId ? Tokens.xs : Tokens.xs / 2,
      );
      _label(
        canvas,
        rect.topLeft,
        names[zone.shelfId] ?? '',
        Tokens.teal,
        size,
      );
    }
    if (draft != null) {
      canvas.drawRect(
        pixels(draft!),
        Paint()
          ..color = Tokens.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = Tokens.xs / 2,
      );
    }
    if (draftPoints.isNotEmpty) {
      final path =
          Path()..addPolygon([
            for (final p in draftPoints)
              Offset(p.dx * size.width, p.dy * size.height),
          ], false);
      canvas.drawPath(
        path,
        Paint()
          ..color = Tokens.warning
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );
      for (final p in draftPoints) {
        canvas.drawCircle(
          Offset(p.dx * size.width, p.dy * size.height),
          4,
          Paint()..color = Tokens.warning,
        );
      }
    }
    for (final track in tracks) {
      final box = track['bbox'];
      if (box is! List || box.length != 4) continue;
      final values = box.map(finiteNumber).toList();
      if (values.any((v) => v == null || v < 0 || v > 1)) continue;
      final rect = pixels(
        Rect.fromLTRB(values[0]!, values[1]!, values[2]!, values[3]!),
      );
      if (rect.width <= 0 || rect.height <= 0) continue;
      final bottomCenter = Offset(rect.center.dx, rect.bottom);
      canvas.drawCircle(bottomCenter, 6, Paint()..color = Tokens.navy);
      canvas.drawCircle(bottomCenter, 4, Paint()..color = Tokens.surface);
      canvas.drawRect(
        rect,
        Paint()
          ..color = Tokens.blue
          ..style = PaintingStyle.stroke
          ..strokeWidth = Tokens.xs / 2,
      );
      _label(
        canvas,
        rect.topLeft,
        trackLabel(track['id']?.toString() ?? ''),
        Tokens.blue,
        size,
      );
    }
  }

  void _label(
    Canvas canvas,
    Offset point,
    String label,
    Color color,
    Size size,
  ) {
    final text = TextPainter(
      text: TextSpan(
        text: label,
        style: textStyle.copyWith(color: Tokens.surface),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '\u2026',
    )..layout(maxWidth: size.width - point.dx);
    final background = Rect.fromLTWH(
      point.dx,
      point.dy,
      text.width + Tokens.sm,
      text.height + Tokens.sm,
    );
    canvas.drawRect(background, Paint()..color = color);
    text.paint(canvas, point + const Offset(Tokens.xs, Tokens.xs));
  }

  @override
  bool shouldRepaint(covariant _CameraOverlay old) => true;
}
