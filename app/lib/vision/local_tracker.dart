import 'dart:math' as math;
import 'dart:ui';
import 'geometry.dart';

class PersonDetection {
  const PersonDetection(this.bbox, this.confidence);
  final Rect bbox;
  final double confidence;
  bool get valid =>
      confidence.isFinite &&
      confidence >= 0 &&
      confidence <= 1 &&
      bbox.left >= 0 &&
      bbox.top >= 0 &&
      bbox.right <= 1 &&
      bbox.bottom <= 1 &&
      bbox.width > 0 &&
      bbox.height > 0;
}

class _Track {
  _Track(this.id, this.bbox, this.lastSeen);
  final int id;
  Rect bbox;
  double lastSeen;
  String? shelf;
  double? entered, zoneLastSeen;
}

/// Port of the server ZoneTracker: anonymous IDs, bottom-center zone matching,
/// conservative dwell, greedy IoU/distance association and gap expiry BEFORE
/// association. Time is UTC epoch seconds; no unseen gap adds dwell.
class BottomCenterIoUTracker {
  BottomCenterIoUTracker({
    required this.zones,
    required this.defaults,
    this.shelfSettings = const {},
  }) {
    if (!validZones(zones)) throw ArgumentError('Invalid calibration zones');
  }
  final List<CameraZone> zones;
  final Map<String, dynamic> defaults;
  final Map<String, Map<String, dynamic>> shelfSettings;
  final _tracks = <int, _Track>{};
  final _observed = <int>{};
  int _nextId = 0;
  double? _lastTime;
  Map<String, dynamic> _settings(String? shelf) =>
      shelfSettings[shelf] ?? defaults;
  double _number(String? shelf, String key) =>
      (_settings(shelf)[key] as num).toDouble();
  Map<String, dynamic>? _end(_Track t, bool incomplete) {
    Map<String, dynamic>? result;
    if (t.shelf != null && t.entered != null && t.zoneLastSeen != null) {
      final duration = math.max(0.0, t.zoneLastSeen! - t.entered!);
      if (duration >= _number(t.shelf, 'dwell_cutoff_sec')) {
        String stamp(double s) =>
            DateTime.fromMillisecondsSinceEpoch(
              (s * 1000).round(),
              isUtc: true,
            ).toIso8601String();
        result = {
          'track_id': t.id,
          'shelf_id': t.shelf,
          'started_at': stamp(t.entered!),
          'ended_at': stamp(t.zoneLastSeen!),
          'dwell_seconds': duration,
          'incomplete': incomplete,
          'is_incomplete': incomplete,
        };
      }
    }
    t.shelf = null;
    t.entered = null;
    t.zoneLastSeen = null;
    return result;
  }

  String? _zone(PersonDetection d) {
    final point = Offset(d.bbox.center.dx, d.bbox.bottom);
    for (final z in zones) {
      // Rect.contains excludes right/bottom; calibrated bounds are inclusive.
      if (point.dx >= z.rect.left &&
          point.dx <= z.rect.right &&
          point.dy >= z.rect.top &&
          point.dy <= z.rect.bottom &&
          d.confidence >=
              _number(z.shelfId, 'detection_confidence_threshold')) {
        return z.shelfId;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> update(List<PersonDetection> input, double now) {
    if (!now.isFinite || (_lastTime != null && now < _lastTime!)) {
      throw ArgumentError('Non-monotonic observation');
    }
    _lastTime = now;
    final detections = input.where((d) => d.valid).toList();
    final events = <Map<String, dynamic>>[];
    for (final t in _tracks.values.toList()) {
      if (now - t.lastSeen > _number(t.shelf, 'tracking_grace_sec')) {
        final e = _end(t, true);
        if (e != null) events.add(e);
        _tracks.remove(t.id);
      }
    }
    final matches = <({double cost, int id, int index})>[];
    for (final t in _tracks.values) {
      for (var i = 0; i < detections.length; i++) {
        final b = detections[i].bbox;
        final intersection = t.bbox.intersect(b);
        final overlap =
            intersection.width > 0 && intersection.height > 0
                ? intersection.width * intersection.height
                : 0.0;
        final union =
            t.bbox.width * t.bbox.height + b.width * b.height - overlap;
        final iou = union > 0 ? overlap / union : 0.0;
        final distance = (t.bbox.center - b.center).distance;
        if (iou >= _number(t.shelf, 'tracker_min_iou') ||
            distance <= _number(t.shelf, 'tracker_match_distance')) {
          matches.add((cost: distance - iou, id: t.id, index: i));
        }
      }
    }
    matches.sort((a, b) {
      final c = a.cost.compareTo(b.cost);
      if (c != 0) return c;
      final id = a.id.compareTo(b.id);
      return id == 0 ? a.index.compareTo(b.index) : id;
    });
    final usedTracks = <int>{}, usedDetections = <int>{};
    final assignments = <(_Track, PersonDetection)>[];
    for (final m in matches) {
      if (!usedTracks.contains(m.id) && !usedDetections.contains(m.index)) {
        usedTracks.add(m.id);
        usedDetections.add(m.index);
        assignments.add((_tracks[m.id]!, detections[m.index]));
      }
    }
    for (var i = 0; i < detections.length; i++) {
      if (!usedDetections.contains(i)) {
        final t = _Track(++_nextId, detections[i].bbox, now);
        _tracks[t.id] = t;
        assignments.add((t, detections[i]));
      }
    }
    _observed.clear();
    for (final (t, d) in assignments) {
      _observed.add(t.id);
      t.bbox = d.bbox;
      t.lastSeen = now;
      final shelf = _zone(d);
      if (shelf == t.shelf && shelf != null) {
        t.zoneLastSeen = now;
      } else if (shelf != null) {
        final e = _end(t, false);
        if (e != null) events.add(e);
        t.shelf = shelf;
        t.entered = now;
        t.zoneLastSeen = now;
      } else if (t.shelf != null &&
          now - t.zoneLastSeen! >= _number(t.shelf, 'exit_grace_seconds')) {
        final e = _end(t, false);
        if (e != null) events.add(e);
      }
    }
    return events;
  }

  List<Map<String, dynamic>> finish({required bool incomplete}) {
    final events = <Map<String, dynamic>>[];
    for (final t in _tracks.values) {
      final e = _end(t, incomplete);
      if (e != null) events.add(e);
    }
    _tracks.clear();
    _observed.clear();
    return events;
  }

  List<Map<String, dynamic>> visible() => [
    for (final t in _tracks.values)
      if (_observed.contains(t.id))
        {
          'id': t.id,
          'bbox': [t.bbox.left, t.bbox.top, t.bbox.right, t.bbox.bottom],
        },
  ];
  List<Map<String, dynamic>> active() => [
    for (final t in _tracks.values)
      if (t.shelf != null)
        {
          'track_id': t.id,
          'shelf_id': t.shelf,
          'started_at':
              DateTime.fromMillisecondsSinceEpoch(
                (t.entered! * 1000).round(),
                isUtc: true,
              ).toIso8601String(),
          'ended_at':
              DateTime.fromMillisecondsSinceEpoch(
                (t.zoneLastSeen! * 1000).round(),
                isUtc: true,
              ).toIso8601String(),
          'dwell_seconds': math.max(0.0, t.zoneLastSeen! - t.entered!),
        },
  ];
}
