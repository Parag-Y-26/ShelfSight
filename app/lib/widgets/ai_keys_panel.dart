import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/ai_credentials.dart';
import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import 'shared.dart';

class AiKeysPanel extends ConsumerStatefulWidget {
  const AiKeysPanel({super.key, this.showRouting = true});
  final bool showRouting;
  @override
  ConsumerState<AiKeysPanel> createState() => _AiKeysPanelState();
}

class _AiKeysPanelState extends ConsumerState<AiKeysPanel> {
  final _keys = {
    for (final provider in AiCredentials.providers)
      provider: TextEditingController(),
  };
  final _vision = {
    for (final provider in AiCredentials.providers)
      provider: TextEditingController(),
  };
  final _decision = {
    for (final provider in AiCredentials.providers)
      provider: TextEditingController(),
  };
  final _saved = <String, bool>{};
  final _latency = <String, double>{};
  bool _busy = false;
  String? _error, _notice;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final app = ref.read(appControllerProvider);
    if (app.config['ai'] is! Map) return;
    try {
      for (final provider in AiCredentials.providers) {
        final profile = app.config['ai']['providers'][provider] as Map;
        _saved[provider] = (await app.aiCredentials.key(provider)).isNotEmpty;
        final vision = await app.aiCredentials.model(
          provider,
          'shelf_scan',
          profile['vision_model'] as String,
        );
        final decision = await app.aiCredentials.model(
          provider,
          'autonomous_decision',
          profile['decision_model'] as String,
        );
        if (!mounted) return;
        _vision[provider]!.text = vision;
        _decision[provider]!.text = decision;
      }
    } catch (_) {
      _error = 'aiStorageFailed';
    }
    if (mounted) setState(() {});
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = 'aiRequestFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save(String provider) async {
    final vault = ref.read(appControllerProvider).aiCredentials;
    final key = _keys[provider]!.text;
    final vision = _vision[provider]!.text,
        decision = _decision[provider]!.text;
    if (key.trim().isNotEmpty) {
      await vault.setKey(provider, key);
    }
    await vault.setModel(provider, vision);
    await vault.setModel(provider, decision, vision: false);
    if (!mounted) return;
    _keys[provider]!.clear();
    _saved[provider] = (await vault.key(provider)).isNotEmpty;
    _latency.remove(provider);
    _notice = 'aiKeysSaved';
  }

  @override
  void dispose() {
    for (final controller in [
      ..._keys.values,
      ..._vision.values,
      ..._decision.values,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    if (app.config['ai'] is! Map) return const SizedBox.shrink();
    return InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            tr(context, 'aiDirectKeys'),
            style: Theme.of(context).textTheme.titleLarge,
          ),
          Text(tr(context, 'aiKeysPrivacy')),
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ErrorNotice(message: tr(context, _error!)),
          if (_notice != null) Text(tr(context, _notice!)),
          const SizedBox(height: Tokens.sm),
          if (widget.showRouting)
            DropdownButtonFormField<String>(
              key: ValueKey(app.globalSettings['active_ai_provider']),
              isExpanded: true,
              initialValue:
                  app.globalSettings['active_ai_provider'] as String? ?? 'auto',
              decoration: InputDecoration(
                labelText: tr(context, 'threshold_active_ai_provider'),
              ),
              items: [
                for (final provider in ['auto', ...AiCredentials.providers])
                  DropdownMenuItem(
                    value: provider,
                    child: Text(tr(context, 'option_$provider')),
                  ),
              ],
              onChanged:
                  _busy
                      ? null
                      : (provider) {
                        if (provider != null) {
                          _run(
                            () => app.saveSettings({
                              ...app.deviceOverrides,
                              'active_ai_provider': provider,
                            }, global: true),
                          );
                        }
                      },
            ),
          for (final provider in AiCredentials.providers)
            ExpansionTile(
              key: ValueKey('ai-provider-$provider'),
              title: Text(tr(context, 'option_$provider')),
              subtitle: Text(
                tr(
                  context,
                  _saved[provider] == true ? 'aiKeyPresent' : 'aiKeyMissing',
                ),
              ),
              children: [
                TextField(
                  key: ValueKey('ai-key-$provider'),
                  controller: _keys[provider],
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  maxLength: 8192,
                  decoration: InputDecoration(
                    labelText: tr(context, 'aiApiKey'),
                  ),
                ),
                TextField(
                  key: ValueKey('ai-vision-model-$provider'),
                  controller: _vision[provider],
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr(context, 'aiVisionModel'),
                  ),
                ),
                TextField(
                  key: ValueKey('ai-decision-model-$provider'),
                  controller: _decision[provider],
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: tr(context, 'aiDecisionModel'),
                  ),
                ),
                Wrap(
                  spacing: Tokens.sm,
                  children: [
                    TextButton(
                      onPressed:
                          _busy ? null : () => _run(() => _save(provider)),
                      child: Text(tr(context, 'save')),
                    ),
                    TextButton(
                      key: ValueKey('ai-test-$provider'),
                      onPressed:
                          _busy
                              ? null
                              : () => _run(() async {
                                await _save(provider);
                                final result = await app.aiRouter
                                    .testConnection(provider);
                                if (mounted) {
                                  _latency[provider] = result.latencyMs;
                                  _notice = null;
                                }
                              }),
                      child: Text(tr(context, 'aiTestConnection')),
                    ),
                    TextButton(
                      onPressed:
                          _busy
                              ? null
                              : () => _run(() async {
                                await app.aiCredentials.clear(provider);
                                if (!mounted) return;
                                _saved[provider] = false;
                                _latency.remove(provider);
                                _keys[provider]!.clear();
                              }),
                      child: Text(tr(context, 'aiRemoveKey')),
                    ),
                  ],
                ),
                if (_latency[provider] case final ms?)
                  Text(tr(context, 'aiLatency', {'ms': ms.toStringAsFixed(0)})),
              ],
            ),
          TextButton.icon(
            onPressed: _busy ? null : () => context.push('/ai-scan'),
            icon: const Icon(Icons.camera_alt_outlined),
            label: Text(tr(context, 'aiDirectScan')),
          ),
          TextButton.icon(
            onPressed: _busy ? null : () => context.push('/ai-parse'),
            icon: const Icon(Icons.text_fields),
            label: Text(tr(context, 'aiProductParse')),
          ),
        ],
      ),
    );
  }
}
