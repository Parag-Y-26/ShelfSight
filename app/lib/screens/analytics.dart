import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';
import '../widgets/decision_panel.dart';
import '../core/csv_export.dart';

class AnalyticsScreen extends ConsumerStatefulWidget {
  const AnalyticsScreen({super.key, this.now = DateTime.now});

  final DateTime Function() now;

  @override
  ConsumerState<AnalyticsScreen> createState() => _AnalyticsScreenState();
}

class _AnalyticsScreenState extends ConsumerState<AnalyticsScreen> {
  Map<String, dynamic>? _data;
  String? _periodId;
  DateTimeRange? _customRange;
  DateTime? _start;
  DateTime? _end;
  DateTime? _updatedAt;
  String? _errorKey;
  bool _loading = false;
  bool _copying = false;
  bool _fromCache = false;
  int _generation = 0;
  String? _storeId;
  late final AppController _app;
  String? _observedScope;
  String _scope() =>
      '${_app.identityGeneration}|${_app.store?['id']}|${_app.ledgerRevision}';
  @override
  void initState() {
    super.initState();
    _app = ref.read(appControllerProvider);
    _observedScope = _scope();
    _app.addListener(_ledgerChanged);
  }

  void _ledgerChanged() {
    final scope = _scope();
    if (scope == _observedScope) return;
    _observedScope = scope;
    ++_generation;
    _data = null;
    _errorKey = null;
    _loading = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || scope != _scope()) return;
      setState(() {
        _storeId = _app.store?['id']?.toString();
      });
      _load();
    });
  }

  @override
  void dispose() {
    _app.removeListener(_ledgerChanged);
    ++_generation;
    super.dispose();
  }

  List<Map<String, dynamic>> _maps(dynamic value) =>
      value is List
          ? value
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : [];

  num? _number(dynamic value) => value is num && value.isFinite ? value : null;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final app = ref.read(appControllerProvider);
    final id = app.store?['id']?.toString();
    if (_storeId == id && _periodId != null) return;
    _storeId = id;
    final periods = _maps(app.config['periods']);
    if (periods.isEmpty) return;
    _periodId = periods.first['id']?.toString();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Map<String, dynamic>? _currentPeriod() {
    final matches = _maps(
      ref.read(appControllerProvider).config['periods'],
    ).where((p) => p['id']?.toString() == _periodId);
    return matches.isEmpty ? null : matches.first;
  }

  bool _setRange() {
    final period = _currentPeriod();
    if (period == null) return false;
    if (period['days'] == null) {
      final range = _customRange;
      if (range == null) return false;
      _start =
          DateTime(
            range.start.year,
            range.start.month,
            range.start.day,
          ).toUtc();
      _end =
          DateTime(range.end.year, range.end.month, range.end.day + 1).toUtc();
      return true;
    }
    final days = _number(period['days'])?.toInt();
    if (days == null || days <= 0) return false;
    final now = widget.now();
    _start = DateTime(now.year, now.month, now.day - days + 1).toUtc();
    _end = DateTime(now.year, now.month, now.day + 1).toUtc();
    return true;
  }

  Future<void> _selectPeriod(Map<String, dynamic> period) async {
    if (_loading || _copying) return;
    final id = period['id']?.toString();
    if (id == null) return;
    if (period['days'] == null) {
      final today = widget.now();
      final last = DateTime(today.year, today.month, today.day);
      final previous = _customRange;
      final selected = await showDateRangePicker(
        context: context,
        firstDate: DateTime(1),
        lastDate: last,
        initialDateRange: previous ?? DateTimeRange(start: last, end: last),
        helpText: tr(context, 'rsChooseDates'),
        saveText: tr(context, 'rsApply'),
      );
      if (selected == null || !mounted) return;
      _customRange = selected;
    }
    setState(() {
      _periodId = id;
      _data = null;
      _errorKey = null;
    });
    await _load();
  }

  Map<String, dynamic>? _validated(dynamic response) {
    if (response is! Map) return null;
    final result = Map<String, dynamic>.from(response);
    if (_number(result['visits']) == null ||
        _number(result['total_dwell_seconds']) == null ||
        _number(result['coverage_seconds']) == null ||
        result['shelves'] is! List ||
        result['inventory'] is! List) {
      return null;
    }
    return result;
  }

  Future<void> _load() async {
    final app = ref.read(appControllerProvider);
    final storeId = app.store?['id']?.toString();
    if (storeId == null || !_setRange()) return;
    final start = _start?.toIso8601String();
    final end = _end?.toIso8601String();
    if (start == null || end == null) return;
    final generation = ++_generation;
    final identity = app.identityGeneration;
    final cacheKey = 'analytics:$storeId:$start:$end';
    setState(() {
      _loading = true;
      _errorKey = null;
    });
    try {
      Map<String, dynamic>? cached;
      try {
        cached = await app.readCached(cacheKey);
      } catch (_) {
        // A damaged optional cache must not prevent a fresh server query.
      }
      if (!mounted ||
          generation != _generation ||
          (identity != app.identityGeneration || app.store?['id'] != storeId)) {
        return;
      }
      final value = _validated(cached?['value']);
      if (value != null) {
        setState(() {
          _data = value;
          _fromCache = true;
          _updatedAt = DateTime.tryParse(
            cached?['updated_at']?.toString() ?? '',
          );
        });
      }
      final response = await app.repository.get(
        '/stores/${Uri.encodeComponent(storeId)}/analytics',
        query: {'start': start, 'end': end},
      );
      final valid = _validated(response);
      if (valid == null) throw const FormatException('analytics_response');
      try {
        if (!mounted ||
            (identity != app.identityGeneration || app.store?['id'] != storeId)) {
          return;
        }
        await app.cacheValue(cacheKey, valid);
      } catch (_) {
        // Keep the successful online result visible when local storage fails.
      }
      if (!mounted ||
          generation != _generation ||
          (identity != app.identityGeneration || app.store?['id'] != storeId)) {
        return;
      }
      setState(() {
        _data = valid;
        _fromCache = false;
        _updatedAt =
            DateTime.tryParse(valid['generated_at']?.toString() ?? '') ??
            widget.now();
      });
    } catch (_) {
      if (mounted && generation == _generation) {
        setState(
          () =>
              _errorKey =
                  _data == null ? 'rsAnalyticsFailed' : 'rsAnalyticsStale',
        );
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _copyExport({bool share = false}) async {
    final app = ref.read(appControllerProvider);
    final identity = app.identityGeneration;
    final id = app.store?['id']?.toString();
    if (_copying || _loading || id == null || _start == null || _end == null) {
      return;
    }
    setState(() => _copying = true);
    try {
      final csv = await app.repository.text(
        '/stores/${Uri.encodeComponent(id)}/analytics/export',
        query: {
          'start': _start!.toIso8601String(),
          'end': _end!.toIso8601String(),
        },
      );
      if (!mounted ||
          (identity != app.identityGeneration || app.store?['id'] != id)) {
        return;
      }
      if (share) {
        final box = context.findRenderObject() as RenderBox;
        await exportCsv(
          csv,
          'shelfsight_analytics_${_start!.toIso8601String().substring(0, 10)}.csv',
          origin: box.localToGlobal(Offset.zero) & box.size,
        );
      } else {
        await Clipboard.setData(ClipboardData(text: csv));
      }
      if (mounted && !share) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(tr(context, 'rsCsvCopied'))));
      }
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'rsExportFailed');
    } finally {
      if (mounted) setState(() => _copying = false);
    }
  }

  String _format(num? value, {bool decimal = false}) {
    if (value == null) return tr(context, 'rsUnknown');
    final number = NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    )..maximumFractionDigits = decimal ? 1 : 0;
    return number.format(value);
  }

  String _seconds(num? value) =>
      value == null
          ? tr(context, 'rsUnknown')
          : tr(context, 'rsSeconds', {'value': _format(value, decimal: true)});

  String _timestamp(dynamic raw) {
    final date = DateTime.tryParse(raw?.toString() ?? '');
    return date == null
        ? tr(context, 'rsUnknown')
        : DateFormat.yMMMd(
          Localizations.localeOf(context).toString(),
        ).add_Hm().format(date.toLocal());
  }

  Widget _metric({
    required String label,
    required String value,
    required IconData icon,
  }) {
    final theme = Theme.of(context);
    return InfoCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: theme.colorScheme.primary),
          const SizedBox(height: Tokens.sm),
          Text(label, style: theme.textTheme.labelLarge),
          const SizedBox(height: Tokens.sm),
          Text(value, style: theme.textTheme.headlineSmall),
        ],
      ),
    );
  }

  Widget _unavailable(String label, IconData icon) => InfoCard(
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: Theme.of(context).colorScheme.outline),
        const SizedBox(width: Tokens.md),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: Tokens.xs),
              Text(
                tr(context, 'rsNotMeasured'),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final theme = Theme.of(context);
    final data = _storeId == app.store?['id'] ? _data : null;
    final periods = _maps(app.config['periods']);
    final shelves = _maps(data?['shelves']);
    final ranking = [...shelves]..sort(
      (a, b) =>
          (_number(b['visits']) ?? 0).compareTo(_number(a['visits']) ?? 0),
    );
    final maxVisits =
        ranking.isEmpty ? 0 : _number(ranking.first['visits']) ?? 0;
    final inventory =
        _maps(data?['inventory']).map((item) {
          final shelf =
              app.shelves.where((s) => s['id'] == item['shelf_id']).firstOrNull;
          final threshold = app.effectiveSettings(shelf)['low_stock_threshold'];
          return {
            ...item,
            if (threshold is num) 'low_stock_threshold': threshold,
          };
        }).toList();
    final lowInventory =
        inventory.where((e) {
          final quantity = _number(e['quantity']);
          final threshold = _number(e['low_stock_threshold']);
          return quantity != null && threshold != null && quantity <= threshold;
        }).toList();
    return PageScaffold(
      title: tr(context, 'rsAnalytics'),
      actions: [
        IconButton(
          onPressed: _loading ? null : _load,
          tooltip: tr(context, 'rsRefresh'),
          icon: const Icon(Icons.refresh),
        ),
        IconButton(
          onPressed: _copying || _loading || data == null ? null : _copyExport,
          tooltip: tr(context, 'rsCopyCsv'),
          icon: const Icon(Icons.content_copy_outlined),
        ),
      ],
      child: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.all(Tokens.md),
          children: [
            if (app.store == null) ...[
              EmptyState(
                message: tr(context, 'rsSetupBeforeAnalytics'),
                icon: Icons.storefront_outlined,
              ),
              BrandButton(
                label: tr(context, 'rsStoreSetup'),
                onPressed: () => context.go('/setup'),
              ),
            ] else ...[
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final period in periods) ...[
                      ChoiceChip(
                        label: Text(
                          tr(
                            context,
                            period['label_key']?.toString() ?? 'rsUnknown',
                          ),
                        ),
                        selected: _periodId == period['id']?.toString(),
                        onSelected:
                            _loading ? null : (_) => _selectPeriod(period),
                      ),
                      const SizedBox(width: Tokens.sm),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: Tokens.sm),
              Text(
                tr(context, 'rsDateTimezone'),
                style: theme.textTheme.bodySmall,
              ),
              if (_start != null && _end != null)
                Padding(
                  padding: const EdgeInsets.only(top: Tokens.xs),
                  child: Text(
                    tr(context, 'rsDateRange', {
                      'start': DateFormat.yMMMd(
                        Localizations.localeOf(context).toString(),
                      ).format(_start!.toLocal()),
                      'end': DateFormat.yMMMd(
                        Localizations.localeOf(context).toString(),
                      ).format(_inclusiveEnd()),
                    }),
                    style: theme.textTheme.labelMedium,
                  ),
                ),
              if (_updatedAt != null)
                Padding(
                  padding: const EdgeInsets.only(top: Tokens.xs),
                  child: Text(
                    tr(context, _fromCache ? 'rsCachedAt' : 'rsUpdatedAt', {
                      'time': _timestamp(_updatedAt!.toIso8601String()),
                    }),
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              const SizedBox(height: Tokens.md),
              if (_loading) const LinearProgressIndicator(),
              if (_errorKey != null)
                ErrorNotice(message: tr(context, _errorKey!)),
              if (data == null && !_loading)
                EmptyState(
                  message: tr(context, 'rsNoAnalytics'),
                  icon: Icons.insights_outlined,
                ),
              if (data != null) ...[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: _metric(
                        label: tr(context, 'rsShelfVisits'),
                        value: _format(_number(data['visits'])),
                        icon: Icons.directions_walk_outlined,
                      ),
                    ),
                    const SizedBox(width: Tokens.md),
                    Expanded(
                      child: _metric(
                        label: tr(context, 'rsTotalDwell'),
                        value: _seconds(_number(data['total_dwell_seconds'])),
                        icon: Icons.timelapse_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Tokens.md),
                Wrap(
                  spacing: Tokens.md,
                  runSpacing: Tokens.md,
                  children: [
                    _metric(
                      label: tr(context, 'meanDwell'),
                      value: _seconds(_number(data['mean_dwell_seconds'])),
                      icon: Icons.timelapse_outlined,
                    ),
                    _metric(
                      label: tr(context, 'medianDwell'),
                      value: _seconds(_number(data['median_dwell_seconds'])),
                      icon: Icons.av_timer_outlined,
                    ),
                  ],
                ),
                InfoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'rsMostVisited'),
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: Tokens.sm),
                      Text(
                        tr(context, 'rsVisitsDefinition'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: Tokens.md),
                      if (maxVisits <= 0)
                        EmptyState(
                          message: tr(context, 'rsNoVisitData'),
                          icon: Icons.directions_walk_outlined,
                        ),
                      if (maxVisits > 0)
                        for (final shelf in ranking)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Tokens.md),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        shelf['name']?.toString() ??
                                            tr(context, 'rsShelf'),
                                        style: theme.textTheme.titleSmall,
                                      ),
                                    ),
                                    Text(
                                      _format(_number(shelf['visits'])),
                                      style: theme.textTheme.labelLarge,
                                    ),
                                  ],
                                ),
                                const SizedBox(height: Tokens.sm),
                                LinearProgressIndicator(
                                  value:
                                      ((_number(shelf['visits']) ?? 0) /
                                              maxVisits)
                                          .clamp(0, 1)
                                          .toDouble(),
                                  minHeight: Tokens.sm,
                                  color: Tokens.blue,
                                  borderRadius: BorderRadius.circular(
                                    Tokens.md,
                                  ),
                                ),
                                const SizedBox(height: Tokens.xs),
                                Text(
                                  tr(context, 'rsDwellSummary', {
                                    'total': _seconds(
                                      _number(shelf['dwell_seconds']),
                                    ),
                                    'average': _seconds(
                                      (_number(shelf['visits']) ?? 0) > 0 &&
                                              _number(shelf['dwell_seconds']) !=
                                                  null
                                          ? _number(shelf['dwell_seconds'])! /
                                              _number(shelf['visits'])!
                                          : null,
                                    ),
                                  }),
                                  style: theme.textTheme.bodySmall,
                                ),
                              ],
                            ),
                          ),
                    ],
                  ),
                ),
                const SizedBox(height: Tokens.md),
                InfoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'rsShelfExposure'),
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: Tokens.sm),
                      Text(
                        tr(context, 'rsExposureDefinition'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: Tokens.md),
                      if ((_number(data['coverage_seconds']) ?? 0) <= 0)
                        EmptyState(
                          message: tr(context, 'rsNoCoverageData'),
                          icon: Icons.videocam_off_outlined,
                        )
                      else ...[
                        Text(
                          tr(context, 'rsCameraCoverage', {
                            'duration': _seconds(
                              _number(data['coverage_seconds']),
                            ),
                          }),
                          style: theme.textTheme.titleSmall,
                        ),
                        const SizedBox(height: Tokens.md),
                        for (final shelf in shelves)
                          Padding(
                            padding: const EdgeInsets.only(bottom: Tokens.sm),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    shelf['name']?.toString() ??
                                        tr(context, 'rsShelf'),
                                  ),
                                ),
                                Text(
                                  _seconds(_number(shelf['exposure_seconds'])),
                                  style: theme.textTheme.labelLarge,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: Tokens.md),
                InfoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'rsRecordedInventory'),
                        style: theme.textTheme.titleLarge,
                      ),
                      const SizedBox(height: Tokens.sm),
                      Text(
                        tr(context, 'rsInventoryDefinition'),
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: Tokens.md),
                      if (inventory.isEmpty)
                        EmptyState(
                          message: tr(context, 'rsNoInventoryData'),
                          icon: Icons.inventory_2_outlined,
                        ),
                      for (final item in inventory) ...[
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.inventory_2_outlined,
                              color:
                                  (_number(item['quantity']) ?? -1) == 0
                                      ? Tokens.danger
                                      : lowInventory.contains(item)
                                      ? Tokens.warning
                                      : theme.colorScheme.primary,
                            ),
                            const SizedBox(width: Tokens.sm),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    item['name']?.toString() ??
                                        tr(context, 'rsUnknownProduct'),
                                    style: theme.textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: Tokens.xs),
                                  Text(
                                    tr(context, 'rsLastCounted', {
                                      'time': _timestamp(
                                        item['last_corrected_at'],
                                      ),
                                    }),
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: Tokens.sm),
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(
                                  tr(context, 'rsUnitsCount', {
                                    'count': _format(_number(item['quantity'])),
                                  }),
                                  style: theme.textTheme.labelLarge,
                                ),
                                if (_number(item['quantity']) == 0)
                                  Text(
                                    tr(context, 'rsOutOfStock'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Tokens.danger,
                                    ),
                                  )
                                else if (lowInventory.contains(item))
                                  Text(
                                    tr(context, 'rsLowStock'),
                                    style: theme.textTheme.labelSmall?.copyWith(
                                      color: Tokens.warning,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: Tokens.sm),
                          child: Divider(),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
              const SizedBox(height: Tokens.md),
              _unavailable(
                tr(context, 'slotExposure'),
                Icons.visibility_outlined,
              ),
              Text(tr(context, 'slotExposureHelp')),
              for (final item in inventory)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Tokens.sm),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${item['name']} · ${tr(context, 'rsRow')} ${item['row'] ?? tr(context, 'unknown')} / ${tr(context, 'rsSlot')} ${item['slot'] ?? tr(context, 'unknown')}',
                      ),
                      Text(_seconds(_number(item['slot_exposure_seconds']))),
                    ],
                  ),
                ),
              const SizedBox(height: Tokens.md),
              _unavailable(
                tr(context, 'rsEstimatedSales'),
                Icons.payments_outlined,
              ),
              const SizedBox(height: Tokens.md),
              _unavailable(
                tr(context, 'rsMostPicked'),
                Icons.shopping_bag_outlined,
              ),
              const SizedBox(height: Tokens.md),
              _unavailable(tr(context, 'rsPutBack'), Icons.undo_outlined),
              const SizedBox(height: Tokens.lg),
              const DecisionPanel(),
              const SizedBox(height: Tokens.md),
              BrandButton(
                label: tr(context, 'shareCsv'),
                icon: Icons.ios_share_outlined,
                onPressed:
                    _copying || _loading || data == null
                        ? null
                        : () => _copyExport(share: true),
              ),
            ],
          ],
        ),
      ),
    );
  }

  DateTime _inclusiveEnd() {
    final end = _end!.toLocal();
    return DateTime(end.year, end.month, end.day - 1);
  }
}
