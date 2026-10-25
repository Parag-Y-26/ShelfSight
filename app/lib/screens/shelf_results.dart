import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';
import 'product.dart';
import 'shelf_scan.dart';

class ShelfResultsScreen extends ConsumerStatefulWidget {
  const ShelfResultsScreen({super.key, required this.shelfId, this.candidates});
  final String shelfId;
  final List<Map<String, dynamic>>? candidates;

  @override
  ConsumerState<ShelfResultsScreen> createState() => _ShelfResultsScreenState();
}

class _ShelfDraft {
  _ShelfDraft({
    required this.product,
    this.itemId,
    this.productId,
    this.row,
    this.slot,
    this.quantity,
    this.confidence,
    this.dirty = false,
    this.productDirty = false,
  });
  final Map<String, dynamic> product;
  String? itemId;
  String? productId;
  int? row;
  int? slot;
  int? quantity;
  num? confidence;
  bool dirty;
  bool productDirty;
  final key = GlobalKey();
  String get name => product['name']?.toString() ?? '';
}

class _ShelfResultsScreenState extends ConsumerState<ShelfResultsScreen> {
  late String _shelfId;
  List<_ShelfDraft> _drafts = [];
  int? _selected;
  bool _saving = false;
  bool _allowPop = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _shelfId = widget.shelfId;
    _loadFromSnapshot();
    final candidates = widget.candidates;
    if (candidates != null) {
      for (var i = 0; i < candidates.length; i++) {
        final candidate = Map<String, dynamic>.from(candidates[i]);
        final barcode = candidate['barcode']?.toString();
        final name = candidate['name']?.toString().trim().toLowerCase();
        final matching = _drafts.where(
          (draft) =>
              (barcode != null &&
                  barcode.isNotEmpty &&
                  draft.product['barcode']?.toString() == barcode) ||
              (name != null &&
                  name.isNotEmpty &&
                  draft.name.trim().toLowerCase() == name),
        );
        if (matching.isNotEmpty) {
          final existing = matching.first;
          existing.confidence =
              candidate['confidence'] is num
                  ? candidate['confidence'] as num
                  : null;
          existing.row = _integer(candidate['row']) ?? existing.row;
          existing.slot = _integer(candidate['slot']) ?? existing.slot;
          existing.dirty = true;
          continue;
        }
        _drafts.add(
          _ShelfDraft(
            product: candidate,
            row: _integer(candidate['row']) ?? 1,
            slot: _integer(candidate['slot']) ?? i + 1,
            confidence:
                candidate['confidence'] is num
                    ? candidate['confidence'] as num
                    : null,
            dirty: true,
            productDirty: true,
          ),
        );
      }
    }
  }

  int? _integer(dynamic value) =>
      value is int
          ? value
          : value is num && value == value.roundToDouble()
          ? value.toInt()
          : int.tryParse(value?.toString() ?? '');

  void _loadFromSnapshot({bool preserveDrafts = false}) {
    final app = ref.read(appControllerProvider);
    final existing = preserveDrafts ? _drafts : <_ShelfDraft>[];
    final known = existing.map((e) => e.itemId).whereType<String>().toSet();
    final loaded = <_ShelfDraft>[];
    for (final item in app.items.where(
      (e) => e['shelf_id']?.toString() == _shelfId,
    )) {
      final itemId = item['id']?.toString();
      if (itemId != null && known.contains(itemId)) continue;
      final products = app.products.where(
        (p) => p['id']?.toString() == item['product_id']?.toString(),
      );
      final nested = item['product'];
      final product =
          products.isNotEmpty
              ? Map<String, dynamic>.from(products.first)
              : nested is Map
              ? Map<String, dynamic>.from(nested)
              : <String, dynamic>{};
      loaded.add(
        _ShelfDraft(
          product: product,
          itemId: itemId,
          productId: item['product_id']?.toString(),
          row: _integer(item['row']),
          slot: _integer(item['slot']),
          quantity: _integer(item['quantity']),
        ),
      );
    }
    _drafts = [...existing, ...loaded];
    _drafts.sort((a, b) {
      final row = (a.row ?? 0).compareTo(b.row ?? 0);
      return row != 0 ? row : (a.slot ?? 0).compareTo(b.slot ?? 0);
    });
    _selected = null;
  }

  bool get _hasChanges =>
      _drafts.any((e) => e.dirty || e.productDirty || e.itemId == null);

  Future<bool> _discardChanges() async {
    if (!_hasChanges) return true;
    return await showDialog<bool>(
          context: context,
          builder:
              (context) => AlertDialog(
                title: Text(tr(context, 'rsUnsavedTitle')),
                content: Text(tr(context, 'rsUnsavedBody')),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(tr(context, 'rsKeepEditing')),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(tr(context, 'rsDiscard')),
                  ),
                ],
              ),
        ) ??
        false;
  }

  Future<void> _switchShelf(String id) async {
    if (_saving || id == _shelfId || !await _discardChanges() || !mounted) {
      return;
    }
    setState(() {
      _shelfId = id;
      _error = null;
      _loadFromSnapshot();
    });
  }

  Future<void> _scan({bool next = false}) async {
    if (_saving || !await _discardChanges() || !mounted) return;
    var shelfId = _shelfId;
    if (next) {
      final shelves = ref.read(appControllerProvider).shelves;
      final index = shelves.indexWhere((e) => e['id']?.toString() == _shelfId);
      if (index >= 0 && index + 1 < shelves.length) {
        shelfId = shelves[index + 1]['id']?.toString() ?? _shelfId;
      }
    }
    await Navigator.of(context).pushReplacement(
      MaterialPageRoute<void>(
        builder: (_) => ShelfScanScreen(shelfId: shelfId),
      ),
    );
  }

  Future<void> _addShelf() async {
    final app = ref.read(appControllerProvider);
    final storeId = app.store?['id']?.toString();
    if (_saving || storeId == null) return;
    final name = TextEditingController();
    String? floorId =
        app.floors.isEmpty ? null : app.floors.first['id']?.toString();
    final form = GlobalKey<FormState>();
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder:
          (dialogContext) => StatefulBuilder(
            builder:
                (context, change) => AlertDialog(
                  title: Text(tr(context, 'rsAddShelf')),
                  content: Form(
                    key: form,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextFormField(
                          controller: name,
                          autofocus: true,
                          decoration: InputDecoration(
                            labelText: tr(context, 'rsShelfName'),
                          ),
                          validator:
                              (value) =>
                                  value == null || value.trim().isEmpty
                                      ? tr(context, 'rsRequired')
                                      : null,
                        ),
                        const SizedBox(height: Tokens.md),
                        DropdownButtonFormField<String>(
                          initialValue: floorId,
                          decoration: InputDecoration(
                            labelText: tr(context, 'rsFloor'),
                          ),
                          items: [
                            for (final floor in app.floors)
                              if (floor['id'] != null)
                                DropdownMenuItem(
                                  value: floor['id'].toString(),
                                  child: Text(
                                    floor['name']?.toString() ??
                                        tr(context, 'rsUnknown'),
                                  ),
                                ),
                          ],
                          onChanged: (value) => change(() => floorId = value),
                          validator:
                              (value) =>
                                  value == null
                                      ? tr(context, 'rsRequired')
                                      : null,
                        ),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(tr(context, 'rsCancel')),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (form.currentState?.validate() ?? false) {
                          Navigator.pop(dialogContext, {
                            'name': name.text.trim(),
                            'floor_id': floorId,
                          });
                        }
                      },
                      child: Text(tr(context, 'rsCreateShelf')),
                    ),
                  ],
                ),
          ),
    );
    name.dispose();
    if (result == null || !mounted) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await app.repository.post(
        '/stores/${Uri.encodeComponent(storeId)}/shelves',
        result,
      );
      await app.refresh();
    } catch (_) {
      if (mounted) setState(() => _error = tr(context, 'rsAddShelfFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _addProduct() async {
    if (_saving) return;
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(builder: (_) => ProductScreen(shelfId: _shelfId)),
    );
    if (!mounted) return;
    setState(() => _loadFromSnapshot(preserveDrafts: true));
  }

  Future<void> _editDetails(_ShelfDraft draft) async {
    if (_saving || draft.itemId == null) return;
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder:
            (_) => ProductScreen(
              shelfId: _shelfId,
              item: {
                'id': draft.itemId,
                'product_id': draft.productId,
                'row': draft.row,
                'slot': draft.slot,
                'quantity': draft.quantity,
                'product': draft.product,
              },
            ),
      ),
    );
    if (saved != true || !mounted) return;
    setState(() {
      _drafts.remove(draft);
      _loadFromSnapshot(preserveDrafts: true);
    });
  }

  Future<void> _edit(_ShelfDraft draft) async {
    if (_saving) return;
    final form = GlobalKey<FormState>();
    final name = TextEditingController(text: draft.name);
    final row = TextEditingController(text: draft.row?.toString() ?? '');
    final slot = TextEditingController(text: draft.slot?.toString() ?? '');
    final quantity = TextEditingController(
      text: draft.quantity?.toString() ?? '',
    );
    String? positive(String? value) =>
        (int.tryParse(value ?? '') ?? 0) < 1
            ? tr(context, 'rsPositiveNumber')
            : null;
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(tr(context, 'rsReviewProduct')),
            content: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: name,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsProductName'),
                      ),
                      validator:
                          (v) =>
                              v == null || v.trim().isEmpty
                                  ? tr(context, 'rsRequired')
                                  : null,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: row,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsRow'),
                      ),
                      validator: positive,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: slot,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsSlot'),
                      ),
                      validator: positive,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: quantity,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsQuantity'),
                        helperText: tr(context, 'rsEnterCountedQuantity'),
                      ),
                      validator:
                          (v) =>
                              int.tryParse(v ?? '') == null || int.parse(v!) < 0
                                  ? tr(context, 'rsNonnegativeNumber')
                                  : null,
                    ),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: Text(tr(context, 'rsCancel')),
              ),
              FilledButton(
                onPressed: () {
                  if (form.currentState?.validate() ?? false) {
                    Navigator.pop(dialogContext, true);
                  }
                },
                child: Text(tr(context, 'rsApply')),
              ),
            ],
          ),
    );
    if (accepted == true && mounted) {
      setState(() {
        final updatedName = name.text.trim();
        if (updatedName != draft.name) {
          draft.product['name'] = updatedName;
          draft.productDirty = true;
        }
        draft.row = int.parse(row.text);
        draft.slot = int.parse(slot.text);
        draft.quantity = int.parse(quantity.text);
        draft.dirty = true;
      });
    }
    for (final controller in [name, row, slot, quantity]) {
      controller.dispose();
    }
  }

  void _select(int index) {
    setState(() => _selected = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || index >= _drafts.length) return;
      final cardContext = _drafts[index].key.currentContext;
      if (cardContext != null) {
        Scrollable.ensureVisible(
          cardContext,
          duration: const Duration(milliseconds: 250),
          alignment: 0.4,
        );
      }
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    final app = ref.read(appControllerProvider);
    final identity = app.identityGeneration;
    final storeId = app.store?['id']?.toString();
    if (storeId == null) return;
    final occupied = <String>{};
    for (final draft in _drafts) {
      if (draft.name.trim().isEmpty ||
          draft.quantity == null ||
          draft.quantity! < 0 ||
          (draft.row ?? 0) < 1 ||
          (draft.slot ?? 0) < 1) {
        setState(() => _error = tr(context, 'rsReviewAllProducts'));
        return;
      }
      if (!occupied.add('${draft.row}:${draft.slot}')) {
        setState(() => _error = tr(context, 'rsSlotCollision'));
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      for (final draft in _drafts) {
        if (!mounted || identity != app.identityGeneration) return;
        final productPayload = <String, dynamic>{
          for (final key in [
            'name',
            'brand',
            'category',
            'barcode',
            'net_weight',
            'image_base64',
          ])
            if (draft.product[key] != null) key: draft.product[key],
          'source':
              draft.product['source'] ??
              (widget.candidates == null ? 'manual' : 'ai_reviewed'),
        };
        if (draft.productId == null) {
          final saved = await app.repository.post(
            '/stores/${Uri.encodeComponent(storeId)}/products',
            productPayload,
          );
          if (!mounted || identity != app.identityGeneration) return;
          final id = saved is Map ? saved['id']?.toString() : null;
          if (id == null) throw StateError('missing_product_id');
          draft.productId = id;
          draft.productDirty = false;
        } else if (draft.productDirty) {
          await app.repository.patch(
            '/products/${Uri.encodeComponent(draft.productId!)}',
            productPayload,
          );
          draft.productDirty = false;
        }
        if (!mounted || identity != app.identityGeneration) return;
      }
      final updates = [
        for (final draft in _drafts)
          if (draft.itemId != null && draft.dirty)
            {
              'id': draft.itemId,
              'row': draft.row,
              'slot': draft.slot,
              'quantity': draft.quantity,
            },
      ];
      final desiredRows =
          _drafts.isEmpty
              ? null
              : _drafts.map((d) => d.row!).reduce((a, b) => a > b ? a : b);
      final currentRows =
          app.shelves.where((s) => s['id'] == _shelfId).firstOrNull?['rows']
              as num?;
      final expand =
          desiredRows != null &&
          currentRows != null &&
          desiredRows > currentRows;
      if (updates.isNotEmpty || expand) {
        await app.repository.post(
          '/shelves/${Uri.encodeComponent(_shelfId)}/planogram',
          {'items': updates, if (expand) 'rows': desiredRows},
        );
        if (!mounted || identity != app.identityGeneration) return;
      }
      for (final draft in _drafts) {
        if (!mounted || identity != app.identityGeneration) return;
        final itemPayload = {
          'product_id': draft.productId,
          'row': draft.row,
          'slot': draft.slot,
          'quantity': draft.quantity,
        };
        if (draft.itemId == null) {
          final saved = await app.repository.post(
            '/shelves/${Uri.encodeComponent(_shelfId)}/items',
            itemPayload,
          );
          final id = saved is Map ? saved['id']?.toString() : null;
          if (id == null) throw StateError('missing_item_id');
          draft.itemId = id;
        }
        draft.dirty = false;
      }
      if (!mounted || identity != app.identityGeneration) return;
      if (_drafts.isNotEmpty) {
        final rows = _drafts
            .map((draft) => draft.row ?? 1)
            .reduce((a, b) => a > b ? a : b);
        await app.repository.patch(
          '/shelves/${Uri.encodeComponent(_shelfId)}',
          {'rows': rows},
        );
      }
      if (!mounted || identity != app.identityGeneration) return;
      await app.refresh();
      if (mounted && identity == app.identityGeneration) {
        context.go('/map?shelf=${Uri.encodeComponent(_shelfId)}');
      }
    } catch (_) {
      if (mounted) setState(() => _error = tr(context, 'rsSaveShelfFailed'));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _thumbnail(_ShelfDraft draft) {
    final encoded = draft.product['image_base64'];
    if (encoded is String && encoded.isNotEmpty) {
      try {
        return Image.memory(
          base64Decode(encoded),
          width: Tokens.xl * 2,
          height: Tokens.xl * 2,
          fit: BoxFit.contain,
          errorBuilder:
              (_, _, _) =>
                  const Icon(Icons.inventory_2_outlined, size: Tokens.xl),
        );
      } catch (_) {
        /* Malformed optional image falls back to a neutral product tile. */
      }
    }
    return const SizedBox(
      width: Tokens.xl * 2,
      height: Tokens.xl * 2,
      child: Icon(Icons.inventory_2_outlined, size: Tokens.xl),
    );
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final matches = app.shelves.where((e) => e['id']?.toString() == _shelfId);
    final name =
        matches.isEmpty
            ? tr(context, 'rsShelf')
            : matches.first['name']?.toString() ?? tr(context, 'rsShelf');
    final theme = Theme.of(context);
    final locale = Localizations.localeOf(context).toString();
    final rows = _drafts.map((e) => e.row ?? 1).toSet().toList()..sort();
    final currentIndex = app.shelves.indexWhere(
      (e) => e['id']?.toString() == _shelfId,
    );
    final hasNext = currentIndex >= 0 && currentIndex + 1 < app.shelves.length;
    final canPopNavigator = Navigator.of(context).canPop();
    final router = GoRouter.maybeOf(context);
    final currentPath = router?.routeInformationProvider.value.uri.path;
    return PopScope(
      canPop: canPopNavigator && (!_hasChanges || _saving || _allowPop),
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || _saving) return;
        if (!_hasChanges) {
          if (!Navigator.of(context).canPop() &&
              router != null &&
              currentPath != '/home') {
            router.go('/home');
          }
          return;
        }
        if (await _discardChanges() && context.mounted) {
          if (Navigator.of(context).canPop()) {
            setState(() => _allowPop = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) Navigator.of(context).pop();
            });
          } else {
            router?.go('/home');
          }
        }
      },
      child: PageScaffold(
        title: name,
        actions: [
          TextButton.icon(
            onPressed: _saving ? null : _scan,
            icon: const Icon(Icons.refresh),
            label: Text(tr(context, 'rsRescan')),
          ),
        ],
        bottom: Row(
          children: [
            if (hasNext) ...[
              Expanded(
                child: BrandButton(
                  label: tr(context, 'rsScanNextShelf'),
                  icon: Icons.camera_alt_outlined,
                  outlined: true,
                  onPressed: _saving ? null : () => _scan(next: true),
                ),
              ),
              const SizedBox(width: Tokens.sm),
            ],
            Expanded(
              child: BrandButton(
                label: tr(context, _saving ? 'rsSaving' : 'rsSaveShelf'),
                icon: Icons.check,
                onPressed: _saving ? null : _save,
              ),
            ),
          ],
        ),
        child: ListView(
          padding: const EdgeInsets.all(Tokens.md),
          children: [
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final shelf in app.shelves)
                    if (shelf['id'] != null) ...[
                      ChoiceChip(
                        label: Text(
                          shelf['name']?.toString() ?? tr(context, 'rsShelf'),
                        ),
                        selected: shelf['id'].toString() == _shelfId,
                        onSelected:
                            _saving
                                ? null
                                : (_) => _switchShelf(shelf['id'].toString()),
                      ),
                      const SizedBox(width: Tokens.sm),
                    ],
                  ActionChip(
                    avatar: const Icon(Icons.add),
                    label: Text(tr(context, 'rsAddShelf')),
                    onPressed: _saving ? null : _addShelf,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Tokens.md),
            if (_error != null) ErrorNotice(message: _error!),
            InfoCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr(context, 'rsShelfLayout'),
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      Chip(
                        label: Text(
                          tr(
                            context,
                            _drafts.length == 1
                                ? 'rsProductCountOne'
                                : 'rsProductCount',
                            {
                              'count': NumberFormat.decimalPattern(
                                locale,
                              ).format(_drafts.length),
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Tokens.md),
                  if (_drafts.isEmpty)
                    EmptyState(
                      message: tr(context, 'rsNoShelfProducts'),
                      icon: Icons.shelves,
                    ),
                  for (final row in rows)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.md),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tr(context, 'rsRowNumber', {
                              'row': NumberFormat.decimalPattern(
                                locale,
                              ).format(row),
                            }),
                            style: theme.textTheme.labelLarge,
                          ),
                          const SizedBox(height: Tokens.sm),
                          SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                for (
                                  var index = 0;
                                  index < _drafts.length;
                                  index++
                                )
                                  if ((_drafts[index].row ?? 1) == row)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        right: Tokens.sm,
                                      ),
                                      child: InkWell(
                                        onTap: () => _select(index),
                                        borderRadius: BorderRadius.circular(
                                          Tokens.md,
                                        ),
                                        child: Container(
                                          width: Tokens.xl * 3,
                                          padding: const EdgeInsets.all(
                                            Tokens.sm,
                                          ),
                                          decoration: BoxDecoration(
                                            color:
                                                _selected == index
                                                    ? theme
                                                        .colorScheme
                                                        .primaryContainer
                                                    : theme
                                                        .colorScheme
                                                        .surfaceContainerLow,
                                            borderRadius: BorderRadius.circular(
                                              Tokens.md,
                                            ),
                                            border: Border.all(
                                              color:
                                                  _selected == index
                                                      ? theme
                                                          .colorScheme
                                                          .primary
                                                      : theme
                                                          .colorScheme
                                                          .outlineVariant,
                                              width: _selected == index ? 2 : 1,
                                            ),
                                          ),
                                          child: Column(
                                            children: [
                                              Align(
                                                alignment: Alignment.topLeft,
                                                child: CircleAvatar(
                                                  radius: Tokens.md,
                                                  child: Text(
                                                    NumberFormat.decimalPattern(
                                                      locale,
                                                    ).format(index + 1),
                                                    style:
                                                        theme
                                                            .textTheme
                                                            .labelMedium,
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(height: Tokens.sm),
                                              Icon(
                                                Icons.inventory_2_outlined,
                                                color:
                                                    theme.colorScheme.primary,
                                                size: Tokens.xl,
                                              ),
                                              const SizedBox(height: Tokens.sm),
                                              Text(
                                                _drafts[index].name.isEmpty
                                                    ? tr(
                                                      context,
                                                      'rsUnknownProduct',
                                                    )
                                                    : _drafts[index].name,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                textAlign: TextAlign.center,
                                                style:
                                                    theme.textTheme.labelMedium,
                                              ),
                                              Text(
                                                tr(context, 'rsSlotNumber', {
                                                  'slot':
                                                      NumberFormat.decimalPattern(
                                                        locale,
                                                      ).format(
                                                        _drafts[index].slot ??
                                                            0,
                                                      ),
                                                }),
                                                style:
                                                    theme.textTheme.bodySmall,
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                IconButton(
                                  onPressed: _saving ? null : _addProduct,
                                  tooltip: tr(context, 'rsAddMissingProduct'),
                                  icon: const Icon(Icons.add_box_outlined),
                                ),
                              ],
                            ),
                          ),
                          Container(
                            height: Tokens.sm,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.outlineVariant,
                              borderRadius: BorderRadius.circular(Tokens.xs),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: Tokens.lg),
            Text(
              tr(context, 'rsReviewHeading'),
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: Tokens.sm),
            Text(
              tr(context, 'rsReviewExplanation'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: Tokens.md),
            for (var index = 0; index < _drafts.length; index++) ...[
              Builder(
                builder: (context) {
                  final draft = _drafts[index];
                  final confidence = draft.confidence;
                  return AnimatedContainer(
                    key: draft.key,
                    duration: const Duration(milliseconds: 180),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(Tokens.radius),
                      border: Border.all(
                        color:
                            _selected == index
                                ? theme.colorScheme.primary
                                : theme.colorScheme.outlineVariant,
                        width: _selected == index ? 2 : 1,
                      ),
                      color: theme.colorScheme.surface,
                    ),
                    child: InkWell(
                      onTap: () => _select(index),
                      borderRadius: BorderRadius.circular(Tokens.radius),
                      child: Padding(
                        padding: const EdgeInsets.all(Tokens.md),
                        child: Column(
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _thumbnail(draft),
                                const SizedBox(width: Tokens.sm),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        draft.name.isEmpty
                                            ? tr(context, 'rsUnknownProduct')
                                            : draft.name,
                                        style: theme.textTheme.titleSmall,
                                      ),
                                      const SizedBox(height: Tokens.xs),
                                      Text(
                                        tr(context, 'rsPosition', {
                                          'row': NumberFormat.decimalPattern(
                                            locale,
                                          ).format(draft.row ?? 0),
                                          'slot': NumberFormat.decimalPattern(
                                            locale,
                                          ).format(draft.slot ?? 0),
                                        }),
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      if (confidence != null &&
                                          confidence >= 0 &&
                                          confidence <= 1)
                                        Text(
                                          tr(context, 'rsConfidence', {
                                            'confidence':
                                                NumberFormat.percentPattern(
                                                  locale,
                                                ).format(confidence),
                                          }),
                                          style: theme.textTheme.bodySmall,
                                        )
                                      else
                                        Text(
                                          tr(context, 'rsNeedsReview'),
                                          style: theme.textTheme.bodySmall,
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed:
                                      _saving ? null : () => _edit(draft),
                                  tooltip: tr(context, 'rsEditProduct'),
                                  icon: const Icon(Icons.edit_outlined),
                                ),
                              ],
                            ),
                            const SizedBox(height: Tokens.sm),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    tr(context, 'rsRecordedQuantity'),
                                    style: theme.textTheme.labelMedium,
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed:
                                      _saving ||
                                              draft.quantity == null ||
                                              draft.quantity! <= 0
                                          ? null
                                          : () => setState(() {
                                            draft.quantity =
                                                draft.quantity! - 1;
                                            draft.dirty = true;
                                          }),
                                  tooltip: tr(context, 'rsDecreaseQuantity'),
                                  icon: const Icon(Icons.remove),
                                ),
                                TextButton(
                                  onPressed:
                                      _saving ? null : () => _edit(draft),
                                  child: Text(
                                    draft.quantity == null
                                        ? tr(context, 'rsSetQuantity')
                                        : NumberFormat.decimalPattern(
                                          locale,
                                        ).format(draft.quantity),
                                  ),
                                ),
                                IconButton.filledTonal(
                                  onPressed:
                                      _saving || draft.quantity == null
                                          ? null
                                          : () => setState(() {
                                            draft.quantity =
                                                draft.quantity! + 1;
                                            draft.dirty = true;
                                          }),
                                  tooltip: tr(context, 'rsIncreaseQuantity'),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            ),
                            if (draft.itemId != null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed:
                                      _saving
                                          ? null
                                          : () => _editDetails(draft),
                                  icon: const Icon(Icons.info_outline),
                                  label: Text(tr(context, 'rsProductDetails')),
                                ),
                              ),
                            if (draft.itemId == null)
                              Align(
                                alignment: Alignment.centerRight,
                                child: TextButton.icon(
                                  onPressed:
                                      _saving
                                          ? null
                                          : () => setState(() {
                                            _drafts.remove(draft);
                                            _selected = null;
                                          }),
                                  icon: const Icon(Icons.delete_outline),
                                  label: Text(
                                    tr(context, 'rsRemoveSuggestion'),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(height: Tokens.md),
            ],
            OutlinedButton.icon(
              onPressed: _saving ? null : _addProduct,
              icon: const Icon(Icons.add),
              label: Text(tr(context, 'rsAddMissingProduct')),
            ),
            const SizedBox(height: Tokens.lg),
          ],
        ),
      ),
    );
  }
}
