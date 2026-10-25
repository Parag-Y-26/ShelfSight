import 'dart:ui';
import 'dart:math' as math;

const _epsilon = 1e-10;
double _cross(Offset a, Offset b, Offset c) =>
    (b.dx - a.dx) * (c.dy - a.dy) - (b.dy - a.dy) * (c.dx - a.dx);
bool _between(Offset a, Offset b, Offset p) =>
    p.dx >= math.min(a.dx, b.dx) - _epsilon &&
    p.dx <= math.max(a.dx, b.dx) + _epsilon &&
    p.dy >= math.min(a.dy, b.dy) - _epsilon &&
    p.dy <= math.max(a.dy, b.dy) + _epsilon;
bool _intersects(Offset a, Offset b, Offset c, Offset d) {
  final x = _cross(a, b, c),
      y = _cross(a, b, d),
      u = _cross(c, d, a),
      v = _cross(c, d, b);
  if (x * y < 0 && u * v < 0) return true;
  return (x.abs() < _epsilon && _between(a, b, c)) ||
      (y.abs() < _epsilon && _between(a, b, d)) ||
      (u.abs() < _epsilon && _between(c, d, a)) ||
      (v.abs() < _epsilon && _between(c, d, b));
}

bool validConvexPolygon(List<Offset> vertices) {
  if (vertices.length < 3 ||
      vertices.length > 32 ||
      vertices.toSet().length != vertices.length ||
      vertices.any(
        (p) =>
            !p.dx.isFinite ||
            !p.dy.isFinite ||
            p.dx < 0 ||
            p.dy < 0 ||
            p.dx > 1 ||
            p.dy > 1,
      )) {
    return false;
  }
  var sign = 0.0;
  for (var i = 0; i < vertices.length; i++) {
    final cross = _cross(
      vertices[i],
      vertices[(i + 1) % vertices.length],
      vertices[(i + 2) % vertices.length],
    );
    if (cross.abs() > _epsilon) {
      if (sign != 0 && sign * cross < 0) return false;
      sign = cross;
    }
    for (var j = i + 1; j < vertices.length; j++) {
      if (j == i + 1 || (i == 0 && j == vertices.length - 1)) continue;
      if (_intersects(
        vertices[i],
        vertices[(i + 1) % vertices.length],
        vertices[j],
        vertices[(j + 1) % vertices.length],
      )) {
        return false;
      }
    }
  }
  return sign != 0;
}

bool polygonContains(List<Offset> vertices, Offset point) {
  var sign = 0.0;
  for (var i = 0; i < vertices.length; i++) {
    final cross = _cross(
      vertices[i],
      vertices[(i + 1) % vertices.length],
      point,
    );
    if (cross.abs() > _epsilon) {
      if (sign != 0 && sign * cross < 0) return false;
      sign = cross;
    }
  }
  return true;
}

bool polygonsOverlap(List<Offset> a, List<Offset> b) {
  for (final points in [a, b]) {
    for (var i = 0; i < points.length; i++) {
      final edge = points[(i + 1) % points.length] - points[i],
          axis = Offset(-edge.dy, edge.dx);
      double project(Offset p) => p.dx * axis.dx + p.dy * axis.dy;
      final left = a.map(project).toList()..sort(),
          right = b.map(project).toList()..sort();
      if (left.last <= right.first + _epsilon ||
          right.last <= left.first + _epsilon) {
        return false;
      }
    }
  }
  return true;
}
