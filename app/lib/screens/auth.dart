import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/app_controller.dart';
import '../core/strings.dart';
import '../core/theme.dart';
import '../widgets/shared.dart';

class AuthScreen extends ConsumerStatefulWidget {
  const AuthScreen({super.key});
  @override
  ConsumerState<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends ConsumerState<AuthScreen> {
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _name = TextEditingController();
  bool _register = false;
  bool _showPassword = false;
  bool _working = false;
  String? _error;
  String? _notice;
  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _action(
    Future<void> Function() action, {
    bool reset = false,
  }) async {
    if (_working) return;
    setState(() {
      _working = true;
      _error = null;
      _notice = null;
    });
    try {
      await action();
      if (mounted && reset) setState(() => _notice = 'resetSent');
    } on FirebaseAuthException catch (e) {
      if (mounted) {
        setState(
          () => _error = switch (e.code) {
            'email-already-in-use' => 'emailInUse',
            'weak-password' => 'weakPassword',
            'invalid-email' => 'invalidEmail',
            'network-request-failed' => 'connectionFailed',
            'too-many-requests' => 'tryLater',
            'operation-not-allowed' => 'providerDisabled',
            _ => 'loginFailed',
          },
        );
      }
    } catch (e) {
      if (mounted) setState(() => _error = friendlyError(e));
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = ref.watch(appControllerProvider);
    final enabled = controller.firebaseConfigured && !_working;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: ListView(
              padding: const EdgeInsets.all(Tokens.lg),
              children: [
                const SizedBox(height: Tokens.lg),
                Image.asset(
                  'assets/logo.jpeg',
                  height: 148,
                  fit: BoxFit.contain,
                  semanticLabel: tr(context, 'brand'),
                ),
                const SizedBox(height: Tokens.md),
                Text(
                  tr(context, 'brand'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.displaySmall
                      ?.copyWith(fontWeight: FontWeight.w900),
                ),
                Text(
                  tr(context, 'tagline'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(color: Tokens.muted),
                ),
                const SizedBox(height: Tokens.xl),
                if (!controller.firebaseConfigured)
                  InfoCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(
                          Icons.settings_suggest_outlined,
                          color: Tokens.teal,
                          size: 36,
                        ),
                        const SizedBox(height: Tokens.md),
                        Text(
                          tr(context, 'configurationRequired'),
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: Tokens.sm),
                        Text(
                          tr(
                            context,
                            controller.bootstrapError ??
                                'configurationInstructions',
                          ),
                        ),
                        const SizedBox(height: Tokens.md),
                        SelectableText(
                          tr(context, 'configurationKeys'),
                          style: Theme.of(context).textTheme.bodySmall,
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
                          tr(
                            context,
                            _register ? 'createAccount' : 'welcomeBack',
                          ),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.headlineMedium
                              ?.copyWith(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: Tokens.sm),
                        Text(
                          tr(
                            context,
                            _register ? 'accountSubtitle' : 'loginSubtitle',
                          ),
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Tokens.muted),
                        ),
                        const SizedBox(height: Tokens.lg),
                        if (_register) ...[
                          TextFormField(
                            controller: _name,
                            textCapitalization: TextCapitalization.words,
                            autofillHints: const [AutofillHints.name],
                            enabled: enabled,
                            decoration: InputDecoration(
                              labelText: tr(context, 'yourName'),
                              prefixIcon: const Icon(Icons.person_outline),
                            ),
                            validator: (v) => v == null || v.trim().isEmpty
                                ? tr(context, 'requiredField')
                                : null,
                          ),
                          const SizedBox(height: Tokens.md),
                        ],
                        TextFormField(
                          controller: _email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          enabled: enabled,
                          decoration: InputDecoration(
                            labelText: tr(context, 'email'),
                            prefixIcon: const Icon(Icons.mail_outline),
                          ),
                          validator: (v) =>
                              v == null ||
                                  !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                                      .hasMatch(v.trim())
                              ? tr(context, 'invalidEmail')
                              : null,
                        ),
                        const SizedBox(height: Tokens.md),
                        TextFormField(
                          controller: _password,
                          obscureText: !_showPassword,
                          autofillHints: [
                            _register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          enabled: enabled,
                          decoration: InputDecoration(
                            labelText: tr(context, 'password'),
                            prefixIcon: const Icon(Icons.lock_outline),
                            suffixIcon: IconButton(
                              tooltip: tr(
                                context,
                                _showPassword ? 'hidePassword' : 'showPassword',
                              ),
                              onPressed: () => setState(
                                () => _showPassword = !_showPassword,
                              ),
                              icon: Icon(
                                _showPassword
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                              ),
                            ),
                          ),
                          validator: (v) => v == null || v.isEmpty
                              ? tr(context, 'requiredField')
                              : _register && v.length < 6
                              ? tr(context, 'weakPassword')
                              : null,
                        ),
                        if (!_register)
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: enabled
                                  ? () {
                                      if (_email.text.trim().isEmpty) {
                                        setState(
                                          () => _error = 'enterEmailFirst',
                                        );
                                        return;
                                      }
                                      _action(
                                        () => controller.resetPassword(
                                          _email.text,
                                        ),
                                        reset: true,
                                      );
                                    }
                                  : null,
                              child: Text(tr(context, 'forgotPassword')),
                            ),
                          ),
                        if (_error != null)
                          ErrorNotice(message: tr(context, _error!)),
                        if (_notice != null)
                          Padding(
                            padding: const EdgeInsets.all(Tokens.md),
                            child: Text(
                              tr(context, _notice!),
                              style: const TextStyle(color: Tokens.teal),
                            ),
                          ),
                        const SizedBox(height: Tokens.md),
                        BrandButton(
                          label: tr(
                            context,
                            _register ? 'createAccount' : 'login',
                          ),
                          icon: _working
                              ? Icons.hourglass_top
                              : Icons.arrow_forward,
                          onPressed: enabled
                              ? () {
                                  if (_form.currentState?.validate() != true) {
                                    return;
                                  }
                                  _action(
                                    () => _register
                                        ? controller.register(
                                            _name.text,
                                            _email.text,
                                            _password.text,
                                          )
                                        : controller.login(
                                            _email.text,
                                            _password.text,
                                          ),
                                  );
                                }
                              : null,
                        ),
                        const SizedBox(height: Tokens.md),
                        BrandButton(
                          label: tr(context, 'continueGoogle'),
                          icon: Icons.account_circle_outlined,
                          outlined: true,
                          onPressed: enabled
                              ? () => _action(controller.googleLogin)
                              : null,
                        ),
                      ],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _working
                      ? null
                      : () => setState(() {
                          _register = !_register;
                          _error = null;
                          _notice = null;
                        }),
                  child: Text(
                    tr(context, _register ? 'alreadyAccount' : 'newAccount'),
                  ),
                ),
                Text(
                  tr(context, 'privacySummary'),
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: Tokens.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
