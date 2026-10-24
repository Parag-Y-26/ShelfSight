import 'dart:convert';

/// Evaluation-only label reader. It has no camera, API, cache or ledger access.
/// No fabricated frames ship with the app and no production detector uses it.
class SyntheticReplayDetector {
  SyntheticReplayDetector._(this.frames);
  final List<Map<String, dynamic>> frames;
  String get provenance => 'labeled_replay';
  int get detectionCount => frames.fold(
    0,
    (total, frame) => total + (frame['detections'] as List).length,
  );

  factory SyntheticReplayDetector.fromJson(
    String input, {
    required bool enabled,
  }) {
    if (!enabled) {
      throw StateError('Evaluation replay requires explicit opt-in');
    }
    if (input.length > 1000000) throw const FormatException('invalidReplay');
    final decoded = jsonDecode(input);
    if (decoded is! List || decoded.isEmpty || decoded.length > 10000) {
      throw const FormatException('invalidReplay');
    }
    final frames = <Map<String, dynamic>>[];
    num previous = -1;
    for (final frame in decoded) {
      if (frame is! Map) throw const FormatException('invalidReplay');
      final at = frame['at_ms'];
      final detections = frame['detections'];
      if (at is! num ||
          !at.isFinite ||
          at < 0 ||
          at <= previous ||
          detections is! List ||
          detections.length > 1000) {
        throw const FormatException('invalidReplay');
      }
      previous = at;
      for (final detection in detections) {
        if (detection is! Map) throw const FormatException('invalidReplay');
        final box = detection['bbox'];
        final confidence = detection['confidence'];
        if (box is! List ||
            box.length != 4 ||
            box.any((v) => v is! num || !v.isFinite || v < 0 || v > 1) ||
            box[0] >= box[2] ||
            box[1] >= box[3] ||
            confidence is! num ||
            !confidence.isFinite ||
            confidence < 0 ||
            confidence > 1) {
          throw const FormatException('invalidReplay');
        }
      }
      frames.add(
        Map<String, dynamic>.unmodifiable({
          'at_ms': at,
          'detections': List.unmodifiable(detections),
          'provenance': 'labeled_replay',
        }),
      );
    }
    return SyntheticReplayDetector._(List.unmodifiable(frames));
  }
}
