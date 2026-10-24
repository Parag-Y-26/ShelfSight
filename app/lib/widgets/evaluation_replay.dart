import 'package:flutter/material.dart';

import '../core/strings.dart';
import '../core/theme.dart';
import '../vision/evaluation_replay.dart';
import 'shared.dart';

class EvaluationReplayCard extends StatefulWidget {
  const EvaluationReplayCard({super.key});
  @override
  State<EvaluationReplayCard> createState() => _EvaluationReplayCardState();
}

class _EvaluationReplayCardState extends State<EvaluationReplayCard> {
  bool _enabled = false;
  String? _error;
  SyntheticReplayDetector? _replay;
  int _index = 0;
  final _labels = TextEditingController();

  @override
  void dispose() {
    _labels.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => InfoCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(tr(context, 'runLabeledReplay')),
          value: _enabled,
          onChanged:
              (enabled) => setState(() {
                _enabled = enabled;
                _replay = null;
                _error = null;
                _index = 0;
                _labels.clear();
              }),
        ),
        if (_enabled) ...[
          const Chip(label: Text('labeled_replay')),
          Text(tr(context, 'replayHelp')),
          const SizedBox(height: Tokens.sm),
          TextField(
            controller: _labels,
            minLines: 3,
            maxLines: 6,
            maxLength: 1000000,
            decoration: InputDecoration(labelText: tr(context, 'replayLabels')),
          ),
          if (_error != null) ErrorNotice(message: tr(context, _error!)),
          TextButton(
            onPressed:
                () => setState(() {
                  _replay = null;
                  _error = null;
                  _index = 0;
                  try {
                    _replay = SyntheticReplayDetector.fromJson(
                      _labels.text,
                      enabled: _enabled,
                    );
                  } on FormatException {
                    _error = 'invalidReplay';
                  }
                }),
            child: Text(tr(context, 'loadReplay')),
          ),
          if (_replay case final replay?) ...[
            Text(
              tr(context, 'replaySummary', {
                'frames': replay.frames.length.toString(),
                'detections': replay.detectionCount.toString(),
              }),
            ),
            SelectableText(jsonEncodeFrame(replay.frames[_index])),
            TextButton(
              onPressed:
                  _index + 1 < replay.frames.length
                      ? () => setState(() => _index++)
                      : null,
              child: Text(tr(context, 'nextReplayFrame')),
            ),
          ],
        ],
      ],
    ),
  );
}

String jsonEncodeFrame(Map<String, dynamic> frame) =>
    '${frame['at_ms']} ms · ${frame['detections']}';
