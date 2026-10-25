import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_controller.dart';
import '../core/strings.dart';

class EventCitation extends ConsumerWidget {
  const EventCitation({super.key, required this.eventId});
  final String eventId;
  @override
  Widget build(BuildContext context, WidgetRef ref) => TextButton.icon(
    icon: const Icon(Icons.receipt_long_outlined),
    label: Text(eventId, softWrap: true),
    onPressed: () async {
      final app = ref.read(appControllerProvider),
          generation = ref.read(appControllerProvider).identityGeneration;
      final storeId = app.store?['id'];
      try {
        final event = await app.recordedEvent(eventId);
        if (!context.mounted ||
            generation != app.identityGeneration ||
            storeId != app.store?['id']) {
          return;
        }
        await showDialog<void>(
          context: context,
          builder:
              (dialog) => AlertDialog(
                title: Text(tr(context, 'ledgerEvent')),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SelectableText('event_id: ${event['id']}'),
                      for (final key in [
                        'shelf_id',
                        'event_type',
                        'type',
                        'provenance',
                        'server_timestamp',
                        'started_at',
                        'ended_at',
                        'dwell_seconds',
                        'quantity',
                        'row',
                        'slot',
                        'incomplete',
                      ])
                        if (event[key] != null)
                          SelectableText('$key: ${event[key]}'),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: Text(tr(context, 'close')),
                  ),
                ],
              ),
        );
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(tr(context, 'eventUnavailable'))),
          );
        }
      }
    },
  );
}
