import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';
import 'package:intl/intl.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../core/temp_photo.dart';
import '../widgets/shared.dart';

class ProductScreen extends ConsumerStatefulWidget {
  const ProductScreen({super.key, required this.shelfId, this.item});
  final String shelfId;
  final Map<String, dynamic>? item;

  @override
  ConsumerState<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends ConsumerState<ProductScreen>
    with WidgetsBindingObserver {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _barcode = TextEditingController();
  final _brand = TextEditingController();
  final _category = TextEditingController();
  final _netWeight = TextEditingController();
  final _price = TextEditingController();
  final _ingredients = TextEditingController();
  final _allergens = TextEditingController();
  final _manufacturer = TextEditingController();
  final _shelfLife = TextEditingController();
  final _row = TextEditingController();
  final _slot = TextEditingController();
  final _quantity = TextEditingController();
  final Map<String, TextEditingController> _nutrition = {};
  CameraController? _camera;
  Uint8List? _image;
  String? _photo;
  String? _productId;
  String? _itemId;
  String? _currency;
  String? _lookupSource;
  String? _errorKey;
  String? _statusKey;
  bool? _isVeg;
  bool _cameraLoading = false;
  bool _busy = false;
  bool _initialized = false;
  bool _showDetails = true;
  bool _resumeCamera = false;
  bool _applyingProduct = false;
  String? _boundBarcode;
  int? _priceWithUnknownCurrency;
  int _cameraGeneration = 0;
  int _lookupGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _row.addListener(_placementChanged);
    _slot.addListener(_placementChanged);
    _quantity.addListener(_placementChanged);
    _barcode.addListener(_barcodeChanged);
    if (widget.item == null) unawaited(_openCamera());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    final app = ref.read(appControllerProvider);
    _currency = app.store?['currency']?.toString();
    final item = widget.item;
    if (item == null) return;
    _itemId = item['id']?.toString();
    _productId = item['product_id']?.toString();
    _row.text = item['row']?.toString() ?? '';
    _slot.text = item['slot']?.toString() ?? '';
    _quantity.text = item['quantity']?.toString() ?? '';
    final products = app.products.where(
      (e) => e['id']?.toString() == _productId,
    );
    final nested = item['product'];
    if (nested is Map) {
      _applyProduct(Map<String, dynamic>.from(nested));
    } else if (products.isNotEmpty) {
      _applyProduct(products.first);
    }
  }

  void _placementChanged() {
    if (mounted) setState(() {});
  }

  void _clearLookupDetails() {
    for (final controller in [
      _name,
      _brand,
      _category,
      _netWeight,
      _price,
      _ingredients,
      _allergens,
      _manufacturer,
      _shelfLife,
    ]) {
      controller.clear();
    }
    for (final controller in _nutrition.values) {
      controller.dispose();
    }
    _nutrition.clear();
    _isVeg = null;
    _priceWithUnknownCurrency = null;
    _lookupSource = null;
    _statusKey = null;
    _boundBarcode = null;
    if (_photo == null) _image = null;
    if (widget.item == null) _quantity.clear();
  }

  void _barcodeChanged() {
    if (_applyingProduct) return;
    _lookupGeneration++;
    if (_barcode.text.trim() == _boundBarcode) return;
    if (widget.item == null) _productId = null;
    if (_boundBarcode != null) _clearLookupDetails();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _cameraGeneration++;
    unawaited(_camera?.dispose());
    for (final controller in [
      _name,
      _barcode,
      _brand,
      _category,
      _netWeight,
      _price,
      _ingredients,
      _allergens,
      _manufacturer,
      _shelfLife,
      _row,
      _slot,
      _quantity,
      ..._nutrition.values,
    ]) {
      controller.dispose();
    }
    final path = _photo;
    if (path != null) unawaited(_discard(path));
    super.dispose();
  }

  Future<void> _discard(String path) async {
    try {
      await deleteTempPhoto(path);
    } catch (_) {
      /* App temporary capture may already be deleted. */
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _resumeCamera = _resumeCamera || _camera != null || _cameraLoading;
      _cameraGeneration++;
      final camera = _camera;
      if (mounted) {
        setState(() {
          _camera = null;
          _cameraLoading = false;
        });
      }
      unawaited(camera?.dispose());
    } else if (state == AppLifecycleState.resumed && _resumeCamera && !_busy) {
      _resumeCamera = false;
      unawaited(_openCamera());
    }
  }

  Future<void> _openCamera() async {
    if (_busy || _cameraLoading) return;
    final generation = ++_cameraGeneration;
    setState(() {
      _cameraLoading = true;
      _errorKey = null;
    });
    CameraController? next;
    try {
      final cameras = await availableCameras();
      if (!mounted || generation != _cameraGeneration) return;
      if (cameras.isEmpty) throw StateError('no_camera');
      final back = cameras.where(
        (e) => e.lensDirection == CameraLensDirection.back,
      );
      next = CameraController(
        back.isEmpty ? cameras.first : back.first,
        ResolutionPreset.medium,
        enableAudio: false,
      );
      await next.initialize();
      if (!mounted || generation != _cameraGeneration) {
        await next.dispose();
        return;
      }
      final old = _camera;
      setState(() {
        _camera = next;
        _cameraLoading = false;
      });
      await old?.dispose();
    } catch (_) {
      await next?.dispose();
      if (mounted && generation == _cameraGeneration) {
        setState(() {
          _cameraLoading = false;
          _errorKey = 'rsCameraUnavailable';
        });
      }
    }
  }

  Future<void> _captureAndRead() async {
    final camera = _camera;
    if (_busy || camera == null || !camera.value.isInitialized) return;
    setState(() {
      _busy = true;
      _errorKey = null;
      _statusKey = null;
    });
    BarcodeScanner? scanner;
    String? capturedPath;
    try {
      final photo = await camera.takePicture();
      capturedPath = photo.path;
      if (!mounted) {
        await _discard(photo.path);
        return;
      }
      var results = <Barcode>[];
      if (!kIsWeb) {
        scanner = BarcodeScanner(
          formats: [
            BarcodeFormat.ean13,
            BarcodeFormat.ean8,
            BarcodeFormat.upca,
            BarcodeFormat.upce,
          ],
        );
        results = await scanner.processImage(
          InputImage.fromFilePath(photo.path),
        );
      }
      final bytes = await consumeTempPhoto(photo.path);
      if (!mounted) {
        await _discard(photo.path);
        return;
      }
      final limits = ref.read(appControllerProvider).config['limits'];
      final maxBytes =
          limits is Map && limits['max_image_bytes'] is num
              ? (limits['max_image_bytes'] as num).toInt()
              : null;
      if (maxBytes != null && bytes.length > maxBytes) {
        await _discard(photo.path);
        throw const FormatException('image_limit');
      }
      if (!mounted) {
        await _discard(photo.path);
        return;
      }
      final previous = _photo;
      setState(() {
        _photo = photo.path;
        _image = bytes;
        _camera = null;
        _resumeCamera = false;
      });
      _cameraGeneration++;
      await camera.dispose();
      if (previous != null) await _discard(previous);
      if (kIsWeb) {
        setState(() => _statusKey = 'rsNoBarcode');
        return;
      }
      final codes =
          results
              .map((e) => e.rawValue)
              .whereType<String>()
              .where((e) => e.trim().isNotEmpty)
              .toSet()
              .toList();
      if (!mounted) return;
      String? code = codes.length == 1 ? codes.first : null;
      if (codes.length > 1) {
        code = await showDialog<String>(
          context: context,
          builder:
              (context) => SimpleDialog(
                title: Text(tr(context, 'rsChooseBarcode')),
                children: [
                  for (final value in codes)
                    SimpleDialogOption(
                      onPressed: () => Navigator.pop(context, value),
                      child: Text(value),
                    ),
                ],
              ),
        );
      }
      if (!mounted) return;
      if (code == null) {
        setState(() => _statusKey = 'rsNoBarcode');
      } else {
        _barcode.text = code;
        await _lookup(alreadyBusy: true);
      }
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'rsBarcodeCaptureFailed');
    } finally {
      await scanner?.close();
      if (capturedPath != null) await _discard(capturedPath);
      if (mounted) setState(() => _busy = false);
      if (mounted &&
          _resumeCamera &&
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _resumeCamera = false;
        unawaited(_openCamera());
      }
    }
  }

  int _fractionDigits() {
    final code = _currency;
    if (code == null || code.isEmpty) {
      return NumberFormat.decimalPattern(
        Localizations.localeOf(context).toString(),
      ).maximumFractionDigits;
    }
    return NumberFormat.currency(name: code).decimalDigits ?? 0;
  }

  String _priceText(num minor) {
    final digits = _fractionDigits();
    final format =
        NumberFormat.decimalPattern(Localizations.localeOf(context).toString())
          ..minimumFractionDigits = digits
          ..maximumFractionDigits = digits
          ..turnOffGrouping();
    return format.format(minor / math.pow(10, digits));
  }

  int? _priceMinor() {
    if (_price.text.trim().isEmpty) return null;
    final digits = _fractionDigits();
    final decimal =
        NumberFormat.decimalPattern(
          Localizations.localeOf(context).toString(),
        ).symbols.DECIMAL_SEP;
    final normalized = _price.text.trim().replaceAll(decimal, '.');
    if (!RegExp(r'^\d+(\.\d+)?$').hasMatch(normalized)) {
      throw const FormatException('price');
    }
    final parts = normalized.split('.');
    final fraction = parts.length > 1 ? parts[1] : '';
    if (fraction.length > digits) {
      throw const FormatException('price_precision');
    }
    final scale = math.pow(10, digits).toInt();
    return int.parse(parts[0]) * scale +
        (fraction.isEmpty ? 0 : int.parse(fraction.padRight(digits, '0')));
  }

  void _applyProduct(Map<String, dynamic> product) {
    _applyingProduct = true;
    _name.text = product['name']?.toString() ?? '';
    _brand.text = product['brand']?.toString() ?? '';
    _category.text = product['category']?.toString() ?? '';
    _barcode.text = product['barcode']?.toString() ?? _barcode.text;
    _netWeight.text = product['net_weight']?.toString() ?? '';
    _ingredients.text = product['ingredients']?.toString() ?? '';
    final allergens = product['allergens'];
    _allergens.text =
        allergens is List
            ? allergens.map((e) => e.toString()).join(', ')
            : allergens?.toString() ?? '';
    _manufacturer.text = product['manufacturer']?.toString() ?? '';
    _shelfLife.text = product['shelf_life']?.toString() ?? '';
    _isVeg = product['is_veg'] is bool ? product['is_veg'] as bool : null;
    final recordedCurrency = product['currency']?.toString();
    final recordedPrice = product['price_minor'];
    _priceWithUnknownCurrency = null;
    if (recordedPrice is int &&
        (recordedCurrency == null || recordedCurrency.isEmpty)) {
      // A minor-unit amount cannot be interpreted without its denomination.
      _currency = null;
      _priceWithUnknownCurrency = recordedPrice;
      _price.clear();
    } else {
      _currency = recordedCurrency ?? (widget.item == null ? _currency : null);
      _price.text = recordedPrice is num ? _priceText(recordedPrice) : '';
    }
    _lookupSource = product['source']?.toString();
    for (final controller in _nutrition.values) {
      controller.dispose();
    }
    _nutrition.clear();
    final nutrition = product['nutrition'];
    if (nutrition is Map) {
      for (final entry in nutrition.entries) {
        _nutrition[entry.key.toString()] = TextEditingController(
          text: entry.value?.toString() ?? '',
        );
      }
    }
    if (_photo == null && product['image_base64'] is String) {
      try {
        _image = base64Decode(product['image_base64'] as String);
      } catch (_) {
        _image = null;
      }
    }
    _boundBarcode = _barcode.text.trim();
    _applyingProduct = false;
  }

  Future<void> _lookup({bool alreadyBusy = false}) async {
    final barcode = _barcode.text.trim();
    if (barcode.isEmpty || (_busy && !alreadyBusy)) return;
    final generation = ++_lookupGeneration;
    if (widget.item == null) _productId = null;
    if (!alreadyBusy) {
      setState(() {
        _busy = true;
        _errorKey = null;
      });
    }
    try {
      final app = ref.read(appControllerProvider);
      final identity = app.identityGeneration;
      final result = await app.repository.get(
        '/products/lookup',
        query: {
          'barcode': barcode,
          if (app.isStandalone) 'store_id': app.store?['id'],
        },
      );
      if (!mounted ||
          identity != app.identityGeneration ||
          generation != _lookupGeneration ||
          _barcode.text.trim() != barcode) {
        return;
      }
      final raw = result is Map ? result['product'] : null;
      if (result is Map && result['found'] == true && raw is Map) {
        final product = {...Map<String, dynamic>.from(raw), 'barcode': barcode};
        final knownId = product['id']?.toString();
        setState(() {
          _applyProduct(product);
          if (widget.item == null) {
            _productId =
                app.products.any(
                      (e) =>
                          e['id']?.toString() == knownId &&
                          e['barcode']?.toString().trim() == barcode,
                    )
                    ? knownId
                    : null;
          }
          _lookupSource =
              product['source']?.toString() ??
              result['source']?.toString() ??
              _lookupSource;
          _statusKey = 'rsLookupFound';
        });
      } else {
        setState(() {
          if (_boundBarcode != null) _clearLookupDetails();
          if (widget.item == null) _productId = null;
          _statusKey = 'rsLookupMissing';
          _lookupSource = 'manual';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'rsLookupFailed');
    } finally {
      if (mounted && !alreadyBusy) setState(() => _busy = false);
    }
  }

  Future<void> _addNutrition() async {
    final name = TextEditingController();
    final value = TextEditingController();
    final form = GlobalKey<FormState>();
    final accepted = await showDialog<bool>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: Text(tr(context, 'rsAddNutrient')),
            content: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextFormField(
                    controller: name,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsNutrientName'),
                    ),
                    validator:
                        (v) =>
                            v == null || v.trim().isEmpty
                                ? tr(context, 'rsRequired')
                                : _nutrition.containsKey(v.trim())
                                ? tr(context, 'rsDuplicateNutrient')
                                : null,
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: value,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsNutrientValue'),
                    ),
                    validator:
                        (v) =>
                            v == null || v.trim().isEmpty
                                ? tr(context, 'rsRequired')
                                : null,
                  ),
                ],
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
                child: Text(tr(context, 'rsAdd')),
              ),
            ],
          ),
    );
    if (accepted == true && mounted) {
      setState(
        () =>
            _nutrition[name.text.trim()] = TextEditingController(
              text: value.text.trim(),
            ),
      );
    }
    name.dispose();
    value.dispose();
  }

  String? _required(String? value) =>
      value == null || value.trim().isEmpty ? tr(context, 'rsRequired') : null;
  String? _positiveInteger(String? value) =>
      (int.tryParse(value ?? '') ?? 0) < 1
          ? tr(context, 'rsPositiveNumber')
          : null;

  Future<void> _save() async {
    if (_busy || !(_form.currentState?.validate() ?? false)) return;
    final app = ref.read(appControllerProvider);
    final identity = app.identityGeneration;
    final storeId = app.store?['id']?.toString();
    if (storeId == null) return;
    // ListView forms lazily unmount off-screen validators, so validate every
    // required controller before starting any product or inventory mutation.
    final row = int.tryParse(_row.text);
    final slot = int.tryParse(_slot.text);
    final quantity = int.tryParse(_quantity.text);
    if (_name.text.trim().isEmpty ||
        row == null ||
        row < 1 ||
        slot == null ||
        slot < 1 ||
        quantity == null ||
        quantity < 0) {
      setState(() => _errorKey = 'rsReviewRequiredProduct');
      return;
    }
    int? priceMinor;
    try {
      priceMinor = _priceMinor();
    } catch (_) {
      setState(() => _errorKey = 'rsInvalidPrice');
      return;
    }
    if (priceMinor != null && (_currency == null || _currency!.isEmpty)) {
      setState(() => _errorKey = 'rsPriceCurrencyRequired');
      return;
    }
    if (app.items.any(
      (e) =>
          e['shelf_id']?.toString() == widget.shelfId &&
          e['id']?.toString() != _itemId &&
          e['row']?.toString() == row.toString() &&
          e['slot']?.toString() == slot.toString(),
    )) {
      setState(() => _errorKey = 'rsSlotCollision');
      return;
    }
    setState(() {
      _busy = true;
      _errorKey = null;
    });
    try {
      String? optional(TextEditingController field) =>
          field.text.trim().isEmpty ? null : field.text.trim();
      final product = <String, dynamic>{
        'name': _name.text.trim(),
        'barcode': optional(_barcode),
        'brand': optional(_brand),
        'category': optional(_category),
        'net_weight': optional(_netWeight),
        'price_minor': priceMinor ?? _priceWithUnknownCurrency,
        'currency': _currency,
        'is_veg': _isVeg,
        'ingredients': optional(_ingredients),
        'allergens': optional(_allergens),
        'manufacturer': optional(_manufacturer),
        'shelf_life': optional(_shelfLife),
        'nutrition': {
          for (final entry in _nutrition.entries)
            if (entry.value.text.trim().isNotEmpty)
              entry.key: entry.value.text.trim(),
        },
        'image_base64': _image == null ? null : base64Encode(_image!),
        'source': _lookupSource ?? 'manual',
      };
      if (_productId == null) {
        final response = await app.repository.post(
          '/stores/${Uri.encodeComponent(storeId)}/products',
          product,
        );
        if (!mounted || identity != app.identityGeneration) return;
        final id = response is Map ? response['id']?.toString() : null;
        if (id == null) throw StateError('missing_product_id');
        _productId = id;
        _boundBarcode = _barcode.text.trim();
      } else {
        await app.repository.patch(
          '/products/${Uri.encodeComponent(_productId!)}',
          product,
        );
      }
      if (!mounted || identity != app.identityGeneration) return;
      final item = {'row': row, 'slot': slot, 'quantity': quantity};
      if (_itemId == null) {
        final response = await app.repository.post(
          '/shelves/${Uri.encodeComponent(widget.shelfId)}/items',
          {'product_id': _productId, ...item},
        );
        if (!mounted || identity != app.identityGeneration) return;
        final id = response is Map ? response['id']?.toString() : null;
        if (id == null) throw StateError('missing_item_id');
        _itemId = id;
      } else {
        await app.repository.patch(
          '/items/${Uri.encodeComponent(_itemId!)}',
          item,
        );
      }
      if (!mounted || identity != app.identityGeneration) return;
      await app.refresh();
      if (!mounted || identity != app.identityGeneration) return;
      if (Navigator.canPop(context)) {
        Navigator.pop(context, true);
      } else {
        context.go('/shelf/${Uri.encodeComponent(widget.shelfId)}');
      }
    } catch (_) {
      if (mounted) setState(() => _errorKey = 'rsSaveProductFailed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final theme = Theme.of(context);
    final camera = _camera;
    final shelves = app.shelves.where(
      (e) => e['id']?.toString() == widget.shelfId,
    );
    final shelfName =
        shelves.isEmpty
            ? tr(context, 'rsShelf')
            : shelves.first['name']?.toString() ?? tr(context, 'rsShelf');
    final currenciesRaw = app.config['currencies'];
    final currencies =
        currenciesRaw is List
            ? currenciesRaw.whereType<String>().toList()
            : <String>[];
    final recordedCurrency = _currency;
    if (recordedCurrency != null &&
        recordedCurrency.isNotEmpty &&
        !currencies.contains(recordedCurrency)) {
      currencies.add(recordedCurrency);
    }
    final rowValue = int.tryParse(_row.text);
    final slotValue = int.tryParse(_slot.text);
    final currentQuantity = int.tryParse(_quantity.text);
    return PageScaffold(
      title: tr(
        context,
        widget.item == null ? 'rsAddProduct' : 'rsEditProduct',
      ),
      actions: [
        IconButton(
          onPressed: _busy || _cameraLoading ? null : _openCamera,
          tooltip: tr(context, 'rsRetake'),
          icon: const Icon(Icons.camera_alt_outlined),
        ),
      ],
      bottom: BrandButton(
        label: tr(context, _busy ? 'rsPleaseWait' : 'rsAddToShelf', {
          'shelf': shelfName,
        }),
        icon: Icons.check,
        onPressed: _busy ? null : _save,
      ),
      child: Form(
        key: _form,
        child: ListView(
          padding: const EdgeInsets.all(Tokens.md),
          children: [
            if (_errorKey != null)
              ErrorNotice(message: tr(context, _errorKey!)),
            InfoCard(
              child: Column(
                children: [
                  if (_cameraLoading)
                    const Padding(
                      padding: EdgeInsets.all(Tokens.xl),
                      child: CircularProgressIndicator(),
                    )
                  else if (camera != null && camera.value.isInitialized) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(Tokens.md),
                      child: AspectRatio(
                        aspectRatio: camera.value.aspectRatio,
                        child: CameraPreview(camera),
                      ),
                    ),
                    const SizedBox(height: Tokens.md),
                    BrandButton(
                      label: tr(context, 'rsCaptureBarcode'),
                      icon: Icons.document_scanner_outlined,
                      onPressed: _busy ? null : _captureAndRead,
                    ),
                  ] else if (_image != null)
                    Image.memory(
                      _image!,
                      height: Tokens.xl * 6,
                      fit: BoxFit.contain,
                      errorBuilder:
                          (_, _, _) => EmptyState(
                            message: tr(context, 'rsImageUnavailable'),
                            icon: Icons.broken_image_outlined,
                          ),
                    )
                  else ...[
                    Icon(
                      Icons.add_photo_alternate_outlined,
                      size: Tokens.xl * 2,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: Tokens.sm),
                    Text(
                      tr(context, 'rsProductCaptureHelp'),
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                    const SizedBox(height: Tokens.md),
                    OutlinedButton.icon(
                      onPressed: _busy ? null : _openCamera,
                      icon: const Icon(Icons.camera_alt_outlined),
                      label: Text(tr(context, 'rsOpenCamera')),
                    ),
                  ],
                  const SizedBox(height: Tokens.md),
                  if (_statusKey != null) ...[
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          _statusKey == 'rsLookupFound'
                              ? Icons.check_circle_outline
                              : Icons.info_outline,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: Tokens.sm),
                        Expanded(
                          child: Text(
                            tr(context, _statusKey!),
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: Tokens.md),
                  ],
                  if (_lookupSource == 'open_food_facts')
                    Text(tr(context, 'rsCatalogAttribution')),
                  TextFormField(
                    controller: _barcode,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsBarcode'),
                      prefixIcon: const Icon(Icons.qr_code),
                      suffixIcon: IconButton(
                        onPressed: _busy ? null : _lookup,
                        tooltip: tr(context, 'rsLookup'),
                        icon: const Icon(Icons.search),
                      ),
                    ),
                  ),
                  const SizedBox(height: Tokens.sm),
                  Text(
                    tr(context, 'rsBarcodePrivacy'),
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
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          tr(context, 'rsProductDetails'),
                          style: theme.textTheme.titleLarge,
                        ),
                      ),
                      IconButton(
                        onPressed:
                            () => setState(() => _showDetails = !_showDetails),
                        tooltip: tr(context, 'rsEditDetails'),
                        icon: Icon(
                          _showDetails
                              ? Icons.expand_less
                              : Icons.edit_outlined,
                        ),
                      ),
                    ],
                  ),
                  TextFormField(
                    controller: _name,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsProductName'),
                    ),
                    validator: _required,
                  ),
                  if (_showDetails) ...[
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _brand,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsBrand'),
                      ),
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _category,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsCategory'),
                      ),
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _netWeight,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsNetWeight'),
                      ),
                    ),
                    const SizedBox(height: Tokens.md),
                    DropdownButtonFormField<String>(
                      initialValue:
                          currencies.contains(_currency) ? _currency : null,
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsCurrency'),
                      ),
                      items: [
                        for (final code in currencies)
                          DropdownMenuItem(value: code, child: Text(code)),
                      ],
                      onChanged:
                          _busy
                              ? null
                              : (value) => setState(() {
                                if (value != _currency) {
                                  _price.clear();
                                  _priceWithUnknownCurrency = null;
                                }
                                _currency = value;
                              }),
                      validator:
                          (value) =>
                              _price.text.trim().isNotEmpty && value == null
                                  ? tr(context, 'rsRequired')
                                  : null,
                    ),
                    const SizedBox(height: Tokens.md),
                    TextFormField(
                      controller: _price,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsPrice'),
                        helperText: tr(
                          context,
                          _priceWithUnknownCurrency == null
                              ? 'rsUnknownPrice'
                              : 'rsStoredPriceUnknownCurrency',
                        ),
                      ),
                      validator: (_) {
                        try {
                          _priceMinor();
                          return null;
                        } catch (_) {
                          return tr(context, 'rsInvalidPrice');
                        }
                      },
                    ),
                    const SizedBox(height: Tokens.md),
                    DropdownButtonFormField<String>(
                      initialValue:
                          _isVeg == null
                              ? 'unknown'
                              : _isVeg == true
                              ? 'yes'
                              : 'no',
                      decoration: InputDecoration(
                        labelText: tr(context, 'rsVegetarian'),
                      ),
                      items: [
                        for (final choice in ['unknown', 'yes', 'no'])
                          DropdownMenuItem(
                            value: choice,
                            child: Text(tr(context, 'rsChoice_$choice')),
                          ),
                      ],
                      onChanged:
                          _busy
                              ? null
                              : (value) => setState(
                                () =>
                                    _isVeg =
                                        value == 'yes'
                                            ? true
                                            : value == 'no'
                                            ? false
                                            : null,
                              ),
                    ),
                    const SizedBox(height: Tokens.sm),
                    Text(
                      tr(context, 'rsNoRegulatoryClaim'),
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: Tokens.md),
            InfoCard(
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr(context, 'rsNutrition')),
                leading: const Icon(Icons.bar_chart_outlined),
                children: [
                  if (_nutrition.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.md),
                      child: Text(tr(context, 'rsUnknownNutrition')),
                    ),
                  for (final entry in _nutrition.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Tokens.md),
                      child: TextFormField(
                        controller: entry.value,
                        decoration: InputDecoration(labelText: entry.key),
                      ),
                    ),
                  TextButton.icon(
                    onPressed: _busy ? null : _addNutrition,
                    icon: const Icon(Icons.add),
                    label: Text(tr(context, 'rsAddNutrient')),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Tokens.md),
            InfoCard(
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr(context, 'rsIngredientsAllergens')),
                leading: const Icon(Icons.eco_outlined),
                children: [
                  TextFormField(
                    controller: _ingredients,
                    maxLines: 3,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsIngredients'),
                    ),
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: _allergens,
                    maxLines: 2,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsAllergens'),
                      helperText: tr(context, 'rsUnknownAllergens'),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: Tokens.md),
            InfoCard(
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: Text(tr(context, 'rsManufacturerShelfLife')),
                leading: const Icon(Icons.factory_outlined),
                children: [
                  TextFormField(
                    controller: _manufacturer,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsManufacturer'),
                    ),
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: _shelfLife,
                    decoration: InputDecoration(
                      labelText: tr(context, 'rsShelfLife'),
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
                    tr(context, 'rsPlaceOnShelf'),
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: Tokens.sm),
                  Text(shelfName, style: theme.textTheme.bodyMedium),
                  const SizedBox(height: Tokens.md),
                  Container(
                    padding: const EdgeInsets.all(Tokens.md),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer,
                      borderRadius: BorderRadius.circular(Tokens.md),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shelves, color: theme.colorScheme.primary),
                        const SizedBox(width: Tokens.md),
                        Expanded(
                          child: Text(
                            rowValue == null || slotValue == null
                                ? tr(context, 'rsChoosePosition')
                                : tr(context, 'rsPosition', {
                                  'row': NumberFormat.decimalPattern(
                                    Localizations.localeOf(context).toString(),
                                  ).format(rowValue),
                                  'slot': NumberFormat.decimalPattern(
                                    Localizations.localeOf(context).toString(),
                                  ).format(slotValue),
                                }),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Tokens.md),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _row,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: tr(context, 'rsRow'),
                          ),
                          validator: _positiveInteger,
                        ),
                      ),
                      const SizedBox(width: Tokens.md),
                      Expanded(
                        child: TextFormField(
                          controller: _slot,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: tr(context, 'rsSlot'),
                          ),
                          validator: _positiveInteger,
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
                    tr(context, 'rsQuantity'),
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: Tokens.md),
                  Row(
                    children: [
                      IconButton.filledTonal(
                        onPressed:
                            _busy ||
                                    currentQuantity == null ||
                                    currentQuantity <= 0
                                ? null
                                : () =>
                                    _quantity.text =
                                        (currentQuantity - 1).toString(),
                        tooltip: tr(context, 'rsDecreaseQuantity'),
                        icon: const Icon(Icons.remove),
                      ),
                      const SizedBox(width: Tokens.md),
                      Expanded(
                        child: TextFormField(
                          controller: _quantity,
                          textAlign: TextAlign.center,
                          keyboardType: TextInputType.number,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                          ],
                          decoration: InputDecoration(
                            labelText: tr(context, 'rsUnitsOnShelf'),
                          ),
                          validator:
                              (v) =>
                                  int.tryParse(v ?? '') == null ||
                                          int.parse(v!) < 0
                                      ? tr(context, 'rsNonnegativeNumber')
                                      : null,
                        ),
                      ),
                      const SizedBox(width: Tokens.md),
                      IconButton.filledTonal(
                        onPressed:
                            _busy || currentQuantity == null
                                ? null
                                : () =>
                                    _quantity.text =
                                        (currentQuantity + 1).toString(),
                        tooltip: tr(context, 'rsIncreaseQuantity'),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
                  const SizedBox(height: Tokens.sm),
                  Text(
                    tr(context, 'rsEnterCountedQuantity'),
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: Tokens.lg),
          ],
        ),
      ),
    );
  }
}
