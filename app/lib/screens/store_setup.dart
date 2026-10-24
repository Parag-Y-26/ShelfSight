import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

class StoreSetupScreen extends ConsumerStatefulWidget {
  const StoreSetupScreen({super.key});

  @override
  ConsumerState<StoreSetupScreen> createState() => _StoreSetupScreenState();
}

class _StoreSetupScreenState extends ConsumerState<StoreSetupScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _shelfCount = TextEditingController();
  final _floorName = TextEditingController();
  final _floorWidth = TextEditingController();
  final _floorLength = TextEditingController();
  final _timezone = TextEditingController();
  String? _type;
  String? _goal;
  String? _currency;
  String? _unit;
  String? _error;
  String? _createdStoreId;
  bool _saving = false;

  @override
  void dispose() {
    for (final controller in [
      _name,
      _shelfCount,
      _floorName,
      _floorWidth,
      _floorLength,
      _timezone,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  List<Map<String, dynamic>> _options(dynamic value) =>
      value is List
          ? value
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList()
          : [];

  List<String> _codes(dynamic value) =>
      value is List
          ? value.whereType<String>().where((e) => e.isNotEmpty).toList()
          : [];

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? tr(context, 'rsRequired') : null;

  String? _positive(String? value, {bool integer = false}) {
    final number =
        integer ? int.tryParse(value ?? '') : double.tryParse(value ?? '');
    return number == null || !number.isFinite || number <= 0
        ? tr(context, 'rsPositiveNumber')
        : null;
  }

  Future<void> _save() async {
    if (_saving || !(_form.currentState?.validate() ?? false)) return;
    final count = int.tryParse(_shelfCount.text);
    final width = double.tryParse(_floorWidth.text);
    final length = double.tryParse(_floorLength.text);
    if (_name.text.trim().isEmpty ||
        _floorName.text.trim().isEmpty ||
        _timezone.text.trim().isEmpty ||
        count == null ||
        count < 1 ||
        width == null ||
        !width.isFinite ||
        width <= 0 ||
        length == null ||
        !length.isFinite ||
        length <= 0) {
      setState(() => _error = tr(context, 'rsSetupRequired'));
      return;
    }
    if (_type == null || _goal == null || _currency == null || _unit == null) {
      setState(() => _error = tr(context, 'rsChooseOptions'));
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final app = ref.read(appControllerProvider);
    final identity = app.identityGeneration;
    try {
      if (_createdStoreId == null) {
        final response = await app.repository.post('/stores', {
          'name': _name.text.trim(),
          'type_id': _type,
          'goal_id': _goal,
          'currency': _currency,
          'unit': _unit,
          'timezone': _timezone.text.trim(),
          'shelf_count': count,
          'floor': {
            'name': _floorName.text.trim(),
            'width': width,
            'length': length,
          },
        });
        if (!mounted || identity != app.identityGeneration) return;
        final id = response is Map ? response['id']?.toString() : null;
        if (id == null || id.isEmpty) throw StateError('missing_store_id');
        _createdStoreId = id;
      }
      await app.selectStore(_createdStoreId!);
      if (!mounted || identity != app.identityGeneration) return;
      final shelves = app.shelves;
      if (shelves.isEmpty || shelves.first['id'] == null) {
        context.go('/home');
      } else {
        context.go(
          '/scan/${Uri.encodeComponent(shelves.first['id'].toString())}',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _error = tr(
                context,
                _createdStoreId == null
                    ? 'rsSetupFailed'
                    : 'rsSetupResumeFailed',
              ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final config = app.config;
    final types = _options(config['store_types']);
    final goals = _options(config['goals']);
    final currencies = _codes(config['currencies']);
    final units = _codes(config['units']);
    final theme = Theme.of(context);
    return PageScaffold(
      title: tr(context, 'rsStoreSetup'),
      bottom: BrandButton(
        label: tr(
          context,
          _saving
              ? 'rsSaving'
              : _createdStoreId == null
              ? 'rsContinueScan'
              : 'rsResumeSetup',
        ),
        icon: Icons.camera_alt_outlined,
        onPressed: _saving || types.isEmpty || goals.isEmpty ? null : _save,
      ),
      child: AbsorbPointer(
        absorbing: _saving || _createdStoreId != null,
        child: Form(
          key: _form,
          child: ListView(
            padding: const EdgeInsets.all(Tokens.md),
            children: [
              LinearProgressIndicator(
                value: 0.5,
                borderRadius: BorderRadius.circular(Tokens.radius),
              ),
              const SizedBox(height: Tokens.lg),
              CircleAvatar(
                radius: Tokens.xl,
                backgroundColor: theme.colorScheme.primaryContainer,
                child: Icon(
                  Icons.shelves,
                  size: Tokens.xl,
                  color: theme.colorScheme.primary,
                ),
              ),
              const SizedBox(height: Tokens.md),
              Text(
                tr(context, 'rsTellStore'),
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineSmall,
              ),
              const SizedBox(height: Tokens.lg),
              if (_error != null) ErrorNotice(message: _error!),
              if (types.isEmpty || goals.isEmpty)
                EmptyState(
                  message: tr(context, 'rsConfigUnavailable'),
                  icon: Icons.cloud_off_outlined,
                ),
              InfoCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tr(context, 'rsStoreDetails'),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _name,
                      textCapitalization: TextCapitalization.words,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsStoreName'),
                        prefixIcon: const Icon(Icons.storefront_outlined),
                      ),
                      validator: _required,
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: Tokens.md),
                    Text(
                      tr(context, 'rsStoreType'),
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: Tokens.sm),
                    Wrap(
                      spacing: Tokens.sm,
                      runSpacing: Tokens.sm,
                      children: [
                        for (final option in types)
                          ChoiceChip(
                            label: Text(
                              tr(
                                context,
                                option['label_key']?.toString() ?? 'rsUnknown',
                              ),
                            ),
                            selected: _type == option['id'],
                            onSelected:
                                _saving
                                    ? null
                                    : (_) => setState(
                                      () => _type = option['id']?.toString(),
                                    ),
                          ),
                      ],
                    ),
                    const SizedBox(height: Tokens.md),
                    Text(
                      tr(context, 'rsMainGoal'),
                      style: theme.textTheme.labelLarge,
                    ),
                    const SizedBox(height: Tokens.sm),
                    Wrap(
                      spacing: Tokens.sm,
                      runSpacing: Tokens.sm,
                      children: [
                        for (final option in goals)
                          ChoiceChip(
                            label: Text(
                              tr(
                                context,
                                option['label_key']?.toString() ?? 'rsUnknown',
                              ),
                            ),
                            selected: _goal == option['id'],
                            onSelected:
                                _saving
                                    ? null
                                    : (_) => setState(
                                      () => _goal = option['id']?.toString(),
                                    ),
                          ),
                      ],
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
                      tr(context, 'rsShelfCountQuestion'),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _shelfCount,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsShelfCount'),
                        prefixIcon: const Icon(Icons.inventory_2_outlined),
                      ),
                      validator: (v) => _positive(v, integer: true),
                    ),
                    const SizedBox(height: Tokens.sm),
                    Text(
                      tr(context, 'rsCountExplanation'),
                      style: theme.textTheme.bodySmall,
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
                      tr(context, 'rsFirstFloor'),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _floorName,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsFloorName'),
                        prefixIcon: const Icon(Icons.layers_outlined),
                      ),
                      validator: _required,
                    ),
                    const SizedBox(height: Tokens.md),
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(
                            controller: _floorWidth,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: tr(context, 'rsFloorWidth'),
                            ),
                            validator: _positive,
                          ),
                        ),
                        const SizedBox(width: Tokens.md),
                        Expanded(
                          child: TextFormField(
                            controller: _floorLength,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                            ),
                            decoration: InputDecoration(
                              labelText: tr(context, 'rsFloorLength'),
                            ),
                            validator: _positive,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Tokens.md),
                    DropdownButtonFormField<String>(
                      initialValue: _unit,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsUnits'),
                      ),
                      items: [
                        for (final code in units)
                          DropdownMenuItem(
                            value: code,
                            child: Text(tr(context, 'rsUnit_$code')),
                          ),
                      ],
                      onChanged:
                          _saving ? null : (v) => setState(() => _unit = v),
                      validator: _required,
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
                      tr(context, 'rsLocaleSettings'),
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: Tokens.md),
                    DropdownButtonFormField<String>(
                      initialValue: _currency,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsCurrency'),
                      ),
                      items: [
                        for (final code in currencies)
                          DropdownMenuItem(value: code, child: Text(code)),
                      ],
                      onChanged:
                          _saving ? null : (v) => setState(() => _currency = v),
                      validator: _required,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _timezone,
                      autocorrect: false,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsTimezone'),
                        helperText: tr(context, 'rsTimezoneHelp'),
                      ),
                      validator: _required,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Tokens.lg),
            ],
          ),
        ),
      ),
    );
  }
}
