"""Normalized convex camera polygons; boundary-touching zones may coexist."""

import math

EPSILON = 1e-10


def vertices(zone: dict) -> list:
    if zone.get("polygon") is not None:
        return zone["polygon"]
    x, y, w, h = (zone[k] for k in ("x", "y", "width", "height"))
    return [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]


def cross(a, b, c):
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def intersects(a, b, c, d):
    x, y, u, v = cross(a, b, c), cross(a, b, d), cross(c, d, a), cross(c, d, b)
    if x * y < 0 and u * v < 0:
        return True

    def between(p, q, r):
        return all(min(p[i], q[i]) - EPSILON <= r[i] <= max(p[i], q[i]) + EPSILON for i in (0, 1))

    return any(
        abs(value) < EPSILON and between(p, q, r)
        for value, p, q, r in [(x, a, b, c), (y, a, b, d), (u, c, d, a), (v, c, d, b)]
    )


def valid_polygon(points):
    if not 3 <= len(points) <= 32 or len({tuple(p) for p in points}) != len(points):
        return False
    if any(len(p) != 2 or any(not math.isfinite(v) or not 0 <= v <= 1 for v in p) for p in points):
        return False
    sign = 0
    for i, point in enumerate(points):
        turn = cross(point, points[(i + 1) % len(points)], points[(i + 2) % len(points)])
        if abs(turn) > EPSILON:
            if sign and sign * turn < 0:
                return False
            sign = turn
        for j in range(i + 1, len(points)):
            if j == i + 1 or (i == 0 and j == len(points) - 1):
                continue
            if intersects(
                point, points[(i + 1) % len(points)], points[j], points[(j + 1) % len(points)]
            ):
                return False
    return bool(sign)


def zone_contains(zone, x, y):
    points, sign = vertices(zone), 0
    for i, point in enumerate(points):
        turn = cross(point, points[(i + 1) % len(points)], [x, y])
        if abs(turn) > EPSILON:
            if sign and sign * turn < 0:
                return False
            sign = turn
    return True


def zones_overlap(a, b):
    aa, bb = vertices(a), vertices(b)
    for points in (aa, bb):
        for i, point in enumerate(points):
            nxt = points[(i + 1) % len(points)]
            axis = [point[1] - nxt[1], nxt[0] - point[0]]
            ap = [p[0] * axis[0] + p[1] * axis[1] for p in aa]
            bp = [p[0] * axis[0] + p[1] * axis[1] for p in bb]
            if max(ap) <= min(bp) + EPSILON or max(bp) <= min(ap) + EPSILON:
                return False
    return True
