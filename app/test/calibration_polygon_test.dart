import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/geometry.dart';
import 'package:shelfsight/vision/polygon.dart';

void main() {
  final a = [const Offset(0, 0), const Offset(1, 0), const Offset(0, 1)];
  final b = [const Offset(1, 1), const Offset(1, .6), const Offset(.6, 1)];
  test(
    'convex calibration rejects crossings, concavity and overlapping polygons',
    () {
      expect(validConvexPolygon(a), true);
      expect(polygonsOverlap(a, b), false);
      expect(polygonsOverlap(a, a), true);
      expect(polygonContains(a, const Offset(.8, .8)), false);
      expect(polygonContains(a, const Offset(.2, .7)), true);
      expect(
        validConvexPolygon([
          const Offset(0, 0),
          const Offset(1, 1),
          const Offset(0, 1),
          const Offset(1, 0),
        ]),
        false,
      );
      final first = CameraZone.fromJson({
        'shelf_id': 'a',
        'x': 0,
        'y': 0,
        'width': 1,
        'height': 1,
        'polygon': [
          [0, 0],
          [1, 0],
          [0, 1],
        ],
      });
      expect(first!.contains(const Offset(.8, .8)), false);
      expect(CameraZone.fromJson(first.toJson())!.polygon, hasLength(3));
      expect(
        validZones([
          first,
          const CameraZone(shelfId: 'b', rect: Rect.fromLTWH(0, 0, .1, .1)),
        ]),
        false,
      );
    },
  );
}
