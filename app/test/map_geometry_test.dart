import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:shelfsight/vision/geometry.dart';

void main() {
  test(
    'touching zones are allowed but overlapping or duplicate zones fail',
    () {
      const first = CameraZone(
        shelfId: 'fixture-a',
        rect: Rect.fromLTWH(0, 0, 0.5, 1),
      );
      const adjacent = CameraZone(
        shelfId: 'fixture-b',
        rect: Rect.fromLTWH(0.5, 0, 0.5, 1),
      );
      const overlap = CameraZone(
        shelfId: 'fixture-c',
        rect: Rect.fromLTWH(0.4, 0, 0.5, 1),
      );
      expect(validZones([first, adjacent]), isTrue);
      expect(validZones([first, overlap]), isFalse);
      expect(validZones([first, first]), isFalse);
      expect(validZones([]), isFalse);
    },
  );

  test('calibration refuses zero area and coordinates beyond the image', () {
    expect(
      const CameraZone(shelfId: 'x', rect: Rect.fromLTWH(0, 0, 0, 1)).valid,
      isFalse,
    );
    expect(
      const CameraZone(shelfId: 'x', rect: Rect.fromLTWH(0.9, 0, 0.2, 1)).valid,
      isFalse,
    );
    expect(
      CameraZone.fromJson({
        'shelf_id': 'x',
        'x': 0,
        'y': 0,
        'width': double.nan,
        'height': 1,
      }),
      isNull,
    );
  });

  test('rotated footprints and movement keep every corner on the floor', () {
    const shelf = ShelfGeometry(
      x: 1,
      y: 2,
      width: 4,
      length: 2,
      rotation: 90,
      shape: 'rectangle',
    );
    expect(shelf.footprint, const Rect.fromLTWH(1, 2, 2, 4));
    final moved = shelf.moved(const Offset(100, -100), 10, 8);
    expect((moved.x, moved.y), (8, 0));
    expect(moved.fits(10, 8), isTrue);
    expect(shelf.fits(2, 3), isFalse);
  });

  test('resizing a rotated corner retains the opposite anchor and axes', () {
    const shelf = ShelfGeometry(
      x: 1,
      y: 2,
      width: 4,
      length: 2,
      rotation: 90,
      shape: 'rectangle',
    );
    final resized = shelf.resized(2, const Offset(8, 9), 10, 12);
    expect(resized.footprint.topLeft, shelf.footprint.topLeft);
    expect((resized.width, resized.length), (7, 7));
    expect(resized.fits(10, 12), isTrue);
  });

  test('square resize keeps sides equal and clamps outside drags', () {
    const shelf = ShelfGeometry(
      x: 2,
      y: 2,
      width: 2,
      length: 2,
      rotation: 0,
      shape: 'square',
    );
    final resized = shelf.resized(0, const Offset(-50, -20), 10, 10);
    expect(resized.width, resized.length);
    expect(resized.footprint.bottomRight, shelf.footprint.bottomRight);
    expect(resized.fits(10, 10), isTrue);
  });

  test(
    'threshold values resolve shelf then store then versioned configuration',
    () {
      final config = {
        'settings': {'dwell_cutoff_sec': 2.5},
      };
      final store = {
        'settings': {'dwell_cutoff_sec': 3.5},
      };
      final shelf = {
        'settings': {'dwell_cutoff_sec': 4.5},
      };
      expect(threshold(config, store, shelf, 'dwell_cutoff_sec'), 4.5);
      expect(threshold(config, store, null, 'dwell_cutoff_sec'), 3.5);
      expect(threshold(config, null, null, 'dwell_cutoff_sec'), 2.5);
      expect(threshold({}, null, null, 'dwell_cutoff_sec'), isNull);
    },
  );

  test(
    'unplaced geometry remains absent instead of acquiring mock dimensions',
    () {
      expect(
        ShelfGeometry.fromJson({
          'id': 'unplaced',
          'width': null,
          'length': null,
        }),
        isNull,
      );
      expect(containedRect(const Size(100, 100), 0, 10, 5), Rect.zero);
      expect(
        containedRect(const Size(100, 100), 20, 10, 10),
        const Rect.fromLTWH(10, 30, 80, 40),
      );
    },
  );
}
