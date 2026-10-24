import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/api_client.dart';
import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

class CloudConnectionScreen extends ConsumerStatefulWidget {
  const CloudConnectionScreen({super.key});

  @override
  ConsumerState<CloudConnectionScreen> createState() =>
      _CloudConnectionScreenState();
}

class _CloudConnectionScreenState extends ConsumerState<CloudConnectionScreen> {
  final _hostedForm = GlobalKey<FormState>();
  final _localForm = GlobalKey<FormState>();
  late final TextEditingController _address;
  late final TextEditingController _fingerprint;
  late final TextEditingController _secret;
  late final TextEditingController _device;
  bool _localMode = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final api = ref.read(appControllerProvider).api;
    _address = TextEditingController(text: api.serverAddress ?? '');
    _fingerprint = TextEditingController();
    _secret = TextEditingController();
    _device = TextEditingController(text: 'ShelfSight Android');
    _localMode = api.localMode || !api.hasApiAddress;
  }

  @override
  void dispose() {
    _address.dispose();
    _fingerprint.dispose();
    _secret.dispose();
    _device.dispose();
    super.dispose();
  }

  Future<void> _connectHosted() async {
    if (_busy || _hostedForm.currentState?.validate() != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(appControllerProvider)
          .reconnectCloud(address: _address.text);
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pairLocal() async {
    if (_busy || _localForm.currentState?.validate() != true) return;
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
    } catch (error) {
      if (mounted) setState(() => _error = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? _validAddress(String? value) {
    try {
      apiUri(value ?? '');
      return null;
    } catch (_) {
      return tr(context, 'invalidServerAddress');
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = ref.watch(appControllerProvider);
    final error = _error ?? app.error;
    return PageScaffold(
      title: tr(context, 'apiConnection'),
      actions: [
        IconButton(
          tooltip: tr(context, 'logout'),
          icon: const Icon(Icons.logout),
          onPressed: _busy ? null : app.logout,
        ),
      ],
      child: ListView(
        padding: const EdgeInsets.all(Tokens.lg),
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            spacing: Tokens.sm,
            children: [
              ChoiceChip(
                label: Text(tr(context, 'pairLaptop')),
                selected: _localMode,
                onSelected:
                    _busy ? null : (value) => setState(() => _localMode = true),
              ),
              ChoiceChip(
                label: Text(tr(context, 'hostedApi')),
                selected: !_localMode,
                onSelected:
                    _busy
                        ? null
                        : (value) => setState(() => _localMode = false),
              ),
            ],
          ),
          const SizedBox(height: Tokens.md),
          InfoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Icon(
                  _localMode ? Icons.laptop_windows : Icons.cloud_outlined,
                  size: 64,
                  color: Tokens.teal,
                ),
                const SizedBox(height: Tokens.md),
                Text(
                  tr(
                    context,
                    _localMode ? 'pairHeading' : 'apiConnectionHeading',
                  ),
                  style: Theme.of(context).textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: Tokens.md),
                Text(
                  tr(
                    context,
                    _localMode
                        ? 'pairInstructions'
                        : 'apiConnectionInstructions',
                  ),
                ),
                if (_localMode) ...[
                  const SizedBox(height: Tokens.sm),
                  Text(tr(context, 'fingerprintNotice')),
                ],
              ],
            ),
          ),
          if (error != null) ErrorNotice(message: tr(context, error)),
          if (_localMode)
            Form(
              key: _localForm,
              child: Column(
                children: [
                  TextFormField(
                    controller: _address,
                    enabled: !_busy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: tr(context, 'serverAddress'),
                    ),
                    validator: _validAddress,
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: _fingerprint,
                    enabled: !_busy,
                    autocorrect: false,
                    decoration: InputDecoration(
                      labelText: tr(context, 'certificateFingerprint'),
                    ),
                    validator:
                        (value) =>
                            RegExp(
                                  r'^[a-f0-9]{64}$',
                                ).hasMatch(normalizeFingerprint(value ?? ''))
                                ? null
                                : tr(context, 'invalidPairing'),
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: _secret,
                    enabled: !_busy,
                    autocorrect: false,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: tr(context, 'pairingSecret'),
                    ),
                    validator:
                        (value) =>
                            value == null || value.trim().isEmpty
                                ? tr(context, 'requiredField')
                                : null,
                  ),
                  const SizedBox(height: Tokens.md),
                  TextFormField(
                    controller: _device,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: tr(context, 'deviceName'),
                    ),
                    validator:
                        (value) =>
                            value == null || value.trim().isEmpty
                                ? tr(context, 'requiredField')
                                : null,
                  ),
                  const SizedBox(height: Tokens.lg),
                  BrandButton(
                    label: tr(context, _busy ? 'connecting' : 'securePair'),
                    icon: Icons.link,
                    onPressed: _busy ? null : _pairLocal,
                  ),
                ],
              ),
            )
          else
            Form(
              key: _hostedForm,
              child: Column(
                children: [
                  TextFormField(
                    controller: _address,
                    enabled: !_busy,
                    autocorrect: false,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      labelText: tr(context, 'apiAddress'),
                    ),
                    validator: _validAddress,
                    onFieldSubmitted: (_) => _connectHosted(),
                  ),
                  const SizedBox(height: Tokens.lg),
                  BrandButton(
                    label: tr(context, _busy ? 'connecting' : 'connectApi'),
                    icon: Icons.cloud_done_outlined,
                    onPressed: _busy ? null : _connectHosted,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
