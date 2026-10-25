import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';

class ProviderBadge extends ConsumerStatefulWidget {
  const ProviderBadge({super.key, this.shelfId, this.direct = false});
  final String? shelfId;
  final bool direct;
  @override
  ConsumerState<ProviderBadge> createState() => _ProviderBadgeState();
}

class _ProviderBadgeState extends ConsumerState<ProviderBadge> {
  Future<Map<String, dynamic>?>? _choice;
  String? _signature;
  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final shelf =
        app.shelves.where((s) => s['id'] == widget.shelfId).firstOrNull;
    final settings = app.effectiveSettings(shelf);
    final remote =
        !widget.direct && settings['execution_mode'] == 'remote_server';
    final selected = settings['active_ai_provider']?.toString() ?? 'auto';
    final signature =
        '${app.identityGeneration}|${app.store?['id']}|$selected|$remote|${app.aiSettingsRevision}|${app.ledgerRevision}|${app.aiRoutingRevision}';
    if (signature != _signature) {
      _signature = signature;
      _choice =
          !remote && app.config['ai'] is Map
              ? app.aiRouter.previewChoice('shelf_scan', preferred: selected)
              : Future.value(null);
    }
    return FutureBuilder<Map<String, dynamic>?>(
      future: _choice,
      builder: (context, snapshot) {
        final choice =
            snapshot.connectionState == ConnectionState.done
                ? snapshot.data
                : null;
        final label =
            remote
                ? tr(context, 'serverAiRouting')
                : choice == null
                ? tr(
                  context,
                  snapshot.connectionState == ConnectionState.waiting
                      ? 'providerResolving'
                      : 'providerNotConfigured',
                )
                : '${tr(context, 'option_${choice['provider']}')} · ${choice['model']}';
        final last = app.lastShelfScan;
        final hasLast =
            last != null &&
            last['store_id'] == app.store?['id'] &&
            last['backend'] == app.repository.identity &&
            (widget.shelfId == null || last['shelf_id'] == widget.shelfId);
        final previous =
            hasLast
                ? '\n${tr(context, 'lastScanProvider')}: ${['gemini', 'nvidia_nim', 'openrouter'].contains(last['provider']) ? tr(context, 'option_${last['provider']}') : tr(context, 'unknown')} · ${last['model'] ?? tr(context, 'unknown')}'
                : '';
        final text =
            remote
                ? '$label$previous'
                : '${tr(context, 'nextScanRoute')}: ${selected == 'auto' ? 'Laya → ' : ''}$label$previous';
        return Semantics(
          label: text,
          excludeSemantics: true,
          child: Container(
            padding: const EdgeInsets.all(Tokens.sm),
            decoration: BoxDecoration(
              color: Tokens.surface,
              border: Border.all(color: Tokens.line),
              borderRadius: BorderRadius.circular(Tokens.sm),
            ),
            child: Row(
              children: [
                const Icon(Icons.route_outlined),
                const SizedBox(width: Tokens.sm),
                Expanded(child: Text(text, softWrap: true)),
              ],
            ),
          ),
        );
      },
    );
  }
}
