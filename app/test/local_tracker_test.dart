import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/local_tracker.dart';
import 'package:shelfsight/vision/geometry.dart';

void main() {
  final settings = <String, dynamic>{
    'dwell_cutoff_sec': 3.0,
    'tracking_grace_sec': 1.5,
    'exit_grace_seconds': 1.0,
    'tracker_match_distance': .18,
    'tracker_min_iou': .05,
    'detection_confidence_threshold': .45,
  };
  BottomCenterIoUTracker tracker() => BottomCenterIoUTracker(
    zones: [const CameraZone(shelfId: 's1', rect: Rect.fromLTWH(0, .5, 1, .5))],
    defaults: settings,
  );
  const person = PersonDetection(Rect.fromLTRB(.3, .1, .5, .8), .9);
  test('counts verified dwell, uses bottom center and finalizes only once', () {
    final t = tracker();
    expect(t.update([person], 100), isEmpty);
    expect(t.update([person], 101), isEmpty);
    expect(t.update([person], 102), isEmpty);
    expect(t.update([person], 103), isEmpty);
    final events = t.finish(incomplete: true);
    expect(events.single['shelf_id'], 's1');
    expect(events.single['dwell_seconds'], 3);
    expect(events.single['is_incomplete'], true);
    expect(t.finish(incomplete: true), isEmpty);
  });
  test('grace expiry never bridges unseen time or manufactures dwell', () {
    final t = tracker();
    t.update([person], 100);
    t.update([person], 101);
    t.update([person], 110);
    expect(t.finish(incomplete: true), isEmpty);
  });
  test(
    'low confidence, short visits and non-monotonic samples do not count',
    () {
      final t = tracker();
      t.update([PersonDetection(person.bbox, .2)], 100);
      t.update([person], 101);
      expect(() => t.update([person], 100), throwsArgumentError);
      expect(t.finish(incomplete: true), isEmpty);
    },
  );
  test('complete departure ends at last observation in zone', () {
    final t = tracker();
    for (var i = 100; i <= 104; i++) {
      t.update([person], i.toDouble());
    }
    final result = t.update([
      const PersonDetection(Rect.fromLTRB(.3, .1, .5, .49), .9),
    ], 105);
    expect(result.single['incomplete'], false);
    expect(result.single['dwell_seconds'], 4);
  });
}
