import 'package:flutter/material.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../vision/monitoring_controller.dart';
import '../vision/polygon.dart';

/// Numeric alternatives keep camera calibration operable without dragging.
Future<void> editCameraZone(
  BuildContext context,
  MonitoringController model, {
  required bool polygon,
}) async {
  final existing =
      model.zones.where((z) => z.shelfId == model.selectedShelfId).firstOrNull;
  final rect = existing?.rect ?? const Rect.fromLTWH(0, 0, 1, 1);
  final fields = [
    for (final value in [rect.left, rect.top, rect.width, rect.height])
      TextEditingController(text: (value * 100).toStringAsFixed(2)),
  ];
  final x = TextEditingController(), y = TextEditingController();
  var points = <Offset>[...existing?.polygon ?? []];
  final form = GlobalKey<FormState>(), pointForm = GlobalKey<FormState>();
  String? error;
  try {
    final result = await showDialog<List<Offset>>(
      context: context,
      builder:
          (dialog) => StatefulBuilder(
            builder:
                (dialog, setDialog) => AlertDialog(
                  title: Text(tr(context, 'manualZone')),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!polygon)
                          Form(
                            key: form,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (var i = 0; i < 4; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(
                                      bottom: Tokens.sm,
                                    ),
                                    child: TextFormField(
                                      controller: fields[i],
                                      keyboardType:
                                          const TextInputType.numberWithOptions(
                                            decimal: true,
                                          ),
                                      decoration: InputDecoration(
                                        labelText: tr(
                                          context,
                                          [
                                            'zoneLeft',
                                            'zoneTop',
                                            'zoneWidth',
                                            'zoneHeight',
                                          ][i],
                                        ),
                                      ),
                                      validator: (text) {
                                        final value = double.tryParse(
                                          text ?? '',
                                        );
                                        return value == null ||
                                                !value.isFinite ||
                                                value < 0 ||
                                                value > 100
                                            ? tr(context, 'invalidZone')
                                            : null;
                                      },
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        if (polygon) ...[
                          Text(tr(context, 'polygonHelp')),
                          Form(
                            key: pointForm,
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                for (final entry in [
                                  (x, 'zoneX'),
                                  (y, 'zoneY'),
                                ])
                                  TextFormField(
                                    controller: entry.$1,
                                    keyboardType:
                                        const TextInputType.numberWithOptions(
                                          decimal: true,
                                        ),
                                    decoration: InputDecoration(
                                      labelText: tr(context, entry.$2),
                                    ),
                                    validator: (text) {
                                      final value = double.tryParse(text ?? '');
                                      return value == null ||
                                              !value.isFinite ||
                                              value < 0 ||
                                              value > 100
                                          ? tr(context, 'invalidZone')
                                          : null;
                                    },
                                  ),
                              ],
                            ),
                          ),
                          TextButton(
                            onPressed:
                                points.length >= 32
                                    ? null
                                    : () {
                                      if (pointForm.currentState?.validate() ==
                                          true) {
                                        setDialog(
                                          () => points.add(
                                            Offset(
                                              double.parse(x.text) / 100,
                                              double.parse(y.text) / 100,
                                            ),
                                          ),
                                        );
                                      }
                                    },
                            child: Text(tr(context, 'addVertex')),
                          ),
                          for (var i = 0; i < points.length; i++)
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${i + 1}: ${(points[i].dx * 100).toStringAsFixed(1)}%, ${(points[i].dy * 100).toStringAsFixed(1)}%',
                                  ),
                                ),
                                IconButton(
                                  tooltip:
                                      '${tr(context, 'undoVertex')} ${i + 1}',
                                  onPressed:
                                      () => setDialog(() => points.removeAt(i)),
                                  icon: const Icon(Icons.remove_circle_outline),
                                ),
                              ],
                            ),
                        ],
                        if (error != null)
                          Text(
                            error!,
                            style: const TextStyle(color: Tokens.danger),
                          ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialog),
                      child: Text(tr(context, 'cancel')),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (polygon) {
                          if (validConvexPolygon(points)) {
                            Navigator.pop(dialog, points);
                          } else {
                            setDialog(() => error = tr(context, 'invalidZone'));
                          }
                        } else if (form.currentState?.validate() == true) {
                          final v =
                                  fields
                                      .map((f) => double.parse(f.text) / 100)
                                      .toList(),
                              r = Rect.fromLTWH(
                                double.parse(fields[0].text) / 100,
                                double.parse(fields[1].text) / 100,
                                double.parse(fields[2].text) / 100,
                                double.parse(fields[3].text) / 100,
                              );
                          if (v[2] <= 0 ||
                              v[3] <= 0 ||
                              r.right > 1 ||
                              r.bottom > 1) {
                            setDialog(() => error = tr(context, 'invalidZone'));
                            return;
                          }
                          Navigator.pop(dialog, [
                            r.topLeft,
                            r.topRight,
                            r.bottomRight,
                            r.bottomLeft,
                          ]);
                        }
                      },
                      child: Text(tr(context, 'save')),
                    ),
                  ],
                ),
          ),
    );
    if (result != null) model.setPolygon(result);
  } finally {
    for (final c in [...fields, x, y]) {
      c.dispose();
    }
  }
}
