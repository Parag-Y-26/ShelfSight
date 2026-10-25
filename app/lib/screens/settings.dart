import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/configuration.dart';
import '../widgets/evaluation_replay.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';
import '../widgets/ai_keys_panel.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});
  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String? _shelfId;
  String? _error;
  bool _busy = false;
  Future<void> _run(Future<void> Function() task) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await task();
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool _global = true;

  Map<String, dynamic> _overrides(AppController app) =>
      _global ? app.deviceOverrides : app.settingsOverrides(shelfId: _shelfId);

  Future<void> _save(Map<String, dynamic> values) => _run(
    () => ref
        .read(appControllerProvider)
        .saveSettings(values, global: _global, shelfId: _shelfId),
  );

  Future<void> _threshold(String key, num inherited, dynamic current) async {
    final app = ref.read(appControllerProvider);
    final value = await showDialog<num>(
      context: context,
      builder:
          (_) => _ThresholdDialog(
            settingKey: key,
            value: current ?? inherited,
            configuration: app.runtimeConfiguration,
          ),
    );
    if (value == null || !mounted) return;
    await _save({..._overrides(app), key: value});
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(tr(context, 'deleteStore')),
            content: Text(tr(context, 'deleteStoreWarning')),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(context, 'cancel')),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: Text(
                  tr(context, 'delete'),
                  style: const TextStyle(color: Tokens.danger),
                ),
              ),
            ],
          ),
    );
    if (confirmed != true || !mounted) return;
    await _run(() async {
      await ref.read(appControllerProvider).deleteSelectedStore();
      if (mounted) context.go('/home');
    });
  }

  Future<void> _deleteAll() async {
    final app = ref.read(appControllerProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder:
          (dialog) => AlertDialog(
            title: Text(tr(context, 'deleteAllStoreData')),
            content: SingleChildScrollView(
              child: Text(
                tr(context, 'deleteAllStoreDataWarning', {
                  'backend':
                      app.isStandalone
                          ? tr(context, 'localModeTitle')
                          : app.api.serverAddress ?? tr(context, 'notPaired'),
                }),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialog, false),
                child: Text(tr(context, 'cancel')),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialog, true),
                child: Text(tr(context, 'deleteAllStoreData')),
              ),
            ],
          ),
    );
    if (confirmed == true && mounted) await _run(app.deleteAllStoreData);
  }

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider);
    final global = _global || c.store == null;
    final defaults = c.globalSettings;
    final current = _overrides(c);
    final inherited =
        global
            ? c.runtimeConfiguration.resolve()
            : c.runtimeConfiguration.resolve(
              device: c.deviceOverrides,
              store:
                  _shelfId == null ? null : {'settings': c.settingsOverrides()},
            );
    final rules = c.config['setting_rules'] as Map? ?? {};
    final providers =
        c.config['providers'] is Map ? c.config['providers'] as Map : {};
    final currencies =
        c.config['currencies'] is List ? c.config['currencies'] as List : [];
    final units = c.config['units'] is List ? c.config['units'] as List : [];
    return PageScaffold(
      title: tr(context, 'settings'),
      child: ListView(
        padding: const EdgeInsets.all(Tokens.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ErrorNotice(message: tr(context, _error!)),
          if (c.settingsSyncPending) Text(tr(context, 'settingsSavedLocally')),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'connection'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Tokens.sm),
                SelectableText(
                  c.isStandalone
                      ? tr(context, 'localModeTitle')
                      : c.api.serverAddress ?? tr(context, 'notPaired'),
                ),
                if (!c.isStandalone)
                  Text(
                    tr(context, 'sessionExpiry', {
                      'time':
                          c.api.expiresAt?.toLocal().toString() ??
                          tr(context, 'unknown'),
                    }),
                  ),
                const SizedBox(height: Tokens.md),
                Wrap(
                  spacing: Tokens.sm,
                  runSpacing: Tokens.sm,
                  children: [
                    if (c.supportsStandalone && !c.isStandalone)
                      BrandButton(
                        label: tr(context, 'localModeStart'),
                        icon: Icons.phone_android,
                        outlined: true,
                        onPressed: _busy ? null : () => _run(c.enterStandalone),
                      ),
                    BrandButton(
                      label: tr(context, 'refresh'),
                      icon: Icons.refresh,
                      outlined: true,
                      onPressed: _busy ? null : () => _run(c.refresh),
                    ),
                    BrandButton(
                      label: tr(
                        context,
                        c.isStandalone ? 'localUseRemote' : 'changeLaptop',
                      ),
                      icon: Icons.cloud_sync_outlined,
                      outlined: true,
                      onPressed: _busy ? null : () => _run(c.disconnect),
                    ),
                  ],
                ),
              ],
            ),
          ),
          if (c.stores.isNotEmpty)
            InfoCard(
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: c.store?['id']?.toString(),
                    decoration: InputDecoration(
                      labelText: tr(context, 'activeStore'),
                    ),
                    items:
                        c.stores
                            .map(
                              (s) => DropdownMenuItem(
                                value: s['id'].toString(),
                                child: Text(s['name']?.toString() ?? ''),
                              ),
                            )
                            .toList(),
                    onChanged:
                        _busy
                            ? null
                            : (id) {
                              if (id != null) {
                                setState(() => _shelfId = null);
                                _run(() => c.selectStore(id));
                              }
                            },
                  ),
                  const SizedBox(height: Tokens.md),
                  BrandButton(
                    label: tr(context, 'addStore'),
                    icon: Icons.add_business,
                    outlined: true,
                    onPressed: _busy ? null : () => context.push('/setup'),
                  ),
                ],
              ),
            ),
          if (c.store != null) ...[
            InfoCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tr(context, 'regionalSettings'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: Tokens.md),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    key: ValueKey(c.effectiveLocaleTag),
                    initialValue: c.effectiveLocaleTag,
                    decoration: InputDecoration(
                      labelText: tr(context, 'displayLocale'),
                    ),
                    items:
                        c.supportedLocaleTags
                            .map(
                              (tag) => DropdownMenuItem(
                                value: tag,
                                child: Text(tr(context, 'locale_$tag')),
                              ),
                            )
                            .toList(),
                    onChanged:
                        _busy
                            ? null
                            : (tag) {
                              if (tag != null) _run(() => c.setLocaleTag(tag));
                            },
                  ),
                  const SizedBox(height: Tokens.md),
                  for (final field in [
                    ('currency', currencies),
                    ('unit', units),
                  ]) ...[
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      initialValue:
                          field.$2.contains(c.store?[field.$1])
                              ? c.store![field.$1].toString()
                              : null,
                      decoration: InputDecoration(
                        labelText: tr(context, field.$1),
                      ),
                      items:
                          field.$2
                              .map(
                                (v) => DropdownMenuItem(
                                  value: v.toString(),
                                  child: Text(v.toString()),
                                ),
                              )
                              .toList(),
                      onChanged:
                          _busy
                              ? null
                              : (value) {
                                if (value != null) {
                                  _run(() async {
                                    await c.repository.patch(
                                      '/stores/${c.store!['id']}',
                                      {field.$1: value},
                                    );
                                    await c.refresh();
                                  });
                                }
                              },
                    ),
                    const SizedBox(height: Tokens.md),
                  ],
                ],
              ),
            ),
          ],
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'thresholds'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Tokens.sm),
                Text(tr(context, 'overridePrecedence')),
                const SizedBox(height: Tokens.md),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  key: ValueKey('${c.store?['id']}|$_global|$_shelfId'),
                  initialValue: global ? 'global' : _shelfId ?? 'store',
                  decoration: InputDecoration(
                    labelText: tr(context, 'applyTo'),
                  ),
                  items: [
                    DropdownMenuItem(
                      value: 'global',
                      child: Text(tr(context, 'deviceDefaults')),
                    ),
                    if (c.store != null)
                      DropdownMenuItem(
                        value: 'store',
                        child: Text(tr(context, 'entireStore')),
                      ),
                    if (c.store != null)
                      ...c.shelves.map(
                        (s) => DropdownMenuItem(
                          value: s['id'].toString(),
                          child: Text(s['name']?.toString() ?? ''),
                        ),
                      ),
                  ],
                  onChanged:
                      _busy
                          ? null
                          : (id) => setState(() {
                            _global = id == 'global';
                            _shelfId =
                                id == 'global' || id == 'store' ? null : id;
                          }),
                ),
                for (final entry in defaults.entries)
                  if (rules[entry.key] is Map && entry.value is num)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(tr(context, 'threshold_${entry.key}')),
                      subtitle: Text(
                        tr(
                          context,
                          current.containsKey(entry.key)
                              ? 'overrideValue'
                              : 'inheritedValue',
                          {
                            'value':
                                (current[entry.key] ?? inherited[entry.key])
                                    .toString(),
                          },
                        ),
                      ),
                      trailing: const Icon(Icons.edit_outlined),
                      onTap:
                          _busy || c.monitoringActive
                              ? null
                              : () => _threshold(
                                entry.key,
                                inherited[entry.key] as num,
                                current[entry.key],
                              ),
                    )
                  else if (rules[entry.key] is Map &&
                      (rules[entry.key] as Map)['enum'] is List)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: Tokens.sm),
                      child: DropdownButtonFormField<String>(
                        isExpanded: true,
                        key: ValueKey(
                          '${c.store?['id']}|$_global|$_shelfId|${entry.key}|${current[entry.key]}',
                        ),
                        initialValue:
                            (current[entry.key] ?? inherited[entry.key])
                                .toString(),
                        decoration: InputDecoration(
                          labelText: tr(context, 'threshold_${entry.key}'),
                        ),
                        items:
                            ((rules[entry.key] as Map)['enum'] as List)
                                .map(
                                  (v) => DropdownMenuItem(
                                    value: v.toString(),
                                    child: Text(tr(context, 'option_$v')),
                                  ),
                                )
                                .toList(),
                        onChanged:
                            _busy || c.monitoringActive
                                ? null
                                : (value) {
                                  if (value != null) {
                                    _save({...current, entry.key: value});
                                  }
                                },
                      ),
                    ),
                TextButton(
                  onPressed:
                      _busy || c.monitoringActive ? null : () => _save({}),
                  child: Text(tr(context, 'resetOverrides')),
                ),
                if (c.effectiveSettings()['execution_mode'] ==
                    'standalone_mobile')
                  Text(tr(context, 'localModeHelp')),
                if (c.monitoringActive)
                  Text(tr(context, 'settingsAfterMonitoring')),
                Text(
                  tr(context, 'unsupportedSettings'),
                  style: const TextStyle(color: Tokens.muted),
                ),
              ],
            ),
          ),
          const EvaluationReplayCard(),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'providers'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Tokens.sm),
                Text(tr(context, 'privacySummary')),
                for (final entry in providers.entries)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(tr(context, 'provider_${entry.key}')),
                    subtitle: Text(
                      entry.value is Map
                          ? tr(
                            context,
                            (entry.value as Map)['available'] == true
                                ? 'providerAvailable'
                                : 'providerUnavailable',
                            {
                              'reason':
                                  (entry.value as Map)['reason']?.toString() ??
                                  '',
                            },
                          )
                          : entry.value.toString(),
                    ),
                  ),
                if (providers.isEmpty)
                  Text(tr(context, 'providerDetailsUnavailable')),
                Text(tr(context, 'decisionGrounded')),
              ],
            ),
          ),
          const AiKeysPanel(showRouting: false),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                BrandButton(
                  label: tr(context, 'logout'),
                  icon: Icons.logout,
                  outlined: true,
                  onPressed: _busy ? null : () => _run(c.logout),
                ),
                if (c.store != null)
                  TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    icon: const Icon(
                      Icons.delete_outline,
                      color: Tokens.danger,
                    ),
                    label: Text(
                      tr(context, 'deleteStore'),
                      style: const TextStyle(color: Tokens.danger),
                    ),
                  ),
                TextButton.icon(
                  onPressed:
                      _busy || c.monitoringActive || !c.ready
                          ? null
                          : _deleteAll,
                  icon: const Icon(
                    Icons.delete_sweep_outlined,
                    color: Tokens.danger,
                  ),
                  label: Text(
                    tr(context, 'deleteAllStoreData'),
                    style: const TextStyle(color: Tokens.danger),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog({
    required this.settingKey,
    required this.value,
    required this.configuration,
  });
  final RuntimeConfiguration configuration;
  final String settingKey;
  final num value;
  @override
  State<_ThresholdDialog> createState() => _ThresholdDialogState();
}

class _ThresholdDialogState extends State<_ThresholdDialog> {
  late final _input = TextEditingController(text: widget.value.toString());
  final _form = GlobalKey<FormState>();
  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final rule =
        widget.configuration.schema['setting_rules'][widget.settingKey] as Map;
    final minimum =
        (rule['min'] as num?)?.toDouble() ??
        ((rule['exclusive_min'] as num?)?.toDouble() ?? 0) +
            (rule['type'] == 'integer' ? 1 : .001);
    final maximum = (rule['max'] as num?)?.toDouble();
    final value =
        num.tryParse(_input.text)?.toDouble() ?? widget.value.toDouble();
    return AlertDialog(
      title: Text(tr(context, 'threshold_${widget.settingKey}')),
      content: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _input,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr(context, 'settingValue'),
                ),
                onChanged: (_) => setState(() {}),
                validator: (text) {
                  try {
                    final number = num.tryParse(text ?? '');
                    if (number == null) throw const FormatException();
                    widget.configuration.validate({widget.settingKey: number});
                    return null;
                  } on FormatException {
                    return tr(context, 'invalidSetting');
                  }
                },
              ),
              if (maximum != null && maximum > minimum)
                Semantics(
                  label: tr(context, 'threshold_${widget.settingKey}'),
                  child: Slider(
                    min: minimum,
                    max: maximum,
                    value: value.clamp(minimum, maximum),
                    divisions:
                        rule['type'] == 'integer' && maximum - minimum <= 1000
                            ? (maximum - minimum).round()
                            : null,
                    label: value.toStringAsFixed(
                      rule['type'] == 'integer' ? 0 : 2,
                    ),
                    semanticFormatterCallback:
                        (v) => v.toStringAsFixed(
                          rule['type'] == 'integer' ? 0 : 2,
                        ),
                    onChanged:
                        (v) => setState(
                          () =>
                              _input.text =
                                  rule['type'] == 'integer'
                                      ? v.round().toString()
                                      : v.toStringAsFixed(3),
                        ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(tr(context, 'cancel')),
        ),
        TextButton(
          onPressed: () {
            if (_form.currentState?.validate() == true) {
              Navigator.pop(context, num.parse(_input.text));
            }
          },
          child: Text(tr(context, 'save')),
        ),
      ],
    );
  }
}
