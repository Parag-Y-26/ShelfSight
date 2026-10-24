import 'dart:math' as math;
import 'dart:ui';

double? finiteNumber(Object? value) {
  final number = value is num ? value.toDouble() : double.tryParse('$value');
  return number != null && number.isFinite ? number : null;
}

/// A shopper interaction zone in the upright, uncropped camera image.
class CameraZone {
  const CameraZone({required this.shelfId, required this.rect});
  final String shelfId;
  final Rect rect;

  bool get valid =>
      shelfId.isNotEmpty &&
      rect.left.isFinite &&
      rect.top.isFinite &&
      rect.width.isFinite &&
      rect.height.isFinite &&
      rect.left >= 0 &&
      rect.top >= 0 &&
      rect.width > 0 &&
      rect.height > 0 &&
      rect.right <= 1 &&
      rect.bottom <= 1;

  bool overlaps(CameraZone other) => rect.overlaps(other.rect);

  Map<String, dynamic> toJson() => {
    'shelf_id': shelfId,
    'x': rect.left,
    'y': rect.top,
    'width': rect.width,
    'height': rect.height,
  };

  static CameraZone? fromJson(Map<String, dynamic> json) {
    final x = finiteNumber(json['x']);
    final y = finiteNumber(json['y']);
    final w = finiteNumber(json['width']);
    final h = finiteNumber(json['height']);
    final id = json['shelf_id'];
    if (x == null || y == null || w == null || h == null || id is! String) {
      return null;
    }
    final zone = CameraZone(shelfId: id, rect: Rect.fromLTWH(x, y, w, h));
    return zone.valid ? zone : null;
  }
}

bool validZones(List<CameraZone> zones) {
  if (zones.isEmpty) return false;
  final ids = <String>{};
  for (var i = 0; i < zones.length; i++) {
    if (!zones[i].valid || !ids.add(zones[i].shelfId)) return false;
    for (var j = 0; j < i; j++) {
      if (zones[i].overlaps(zones[j])) return false;
    }
  }
  return true;
}

Rect containedRect(Size canvas, double width, double length, double inset) {
  final available = Size(
    math.max(0, canvas.width - inset * 2),
    math.max(0, canvas.height - inset * 2),
  );
  if (width <= 0 || length <= 0 || available.isEmpty) return Rect.zero;
  final scale = math.min(available.width / width, available.height / length);
  final size = Size(width * scale, length * scale);
  return Rect.fromLTWH(
    (canvas.width - size.width) / 2,
    (canvas.height - size.height) / 2,
    size.width,
    size.height,
  );
}

/// Physical coordinates use the store's selected unit. Rotation changes the
/// footprint, while width/length retain the shelf's own axes.
class ShelfGeometry {
  const ShelfGeometry({
    required this.x,
    required this.y,
    required this.width,
    required this.length,
    required this.rotation,
    required this.shape,
  });
  final double x, y, width, length;
  final int rotation;
  final String shape;

  double get footprintWidth => rotation % 180 == 0 ? width : length;
  double get footprintLength => rotation % 180 == 0 ? length : width;
  Rect get footprint => Rect.fromLTWH(x, y, footprintWidth, footprintLength);

  bool fits(double floorWidth, double floorLength) =>
      [x, y, width, length, floorWidth, floorLength].every((v) => v.isFinite) &&
      width > 0 &&
      length > 0 &&
      x >= 0 &&
      y >= 0 &&
      floorWidth > 0 &&
      floorLength > 0 &&
      footprint.right <= floorWidth &&
      footprint.bottom <= floorLength &&
      rotation % 90 == 0 &&
      (shape != 'square' || (width - length).abs() < 0.000001);

  ShelfGeometry moved(Offset delta, double floorWidth, double floorLength) =>
      ShelfGeometry(
        x: (x + delta.dx)
            .clamp(0, math.max(0, floorWidth - footprintWidth))
            .toDouble(),
        y: (y + delta.dy)
            .clamp(0, math.max(0, floorLength - footprintLength))
            .toDouble(),
        width: width,
        length: length,
        rotation: rotation,
        shape: shape,
      );

  /// Resize a displayed corner, keeping its opposite corner fixed. The small
  /// epsilon only avoids a zero-area gesture; it is not a business dimension.
  ShelfGeometry resized(int corner, Offset point, double fw, double fl) {
    final old = footprint;
    final anchors = [
      old.bottomRight,
      old.bottomLeft,
      old.topLeft,
      old.topRight,
    ];
    final anchor = anchors[corner];
    final left = corner == 0 || corner == 3;
    final top = corner == 0 || corner == 1;
    final epsilon = math.min(fw, fl) * 0.000001;
    var dx = (left ? anchor.dx - point.dx : point.dx - anchor.dx)
        .clamp(epsilon, left ? anchor.dx : fw - anchor.dx)
        .toDouble();
    var dy = (top ? anchor.dy - point.dy : point.dy - anchor.dy)
        .clamp(epsilon, top ? anchor.dy : fl - anchor.dy)
        .toDouble();
    if (shape == 'square') {
      dx = dy = math.min(dx, dy);
    }
    final displayWidth = dx;
    final displayLength = dy;
    return ShelfGeometry(
      x: left ? anchor.dx - dx : anchor.dx,
      y: top ? anchor.dy - dy : anchor.dy,
      width: rotation % 180 == 0 ? displayWidth : displayLength,
      length: rotation % 180 == 0 ? displayLength : displayWidth,
      rotation: rotation,
      shape: shape,
    );
  }

  Map<String, dynamic> toJson() => {
    'x': x,
    'y': y,
    'width': width,
    'length': length,
    'rotation': rotation,
    'shape': shape,
  };

  static ShelfGeometry? fromJson(Map<String, dynamic> json) {
    final x = finiteNumber(json['x']);
    final y = finiteNumber(json['y']);
    final w = finiteNumber(json['width']);
    final l = finiteNumber(json['length']);
    final r = finiteNumber(json['rotation']);
    final shape = json['shape'];
    if (x == null ||
        y == null ||
        w == null ||
        l == null ||
        r == null ||
        shape is! String ||
        r != r.roundToDouble()) {
      return null;
    }
    return ShelfGeometry(
      x: x,
      y: y,
      width: w,
      length: l,
      rotation: r.toInt(),
      shape: shape,
    );
  }
}

/// Every setting is resolved against configuration; there are no module-local
/// threshold defaults. The server independently resolves the same precedence.
double? threshold(
  Map<String, dynamic> config,
  Map<String, dynamic>? store,
  Map<String, dynamic>? shelf,
  String key,
) {
  final defaults = config['settings'];
  final storeSettings = store?['settings'];
  final shelfSettings = shelf?['settings'];
  return finiteNumber(
    shelfSettings is Map && shelfSettings[key] != null
        ? shelfSettings[key]
        : storeSettings is Map && storeSettings[key] != null
        ? storeSettings[key]
        : defaults is Map
        ? defaults[key]
        : null,
  );
}
