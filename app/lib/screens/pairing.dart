import 'dart:convert';
import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

class PairingScreen extends ConsumerStatefulWidget {
  const PairingScreen({super.key});
  @override
  ConsumerState<PairingScreen> createState() => _PairingScreenState();
}

class _PairingScreenState extends ConsumerState<PairingScreen> {
  final _form = GlobalKey<FormState>();
  final _address = TextEditingController();
  final _fingerprint = TextEditingController();
  final _secret = TextEditingController();
  final _device = TextEditingController();
  bool _busy = false;
  String? _error;
  @override
  void dispose() {
    _address.dispose();
    _fingerprint.dispose();
    _secret.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final data = await Navigator.of(context)
        .push<String>(MaterialPageRoute(builder: (_) => const _PairQrCamera()));
    if (!mounted || data == null) return;
    try {
      final value = jsonDecode(data);
      if (value is! Map) throw const FormatException();
      final address =
          value['address'] ?? value['server_url'] ?? value['server'];
      final pin =
          value['fingerprint'] ??
          value['fingerprint_sha256'] ??
          value['certificate_sha256'];
      final secret = value['pairing_secret'];
      if (address is! String || pin is! String || secret is! String) {
        throw const FormatException();
      }
      setState(() {
        _address.text = address;
        _fingerprint.text = pin;
        _secret.text = secret;
        _error = null;
      });
    } catch (_) {
      setState(() => _error = 'invalidPairingQr');
    }
  }

  Future<void> _pair() async {
    if (_form.currentState?.validate() != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider)
          .pair(
            address: _address.text,
            fingerprint: _fingerprint.text,
            secret: _secret.text,
            deviceName: _device.text,
          );
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: tr(context, 'pairLaptop'),
    actions: [
      IconButton(
        tooltip: tr(context, 'logout'),
        icon: const Icon(Icons.logout),
        onPressed: _busy
            ? null
            : () => ref.read(appControllerProvider).logout(),
      ),
    ],
    child: ListView(
      padding: const EdgeInsets.all(Tokens.md),
      children: [
        InfoCard(
          child: Column(
            children: [
              const Icon(
                Icons.phonelink_lock_outlined,
                size: 70,
                color: Tokens.teal,
              ),
              const SizedBox(height: Tokens.md),
              Text(
                tr(context, 'pairHeading'),
                style: Theme.of(context).textTheme.headlineSmall,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: Tokens.md),
              Text(tr(context, 'pairInstructions')),
              const SizedBox(height: Tokens.md),
              BrandButton(
                label: tr(context, 'scanPairQr'),
                icon: Icons.qr_code_scanner,
                onPressed: _busy ? null : _scan,
              ),
            ],
          ),
        ),
        InfoCard(
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  tr(context, 'manualPairing'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: Tokens.md),
                for (final field in [
                  (_address, 'serverAddress', Icons.computer),
                  (
                    _fingerprint,
                    'certificateFingerprint',
                    Icons.verified_user_outlined,
                  ),
                  (_secret, 'pairingSecret', Icons.key_outlined),
                  (_device, 'deviceName', Icons.smartphone),
                ]) ...[
                  TextFormField(
                    controller: field.$1,
                    enabled: !_busy,
                    autocorrect: false,
                    obscureText: field.$2 == 'pairingSecret',
                    decoration: InputDecoration(
                      labelText: tr(context, field.$2),
                      prefixIcon: Icon(field.$3),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? tr(context, 'requiredField')
                        : null,
                  ),
                  const SizedBox(height: Tokens.md),
                ],
                Text(
                  tr(context, 'fingerprintNotice'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ErrorNotice(message: tr(context, _error!)),
                const SizedBox(height: Tokens.md),
                BrandButton(
                  label: tr(context, _busy ? 'connecting' : 'securePair'),
                  icon: Icons.lock_outline,
                  onPressed: _busy ? null : _pair,
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

class _PairQrCamera extends StatefulWidget {
  const _PairQrCamera();
  @override
  State<_PairQrCamera> createState() => _PairQrCameraState();
}

class _PairQrCameraState extends State<_PairQrCamera>
    with WidgetsBindingObserver {
  CameraController? _camera;
  final _scanner = BarcodeScanner(formats: [BarcodeFormat.qrCode]);
  String? _error;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
  }

  Future<void> _initialize() async {
    if (_camera != null) return;
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) throw const ApiFailure('cameraUnavailable');
      final camera = CameraController(
        cameras.firstWhere(
          (c) => c.lensDirection == CameraLensDirection.back,
          orElse: () => cameras.first,
        ),
        ResolutionPreset.medium,
        enableAudio: false,
      );
      _camera = camera;
      await camera.initialize();
      if (mounted) {
        setState(() => _error = null);
      } else {
        await camera.dispose();
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'cameraUnavailable');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      final previous = _camera;
      _camera = null;
      previous?.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initialize();
    }
  }

  Future<void> _capture() async {
    if (_busy || _camera?.value.isInitialized != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    XFile? file;
    try {
      file = await _camera!.takePicture();
      final values = await _scanner.processImage(
        InputImage.fromFilePath(file.path),
      );
      final data = values
          .map((b) => b.rawValue)
          .whereType<String>()
          .firstOrNull;
      if (!mounted) return;
      if (data == null) {
        setState(() => _error = 'qrNotFound');
      } else {
        Navigator.of(context).pop(data);
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'cameraUnavailable');
    } finally {
      if (file != null) {
        try {
          await File(file.path).delete();
        } catch (_) {}
      }
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _camera?.dispose();
    _scanner.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PageScaffold(
    title: tr(context, 'scanPairQr'),
    bottom: BrandButton(
      label: tr(context, 'captureQr'),
      icon: Icons.camera_alt_outlined,
      onPressed: _busy ? null : _capture,
    ),
    child: Column(
      children: [
        Expanded(
          child: Center(
            child: _camera?.value.isInitialized == true
                ? CameraPreview(_camera!)
                : const CircularProgressIndicator(),
          ),
        ),
        if (_error != null) ErrorNotice(message: tr(context, _error!)),
      ],
    ),
  );
}
