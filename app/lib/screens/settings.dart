import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

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

  Future<void> _threshold(String key, num inherited, dynamic current) async {
    final value = await showDialog<num>(
      context: context,
      builder: (_) =>
          _ThresholdDialog(settingKey: key, value: current ?? inherited),
    );
    if (value == null || !mounted) return;
    final c = ref.read(appControllerProvider);
    final target = _shelfId == null
        ? c.store
        : c.shelves.where((s) => s['id'] == _shelfId).firstOrNull;
    final settings = Map<String, dynamic>.from(
      target?['settings'] is Map ? target!['settings'] as Map : {},
    );
    settings[key] = value;
    await _run(() async {
      await c.api.patch(
        _shelfId == null ? '/stores/${c.store!['id']}' : '/shelves/$_shelfId',
        {'settings': settings},
      );
      await c.refresh();
    });
  }

  Future<void> _resetOverrides() async {
    final c = ref.read(appControllerProvider);
    final target = _shelfId == null
        ? c.store
        : c.shelves.where((s) => s['id'] == _shelfId).firstOrNull;
    final settings = Map<String, dynamic>.from(
      target?['settings'] is Map ? target!['settings'] as Map : {},
    );
    final defaults = c.config['thresholds'];
    if (defaults is Map) {
      for (final key in defaults.keys) {
        settings.remove(key);
      }
    }
    await _run(() async {
      await c.api.patch(
        _shelfId == null ? '/stores/${c.store!['id']}' : '/shelves/$_shelfId',
        {'settings': settings},
      );
      await c.refresh();
    });
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
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

  @override
  Widget build(BuildContext context) {
    final c = ref.watch(appControllerProvider);
    final defaults = c.config['thresholds'] is Map
        ? c.config['thresholds'] as Map
        : {};
    final storeSettings = c.store?['settings'] is Map
        ? c.store!['settings'] as Map
        : {};
    final shelf = c.shelves.where((s) => s['id'] == _shelfId).firstOrNull;
    final shelfSettings = shelf?['settings'] is Map
        ? shelf!['settings'] as Map
        : {};
    final providers = c.config['providers'] is Map
        ? c.config['providers'] as Map
        : {};
    final currencies = c.config['currencies'] is List
        ? c.config['currencies'] as List
        : [];
    final units = c.config['units'] is List ? c.config['units'] as List : [];
    return PageScaffold(
      title: tr(context, 'settings'),
      child: ListView(
        padding: const EdgeInsets.all(Tokens.md),
        children: [
          if (_busy) const LinearProgressIndicator(),
          if (_error != null) ErrorNotice(message: tr(context, _error!)),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tr(context, 'connection'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Tokens.sm),
                SelectableText(c.api.serverAddress ?? tr(context, 'notPaired')),
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
                    BrandButton(
                      label: tr(context, 'refresh'),
                      icon: Icons.refresh,
                      outlined: true,
                      onPressed: _busy ? null : () => _run(c.refresh),
                    ),
                    BrandButton(
                      label: tr(context, 'changeLaptop'),
                      icon: Icons.phonelink_setup,
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
                    initialValue: c.store?['id']?.toString(),
                    decoration: InputDecoration(
                      labelText: tr(context, 'activeStore'),
                    ),
                    items: c.stores
                        .map(
                          (s) => DropdownMenuItem(
                            value: s['id'].toString(),
                            child: Text(s['name']?.toString() ?? ''),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
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
                    key: ValueKey(c.effectiveLocaleTag),
                    initialValue: c.effectiveLocaleTag,
                    decoration: InputDecoration(
                      labelText: tr(context, 'displayLocale'),
                    ),
                    items: c.supportedLocaleTags
                        .map(
                          (tag) => DropdownMenuItem(
                            value: tag,
                            child: Text(tr(context, 'locale_$tag')),
                          ),
                        )
                        .toList(),
                    onChanged: _busy
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
                      initialValue: field.$2.contains(c.store?[field.$1])
                          ? c.store![field.$1].toString()
                          : null,
                      decoration: InputDecoration(
                        labelText: tr(context, field.$1),
                      ),
                      items: field.$2
                          .map(
                            (v) => DropdownMenuItem(
                              value: v.toString(),
                              child: Text(v.toString()),
                            ),
                          )
                          .toList(),
                      onChanged: _busy
                          ? null
                          : (value) {
                              if (value != null) {
                                _run(() async {
                                  await c.api.patch(
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
                    initialValue: _shelfId ?? '',
                    decoration: InputDecoration(
                      labelText: tr(context, 'applyTo'),
                    ),
                    items: [
                      DropdownMenuItem(
                        value: '',
                        child: Text(tr(context, 'entireStore')),
                      ),
                      ...c.shelves.map(
                        (s) => DropdownMenuItem(
                          value: s['id'].toString(),
                          child: Text(s['name']?.toString() ?? ''),
                        ),
                      ),
                    ],
                    onChanged: _busy
                        ? null
                        : (id) =>
                              setState(() => _shelfId = id == '' ? null : id),
                  ),
                  const SizedBox(height: Tokens.sm),
                  for (final entry in defaults.entries)
                    if (entry.value is num)
                      Builder(
                        builder: (context) {
                          final key = entry.key.toString();
                          final inherited = storeSettings[key] is num
                              ? storeSettings[key] as num
                              : entry.value as num;
                          final current = _shelfId == null
                              ? storeSettings[key]
                              : shelfSettings[key];
                          return ListTile(
                            contentPadding: EdgeInsets.zero,
                            title: Text(tr(context, 'threshold_$key')),
                            subtitle: Text(
                              tr(
                                context,
                                current == null
                                    ? 'inheritedValue'
                                    : 'overrideValue',
                                {'value': (current ?? inherited).toString()},
                              ),
                            ),
                            trailing: const Icon(Icons.edit_outlined),
                            onTap: _busy
                                ? null
                                : () => _threshold(key, inherited, current),
                          );
                        },
                      ),
                  TextButton(
                    onPressed: _busy ? null : _resetOverrides,
                    child: Text(tr(context, 'resetOverrides')),
                  ),
                  Text(
                    tr(context, 'unsupportedSettings'),
                    style: const TextStyle(color: Tokens.muted),
                  ),
                ],
              ),
            ),
          ],
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
                                    (entry.value as Map)['reason']
                                        ?.toString() ??
                                    '',
                              },
                            )
                          : entry.value.toString(),
                    ),
                  ),
                if (providers.isEmpty)
                  Text(tr(context, 'providerDetailsUnavailable')),
                Text(tr(context, 'decisionDisabled')),
              ],
            ),
          ),
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ThresholdDialog extends StatefulWidget {
  const _ThresholdDialog({required this.settingKey, required this.value});
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
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr(context, 'threshold_${widget.settingKey}')),
    content: Form(
      key: _form,
      child: TextFormField(
        controller: _input,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(labelText: tr(context, 'settingValue')),
        validator: (value) {
          final number = num.tryParse(value ?? '');
          final key = widget.settingKey;
          if (number == null ||
              !number.isFinite ||
              number < 0 ||
              (key == 'minimum_confidence' && number > 1) ||
              ([
                    'monitoring_interval_ms',
                    'frame_max_dimension',
                  ].contains(key) &&
                  number <= 0) ||
              ([
                    'low_stock',
                    'frame_max_dimension',
                    'monitoring_interval_ms',
                  ].contains(key) &&
                  number % 1 != 0)) {
            return tr(context, 'invalidSetting');
          }
          return null;
        },
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
