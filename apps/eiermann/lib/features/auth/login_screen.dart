import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Email and password.
///
/// Two things happen before the form is offered at all:
///
/// * the server's `/info` is read, so the instance name can be shown and the
///   sign-in options match what the server actually has;
/// * the app/server version pair is checked, and a mismatch shows a notice
///   naming WHICH SIDE is behind. Telling a user to update their app when the
///   server is the old one is a dead end they cannot act on.
///
/// Both fail OPEN. An unreachable `/info` must not block sign-in — the request
/// itself will report the real problem, and a login screen that refuses to draw
/// is worse than one that tries and fails.
class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final user = await repo.signIn(_email.text, _password.text);
      // The collection's authRule already refuses a deactivated account, but it
      // answers 400 — deliberately indistinguishable from a wrong password, so
      // an attacker learns nothing. That leaves the honest message to the
      // client, once it is actually holding the record.
      if (!user.isActive) {
        repo.signOut();
        if (mounted) {
          setState(() {
            _busy = false;
            _error = l10n.authErrorDeactivated;
          });
        }
        return;
      }
      // The router's gate takes it from here.
    } on RepositoryException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error =
            e.kind == RepositoryErrorKind.validation ||
                e.kind == RepositoryErrorKind.unauthorized
            ? l10n.authErrorInvalidCredentials
            : errorMessage(EiermannStrings(l10n), e);
      });
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'Sign-in failed');
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = l10n.errorGenericTitle;
      });
    }
  }

  Future<void> _resetPassword() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    if (_email.text.trim().isEmpty) {
      setState(() => _error = l10n.fieldRequired);
      return;
    }
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      await repo.requestPasswordReset(_email.text);
    } on Object catch (error, stackTrace) {
      // Reported, not shown: the message below is deliberately the same either
      // way, because saying "no such account" would let anyone enumerate the
      // team's addresses.
      reportCaughtError(error, stackTrace, context: 'Password reset failed');
    }
    messenger.showSnackBar(
      SnackBar(content: Text(l10n.authResetSentMessage)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final strings = EiermannStrings(l10n);
    // Read, never awaited: this screen must draw whatever /info says, including
    // nothing at all.
    final info = ref.watch(serverInfoProvider).value;
    final compatibility = ref.watch(serverCompatibilityProvider).value;
    final options = info?.auth ?? const ServerAuthOptions();

    final versionNotice = switch (compatibility) {
      ServerCompatibility.clientTooOld => l10n.authVersionClientTooOld,
      ServerCompatibility.serverTooOld => l10n.authVersionServerTooOld,
      _ => null,
    };

    return Scaffold(
      appBar: AppBar(title: Text(info?.name ?? l10n.authSignInTitle)),
      body: ContentBounds(
        maxWidth: 480,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ZugvogelSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (versionNotice != null) ...[
                  Card(
                    color: theme.colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(ZugvogelSpacing.md),
                      child: Text(
                        versionNotice,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: ZugvogelSpacing.lg),
                ],
                if (options.password) ...[
                  AppTextField(
                    label: l10n.authEmailLabel,
                    controller: _email,
                    enabled: !_busy,
                    autofocus: true,
                    keyboardType: TextInputType.emailAddress,
                    textInputAction: TextInputAction.next,
                    validator: Validators.compose([
                      Validators.required(strings),
                      Validators.email(strings),
                    ]),
                  ),
                  const SizedBox(height: ZugvogelSpacing.md),
                  AppTextField(
                    label: l10n.authPasswordLabel,
                    controller: _password,
                    enabled: !_busy,
                    obscureText: true,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => _signIn(),
                    validator: Validators.required(strings),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: ZugvogelSpacing.md),
                  Text(
                    _error!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: ZugvogelSpacing.lg),
                PrimaryButton(
                  label: l10n.authSignInAction,
                  isLoading: _busy,
                  onPressed: _signIn,
                ),
                // Only offered when the server can actually send the mail —
                // otherwise it is a button that silently does nothing.
                if (options.passwordReset) ...[
                  const SizedBox(height: ZugvogelSpacing.sm),
                  TextButton(
                    onPressed: _busy ? null : _resetPassword,
                    child: Text(l10n.authForgotPasswordAction),
                  ),
                ],
                const SizedBox(height: ZugvogelSpacing.lg),
                // Native only: on web the server IS the serving origin, so
                // there is nothing to change.
                if (ref.watch(serverConfigControllerProvider).value
                    case ServerConfigured() when !kIsWebPlatform)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => ref
                              .read(serverConfigControllerProvider.notifier)
                              .clearServerUrl(),
                    child: Text(l10n.setupChangeServerAction),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// `kIsWeb`, named so the import of `flutter/foundation` does not shadow
/// anything in this file.
const kIsWebPlatform = bool.fromEnvironment('dart.library.js_interop');
