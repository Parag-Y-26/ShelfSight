import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart' show NumberFormat;

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../vision/geometry.dart';
import '../widgets/shared.dart';

class StoreMapScreen extends ConsumerStatefulWidget {
  const StoreMapScreen({super.key});
  @override
  ConsumerState<StoreMapScreen> createState() => _StoreMapScreenState();
}

class _StoreMapScreenState extends ConsumerState<StoreMapScreen> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _x = TextEditingController(), _y = TextEditingController();
  final _width = TextEditingController(), _length = TextEditingController();
  final _transform = TransformationController();
  String? _floorId, _shelfId, _shape, _errorKey;
  ShelfGeometry? _draft;
  bool _initialized = false, _saving = false;
  int _rotation = 0;
  int? _dragCorner;
  Offset? _lastDrag;
  bool _dragging = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    final app = ref.read(appControllerProvider);
    String? desired;
    try {
      desired = GoRouterState.of(context).uri.queryParameters['shelf'];
    } catch (_) {
      /* can also be opened with Navigator in widget tests */
    }
    final intended = app.shelves.where((s) => s['id'] == desired).firstOrNull;
    _floorId =
        intended?['floor_id']?.toString() ??
        app.floors.firstOrNull?['id']?.toString();
    if (intended != null) _selectShelf(desired, app, rebuild: false);
    _initialized = true;
  }

  @override
  void dispose() {
    for (final controller in [_name, _x, _y, _width, _length]) {
      controller.dispose();
    }
    _transform.dispose();
    super.dispose();
  }

  NumberFormat get _numbers => NumberFormat.decimalPattern(
    Localizations.localeOf(context).toLanguageTag(),
  )..maximumFractionDigits = 6;
  String _format(num value) => _numbers.format(value);
  double? _parse(String text) {
    if (text.trim().isEmpty) return null;
    try {
      final value = _numbers.parse(text.trim()).toDouble();
      return value.isFinite ? value : null;
    } on FormatException {
      return null;
    }
  }

  Map<String, dynamic>? _floor(AppController app) =>
      app.floors.where((f) => f['id'] == _floorId).firstOrNull;

  void _selectShelf(String? id, AppController app, {bool rebuild = true}) {
    _shelfId = id;
    final shelf = app.shelves.where((s) => s['id'] == id).firstOrNull;
    _name.text = shelf?['name']?.toString() ?? '';
    _draft = shelf != null && shelf['floor_id'] == _floorId
        ? ShelfGeometry.fromJson(shelf)
        : null;
    _shape = shelf?['shape']?.toString();
    _rotation = (finiteNumber(shelf?['rotation']) ?? 0).toInt();
    _setFields(_draft);
    _errorKey = null;
    if (rebuild) setState(() {});
  }

  void _setFields(ShelfGeometry? geometry) {
    _x.text = geometry == null ? '' : _format(geometry.x);
    _y.text = geometry == null ? '' : _format(geometry.y);
    _width.text = geometry == null ? '' : _format(geometry.width);
    _length.text = geometry == null ? '' : _format(geometry.length);
  }

  ShelfGeometry? _fromFields() {
    final x = _parse(_x.text), y = _parse(_y.text);
    final width = _parse(_width.text), length = _parse(_length.text);
    if (x == null ||
        y == null ||
        width == null ||
        length == null ||
        _shape == null) {
      return null;
    }
    return ShelfGeometry(
      x: x,
      y: y,
      width: width,
      length: length,
      rotation: _rotation,
      shape: _shape!,
    );
  }

  void _updatePreview({bool widthChanged = false}) {
    if (_shape == 'square' && widthChanged) _length.text = _width.text;
    setState(() {
      _draft = _fromFields();
      _errorKey = null;
    });
  }

  Future<void> _save(AppController app) async {
    final floor = _floor(app);
    final fw = finiteNumber(floor?['width']),
        fl = finiteNumber(floor?['length']);
    if (_saving ||
        !_form.currentState!.validate() ||
        _shelfId == null ||
        floor == null) {
      return;
    }
    final geometry = _fromFields();
    if (geometry == null ||
        fw == null ||
        fl == null ||
        !geometry.fits(fw, fl)) {
      setState(() {
        _errorKey = 'mapOutsideFloor';
      });
      return;
    }
    setState(() {
      _saving = true;
      _errorKey = null;
    });
    try {
      await app.api.patch('/shelves/$_shelfId', {
        ...geometry.toJson(),
        'floor_id': _floorId,
        'name': _name.text.trim(),
      });
      await app.refresh();
      if (!mounted) return;
      _selectShelf(_shelfId, app);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(tr(context, 'mapSaved'))));
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorKey = 'mapSaveFailed';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  Future<void> _editFloor(AppController app, {required bool creating}) async {
    final floor = creating ? null : _floor(app);
    final storeId = app.store?['id'];
    if (storeId == null || (!creating && floor == null)) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _FloorDialog(
        floor: floor,
        unit: app.store?['unit']?.toString() ?? '',
        shelves: app.shelves
            .where((s) => s['floor_id'] == floor?['id'])
            .toList(),
      ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _saving = true;
      _errorKey = null;
    });
    try {
      final data = creating
          ? await app.api.post('/stores/$storeId/floors', result)
          : await app.api.patch('/floors/${floor!['id']}', result);
      await app.refresh();
      if (!mounted) return;
      if (data is Map && data['id'] is String) _floorId = data['id'] as String;
      _transform.value = Matrix4.identity();
      _selectShelf(_shelfId, app);
    } catch (_) {
      if (mounted) {
        setState(() {
          _errorKey = 'mapFloorSaveFailed';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  void _changeFloor(String? id, AppController app) {
    _floorId = id;
    _transform.value = Matrix4.identity();
    _selectShelf(_shelfId, app);
  }

  void _zoom(double factor) {
    final scale = _transform.value.getMaxScaleOnAxis();
    final next = (scale * factor).clamp(1.0, 6.0);
    final applied = next / scale;
    _transform.value = _transform.value.clone()
      ..scaleByDouble(applied, applied, 1, 1);
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final floor = _floor(app);
    final fw = finiteNumber(floor?['width']),
        fl = finiteNumber(floor?['length']);
    final unit = app.store?['unit']?.toString() ?? '';
    final shapeOptions = app.config['shapes'];
    final shapes = shapeOptions is List
        ? shapeOptions.whereType<Map>().toList()
        : <Map>[];
    return PageScaffold(
      title: tr(context, 'mapTitle'),
      bottom: BrandButton(
        label: tr(context, 'mapConfirmLocation'),
        icon: Icons.check,
        onPressed: !_saving && _shelfId != null && floor != null
            ? () => unawaited(_save(app))
            : null,
      ),
      child: app.store == null
          ? EmptyState(
              message: tr(context, 'mapNeedsStore'),
              icon: Icons.store_outlined,
            )
          : ListView(
              padding: const EdgeInsets.all(Tokens.md),
              children: [
                if (_errorKey != null)
                  ErrorNotice(message: tr(context, _errorKey!)),
                InfoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              initialValue: floor?['id']?.toString(),
                              isExpanded: true,
                              decoration: InputDecoration(
                                labelText: tr(context, 'mapFloor'),
                              ),
                              items: app.floors
                                  .map(
                                    (f) => DropdownMenuItem(
                                      value: f['id'].toString(),
                                      child: Text(
                                        f['name']?.toString() ?? '',
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  )
                                  .toList(),
                              onChanged: _saving
                                  ? null
                                  : (id) => _changeFloor(id, app),
                            ),
                          ),
                          const SizedBox(width: Tokens.sm),
                          IconButton(
                            onPressed: !_saving && floor != null
                                ? () => unawaited(
                                    _editFloor(app, creating: false),
                                  )
                                : null,
                            tooltip: tr(context, 'mapEditFloor'),
                            icon: const Icon(Icons.edit_outlined),
                          ),
                          IconButton(
                            onPressed: _saving
                                ? null
                                : () => unawaited(
                                    _editFloor(app, creating: true),
                                  ),
                            tooltip: tr(context, 'mapAddFloor'),
                            icon: const Icon(Icons.add),
                          ),
                        ],
                      ),
                      if (fw != null && fl != null)
                        Padding(
                          padding: const EdgeInsets.only(top: Tokens.sm),
                          child: Text(
                            tr(context, 'mapFloorDimensions', {
                              'width': _format(fw),
                              'length': _format(fl),
                              'unit': unit,
                            }),
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                    ],
                  ),
                ),
                if (fw != null && fl != null && fw > 0 && fl > 0)
                  InfoCard(
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            IconButton(
                              onPressed: () => _zoom(1.25),
                              tooltip: tr(context, 'mapZoomIn'),
                              icon: const Icon(Icons.zoom_in),
                            ),
                            IconButton(
                              onPressed: () => _zoom(1 / 1.25),
                              tooltip: tr(context, 'mapZoomOut'),
                              icon: const Icon(Icons.zoom_out),
                            ),
                            IconButton(
                              onPressed: () =>
                                  _transform.value = Matrix4.identity(),
                              tooltip: tr(context, 'mapRecenter'),
                              icon: const Icon(Icons.center_focus_strong),
                            ),
                          ],
                        ),
                        SizedBox(
                          height: MediaQuery.sizeOf(context).height * 0.42,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Tokens.md),
                            child: InteractiveViewer(
                              transformationController: _transform,
                              minScale: 1,
                              maxScale: 6,
                              panEnabled: _shelfId == null,
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final size = Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  );
                                  final boundary = containedRect(
                                    size,
                                    fw,
                                    fl,
                                    Tokens.md,
                                  );
                                  Offset physical(Offset point) => Offset(
                                    (point.dx - boundary.left) *
                                        fw /
                                        boundary.width,
                                    (point.dy - boundary.top) *
                                        fl /
                                        boundary.height,
                                  );
                                  final visible = <String, ShelfGeometry>{};
                                  final names = <String, String>{};
                                  for (final shelf in app.shelves.where(
                                    (s) => s['floor_id'] == _floorId,
                                  )) {
                                    final geometry = ShelfGeometry.fromJson(
                                      shelf,
                                    );
                                    if (geometry != null &&
                                        geometry.fits(fw, fl)) {
                                      visible[shelf['id'].toString()] =
                                          geometry;
                                      names[shelf['id'].toString()] =
                                          shelf['name']?.toString() ?? '';
                                    }
                                  }
                                  if (_shelfId != null) {
                                    visible.remove(_shelfId);
                                    if (_draft?.fits(fw, fl) == true) {
                                      visible[_shelfId!] = _draft!;
                                    }
                                    names[_shelfId!] = _name.text;
                                  }
                                  final geometry = _draft;
                                  return Semantics(
                                    label: tr(context, 'mapCanvasSemantics'),
                                    child: GestureDetector(
                                      behavior: HitTestBehavior.opaque,
                                      onTapUp: _saving
                                          ? null
                                          : (details) {
                                              final point = physical(
                                                details.localPosition,
                                              );
                                              final hit = visible.entries
                                                  .where(
                                                    (e) => e.value.footprint
                                                        .contains(point),
                                                  )
                                                  .lastOrNull;
                                              if (hit != null &&
                                                  hit.key != _shelfId) {
                                                _selectShelf(hit.key, app);
                                              } else if (hit != null) {
                                                return;
                                              } else if (_shelfId != null && _draft == null) {
                                                return;
                                              } else {
                                                _selectShelf(null, app);
                                              }
                                            },
                                      onPanStart:
                                          _saving ||
                                              _shelfId == null ||
                                              geometry == null ||
                                              !geometry.fits(fw, fl)
                                          ? null
                                          : (details) {
                                              final point = physical(
                                                details.localPosition,
                                              );
                                              final rect = geometry.footprint;
                                              final corners = [
                                                rect.topLeft,
                                                rect.topRight,
                                                rect.bottomRight,
                                                rect.bottomLeft,
                                              ];
                                              _dragCorner = null;
                                              for (
                                                var i = 0;
                                                i < corners.length;
                                                i++
                                              ) {
                                                final px = Offset(
                                                  boundary.left +
                                                      corners[i].dx /
                                                          fw *
                                                          boundary.width,
                                                  boundary.top +
                                                      corners[i].dy /
                                                          fl *
                                                          boundary.height,
                                                );
                                                if ((px - details.localPosition)
                                                        .distance <=
                                                    Tokens.md) {
                                                  _dragCorner = i;
                                                }
                                              }
                                              _dragging =
                                                  _dragCorner != null ||
                                                  rect.contains(point);
                                              _lastDrag = point;
                                            },
                                      onPanUpdate:
                                          _saving ||
                                              _shelfId == null ||
                                              geometry == null
                                          ? null
                                          : (details) {
                                              final current = _draft,
                                                  previous = _lastDrag;
                                              if (!_dragging ||
                                                  current == null ||
                                                  previous == null) {
                                                return;
                                              }
                                              final point = physical(
                                                details.localPosition,
                                              );
                                              final changed =
                                                  _dragCorner == null
                                                  ? current.moved(
                                                      point - previous,
                                                      fw,
                                                      fl,
                                                    )
                                                  : current.resized(
                                                      _dragCorner!,
                                                      point,
                                                      fw,
                                                      fl,
                                                    );
                                              _lastDrag = point;
                                              setState(() {
                                                _draft = changed;
                                                _setFields(changed);
                                              });
                                            },
                                      onPanEnd: (_) {
                                        _dragging = false;
                                        _lastDrag = null;
                                        _dragCorner = null;
                                      },
                                      onPanCancel: () {
                                        _dragging = false;
                                        _lastDrag = null;
                                        _dragCorner = null;
                                      },
                                      child: CustomPaint(
                                        size: size,
                                        painter: _FloorPainter(
                                          floorWidth: fw,
                                          floorLength: fl,
                                          shelves: visible,
                                          names: names,
                                          selectedId: _shelfId,
                                          textStyle:
                                              Theme.of(context)
                                                  .textTheme
                                                  .labelMedium ??
                                              const TextStyle(),
                                          textDirection: Directionality.of(
                                            context,
                                          ),
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: Tokens.sm),
                        Text(
                          tr(context, 'mapGestureHelp'),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  )
                else
                  InfoCard(
                    child: EmptyState(
                      message: tr(context, 'mapNoFloor'),
                      icon: Icons.grid_on,
                    ),
                  ),
                InfoCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        tr(context, 'mapShelfGeometry'),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: Tokens.md),
                      DropdownButtonFormField<String>(
                        initialValue: app.shelves.any((s) => s['id'] == _shelfId)
                            ? _shelfId
                            : null,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: tr(context, 'mapSelectShelf'),
                        ),
                        items: app.shelves
                            .map(
                              (s) => DropdownMenuItem(
                                value: s['id'].toString(),
                                child: Text(
                                  s['name']?.toString() ?? '',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(),
                        onChanged: _saving
                            ? null
                            : (value) => _selectShelf(value, app),
                      ),
                      if (_shelfId == null)
                        EmptyState(message: tr(context, 'mapChooseShelf'))
                      else
                        Form(
                          key: _form,
                          child: Column(
                            children: [
                              const SizedBox(height: Tokens.md),
                              TextFormField(
                                controller: _name,
                                enabled: !_saving,
                                decoration: InputDecoration(
                                  labelText: tr(context, 'mapShelfName'),
                                ),
                                validator: (v) => v?.trim().isNotEmpty == true
                                    ? null
                                    : tr(context, 'mapRequired'),
                              ),
                              const SizedBox(height: Tokens.md),
                              DropdownButtonFormField<String>(
                                initialValue: shapes.any((s) => s['id'] == _shape)
                                    ? _shape
                                    : null,
                                decoration: InputDecoration(
                                  labelText: tr(context, 'mapShape'),
                                ),
                                items: shapes
                                    .map(
                                      (s) => DropdownMenuItem(
                                        value: s['id'].toString(),
                                        child: Text(
                                          tr(
                                            context,
                                            s['label_key']?.toString() ?? '',
                                          ),
                                        ),
                                      ),
                                    )
                                    .toList(),
                                onChanged: _saving
                                    ? null
                                    : (shape) {
                                        _shape = shape;
                                        if (shape == 'square') {
                                          _length.text = _width.text;
                                        }
                                        _updatePreview();
                                      },
                                validator: (v) => v == null
                                    ? tr(context, 'mapRequired')
                                    : null,
                              ),
                              const SizedBox(height: Tokens.md),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _dimensionField(
                                      _width,
                                      'mapWidth',
                                      unit,
                                      positive: true,
                                      onChange: () =>
                                          _updatePreview(widthChanged: true),
                                    ),
                                  ),
                                  const SizedBox(width: Tokens.md),
                                  Expanded(
                                    child: _dimensionField(
                                      _length,
                                      'mapLength',
                                      unit,
                                      positive: true,
                                      enabled: _shape != 'square',
                                      onChange: _updatePreview,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Tokens.md),
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: _dimensionField(
                                      _x,
                                      'mapPositionX',
                                      unit,
                                      onChange: _updatePreview,
                                    ),
                                  ),
                                  const SizedBox(width: Tokens.md),
                                  Expanded(
                                    child: _dimensionField(
                                      _y,
                                      'mapPositionY',
                                      unit,
                                      onChange: _updatePreview,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Tokens.md),
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      tr(context, 'mapRotation', {
                                        'value': _format(_rotation),
                                      }),
                                    ),
                                  ),
                                  OutlinedButton.icon(
                                    onPressed: _saving
                                        ? null
                                        : () {
                                            _rotation = (_rotation + 90) % 360;
                                            _updatePreview();
                                          },
                                    icon: const Icon(Icons.rotate_right),
                                    label: Text(tr(context, 'mapRotate')),
                                  ),
                                ],
                              ),
                              const SizedBox(height: Tokens.sm),
                              Text(
                                tr(context, 'mapGeometryHelp'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                if (_saving) const LinearProgressIndicator(),
              ],
            ),
    );
  }

  Widget _dimensionField(
    TextEditingController controller,
    String key,
    String unit, {
    bool positive = false,
    bool enabled = true,
    required VoidCallback onChange,
  }) => TextFormField(
    controller: controller,
    enabled: enabled && !_saving,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    decoration: InputDecoration(labelText: tr(context, key), suffixText: unit),
    onChanged: (_) => onChange(),
    validator: (text) {
      final n = _parse(text ?? '');
      if (n == null || (positive ? n <= 0 : n < 0)) {
        return tr(
          context,
          positive ? 'mapPositiveNumber' : 'mapNonnegativeNumber',
        );
      }
      return null;
    },
  );
}

class _FloorDialog extends StatefulWidget {
  const _FloorDialog({
    required this.floor,
    required this.unit,
    required this.shelves,
  });
  final Map<String, dynamic>? floor;
  final String unit;
  final List<Map<String, dynamic>> shelves;
  @override
  State<_FloorDialog> createState() => _FloorDialogState();
}

class _FloorDialogState extends State<_FloorDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController(),
      _width = TextEditingController(),
      _length = TextEditingController();
  String? _error;
  bool _loaded = false;
  NumberFormat get _numbers => NumberFormat.decimalPattern(
    Localizations.localeOf(context).toLanguageTag(),
  );
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _name.text = widget.floor?['name']?.toString() ?? '';
    final width = finiteNumber(widget.floor?['width']),
        length = finiteNumber(widget.floor?['length']);
    _width.text = width == null ? '' : _numbers.format(width);
    _length.text = length == null ? '' : _numbers.format(length);
  }

  @override
  void dispose() {
    _name.dispose();
    _width.dispose();
    _length.dispose();
    super.dispose();
  }

  double? _parse(String value) {
    try {
      final v = _numbers.parse(value.trim()).toDouble();
      return v.isFinite ? v : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      tr(context, widget.floor == null ? 'mapAddFloor' : 'mapEditFloor'),
    ),
    content: SingleChildScrollView(
      child: Form(
        key: _form,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _name,
              decoration: InputDecoration(
                labelText: tr(context, 'mapFloorName'),
              ),
              validator: (v) => v?.trim().isNotEmpty == true
                  ? null
                  : tr(context, 'mapRequired'),
            ),
            const SizedBox(height: Tokens.md),
            for (final entry in [
              (_width, 'mapWidth'),
              (_length, 'mapLength'),
            ]) ...[
              TextFormField(
                controller: entry.$1,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: tr(context, entry.$2),
                  suffixText: widget.unit,
                ),
                validator: (v) {
                  final n = _parse(v ?? '');
                  return n != null && n > 0
                      ? null
                      : tr(context, 'mapPositiveNumber');
                },
              ),
              const SizedBox(height: Tokens.md),
            ],
            if (_error != null) ErrorNotice(message: tr(context, _error!)),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(tr(context, 'mapCancel')),
      ),
      FilledButton(
        onPressed: () {
          if (!_form.currentState!.validate()) return;
          final width = _parse(_width.text)!, length = _parse(_length.text)!;
          for (final shelf in widget.shelves) {
            final geometry = ShelfGeometry.fromJson(shelf);
            if (geometry != null && !geometry.fits(width, length)) {
              setState(() {
                _error = 'mapFloorContainsShelves';
              });
              return;
            }
          }
          Navigator.pop(context, {
            'name': _name.text.trim(),
            'width': width,
            'length': length,
          });
        },
        child: Text(tr(context, 'mapSaveFloor')),
      ),
    ],
  );
}

class _FloorPainter extends CustomPainter {
  const _FloorPainter({
    required this.floorWidth,
    required this.floorLength,
    required this.shelves,
    required this.names,
    required this.selectedId,
    required this.textStyle,
    required this.textDirection,
  });
  final double floorWidth, floorLength;
  final Map<String, ShelfGeometry> shelves;
  final Map<String, String> names;
  final String? selectedId;
  final TextStyle textStyle;
  final TextDirection textDirection;
  @override
  void paint(Canvas canvas, Size size) {
    final boundary = containedRect(size, floorWidth, floorLength, Tokens.md);
    canvas.drawRect(Offset.zero & size, Paint()..color = Tokens.pale);
    canvas.save();
    canvas.clipRect(boundary);
    // Grid density follows viewport size rather than a fixed store dimension.
    final columns = math.max(1, (boundary.width / Tokens.lg).floor());
    final rows = math.max(1, (boundary.height / Tokens.lg).floor());
    final dots = Paint()..color = Tokens.line;
    for (var x = 0; x <= columns; x++) {
      for (var y = 0; y <= rows; y++) {
        canvas.drawCircle(
          Offset(
            boundary.left + boundary.width * x / columns,
            boundary.top + boundary.height * y / rows,
          ),
          Tokens.xs / 4,
          dots,
        );
      }
    }
    Rect physical(Rect r) => Rect.fromLTWH(
      boundary.left + r.left / floorWidth * boundary.width,
      boundary.top + r.top / floorLength * boundary.height,
      r.width / floorWidth * boundary.width,
      r.height / floorLength * boundary.height,
    );
    for (final entry in shelves.entries) {
      final rect = physical(entry.value.footprint);
      final selected = entry.key == selectedId;
      canvas.drawRect(
        rect,
        Paint()..color = Tokens.teal.withValues(alpha: selected ? 0.75 : 0.15),
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = Tokens.teal
          ..style = PaintingStyle.stroke
          ..strokeWidth = Tokens.xs / 2,
      );
      final text = TextPainter(
        text: TextSpan(
          text: names[entry.key] ?? '',
          style: textStyle.copyWith(
            color: selected ? Tokens.surface : Tokens.navy,
          ),
        ),
        textDirection: textDirection,
        maxLines: 2,
        ellipsis: '\u2026',
      )..layout(maxWidth: math.max(0, rect.width - Tokens.sm));
      canvas.save();
      canvas.clipRect(rect);
      text.paint(canvas, rect.center - Offset(text.width / 2, text.height / 2));
      canvas.restore();
      if (selected) {
        for (final corner in [
          rect.topLeft,
          rect.topRight,
          rect.bottomRight,
          rect.bottomLeft,
        ]) {
          canvas.drawCircle(
            corner,
            Tokens.sm / 2,
            Paint()..color = Tokens.surface,
          );
          canvas.drawCircle(
            corner,
            Tokens.sm / 2,
            Paint()
              ..color = Tokens.teal
              ..style = PaintingStyle.stroke
              ..strokeWidth = Tokens.xs / 2,
          );
        }
      }
    }
    canvas.restore();
    canvas.drawRect(
      boundary,
      Paint()
        ..color = Tokens.navy.withValues(alpha: 0.65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = Tokens.xs / 2,
    );
  }

  @override
  bool shouldRepaint(covariant _FloorPainter oldDelegate) => true;
}
