import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/auth/oauth_launcher.dart';
import 'package:eiermann/features/auth/oauth_popup.dart';
import 'package:eiermann/features/auth/oauth_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
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
///
/// **The two ways in are not symmetrical.** Email and password is the default
/// and needs no configuration; an identity provider is a button per configured
/// provider, and appears only because the server said it exists. An instance
/// can also turn the password off entirely, and then the form and its button
/// are both gone — a sign-in control that cannot sign anybody in is worse than
/// no control, because the reader tries it first.
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

  // The provider flow happens in a browser this app does not own, so it has an
  // ending this app never hears about: the window simply gets closed. While one
  // is pending the screen therefore offers a way out, and taking it bumps
  // [_oauthAttempt] — which orphans the pending wait rather than cancelling it,
  // because there is nothing to cancel. A flow that completes afterwards still
  // signs in; the auth store changes and the router's gate moves.
  bool _oauthPending = false;
  int _oauthAttempt = 0;

  // Web only: the window opened inside the tap (see [OAuthPopup]), held so it
  // can be closed again when the flow fails or is abandoned.
  OAuthPopup? _oauthPopup;

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

  Future<void> _signInWithProvider(OAuthProvider provider) async {
    final l10n = context.l10n;
    final attempt = ++_oauthAttempt;
    // Web: the window has to be opened HERE, inside the tap, or Safari refuses
    // it — the URL to point it at only exists two awaits later. Null off the
    // web, and also when the browser said no anyway, and then the flow falls
    // back to an ordinary launch below.
    final popup = kIsWebPlatform ? openBlankOAuthPopup() : null;
    _oauthPopup = popup;
    // Scopes the SERVER prescribes for this provider, empty unless it needs
    // more than PocketBase asks for on its own. Without them a generic OIDC
    // provider never sends the groups claim, and everybody arrives as a guest
    // however carefully the group mapping was configured.
    final scopes =
        ref.read(serverInfoProvider).value?.auth.oauth2Scopes[provider.name] ??
        const <String>[];
    setState(() {
      _busy = true;
      _oauthPending = true;
      _error = null;
    });
    try {
      final repo = await ref.read(authRepositoryProvider.future);
      final AppUser user;
      if (kIsWebPlatform) {
        // The browser tab keeps running, so the realtime channel survives and
        // the all-in-one flow needs no redirect handling on this side.
        user = await repo.signInWithOAuth2(
          provider.name,
          (url) async {
            if (popup != null) {
              popup.navigateTo(url);
            } else {
              await launchUrl(url, mode: LaunchMode.inAppBrowserView);
            }
          },
          scopes: scopes,
        );
      } else {
        // A phone backgrounds this app the moment the browser comes up, which
        // drops that channel and loses the redirect. The deep link does not
        // care.
        user = await repo.signInWithOAuth2Code(
          provider.name,
          redirectUrl: oauthRedirectUrl,
          authenticate: authenticateOAuth,
          scopes: scopes,
        );
      }
      // The same check the password path makes, and for the same reason: the
      // identity provider knows who somebody is, it does not know whether this
      // instance still lets them in. A departed member keeps their account —
      // deactivation is how their access ends — and their sign-in at the
      // provider goes on working, so without this they would land in the app
      // and meet a refusal on every read instead of a sentence.
      if (!user.isActive) {
        repo.signOut();
        if (!mounted || attempt != _oauthAttempt) return;
        setState(() {
          _busy = false;
          _oauthPending = false;
          _error = l10n.authErrorDeactivated;
        });
        return;
      }
      // Signed in. The router's gate reads the auth store and moves — to the
      // dashboard, or to the waiting screen for somebody the provisioning hook
      // put in `guest`.
    } on Object catch (error, stackTrace) {
      popup?.closeIfOpen();
      _oauthPopup = null;
      // A cancel that landed while this was in flight already unlocked the
      // screen and may have started another attempt; this one is stale.
      if (!mounted || attempt != _oauthAttempt) return;
      // Dismissing the browser is one of the ordinary endings, not a failure:
      // no message, no report, just the form back.
      final cancelled = error is PlatformException && error.code == 'CANCELED';
      // The hook's 403 for an account the instance does not admit
      // (EIERMANN_OIDC_ALLOWED_GROUPS). Its own message is English, for the
      // log; the sentence the reader gets is this app's.
      final refused =
          error is RepositoryException &&
          error.kind == RepositoryErrorKind.unauthorized;
      if (!cancelled) reportCaughtError(error, stackTrace);
      setState(() {
        _busy = false;
        _oauthPending = false;
        _error = switch ((cancelled, refused)) {
          (true, _) => null,
          (_, true) => l10n.authOauthRefused,
          _ => l10n.authOauthFailed,
        };
      });
    }
  }

  /// Unlocks a screen left waiting on a flow nobody is going to finish.
  ///
  /// It cannot cancel anything — the browser is not this app's to close on
  /// native, and the pending future may still complete. If it does, the sign-in
  /// happens: the auth store changes and the gate moves, which is the right
  /// outcome and does not involve this screen.
  void _cancelOAuth() {
    _oauthAttempt++;
    _oauthPopup?.closeIfOpen();
    _oauthPopup = null;
    setState(() {
      _busy = false;
      _oauthPending = false;
    });
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
                if (options.password) ...[
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
                ],
                // One button per provider the server has. The separator appears
                // only when there is something to separate them FROM; on an
                // instance with the password off these are the whole screen.
                if (options.oauth2.isNotEmpty) ...[
                  const SizedBox(height: ZugvogelSpacing.lg),
                  if (options.password) ...[
                    _OrSeparator(label: l10n.authOrSeparator),
                    const SizedBox(height: ZugvogelSpacing.sm),
                  ],
                  ..._providerButtons(),
                  if (_oauthPending) ...[
                    const SizedBox(height: ZugvogelSpacing.md),
                    Text(
                      l10n.authOauthWaiting,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    TextButton(
                      onPressed: _cancelOAuth,
                      child: Text(l10n.actionCancel),
                    ),
                  ],
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

  /// One sign-in button per configured provider.
  ///
  /// The list is fetched for its LABELS only, so while it resolves — or if it
  /// fails — nothing is drawn: `/info` has already said providers exist, and
  /// this is what turns their names into the operator's wording. A button
  /// labelled with a raw provider id would be a worse answer than a moment of
  /// nothing.
  List<Widget> _providerButtons() {
    final l10n = context.l10n;
    final providers = ref.watch(oauthProvidersProvider).value ?? const [];
    return [
      for (final p in providers) ...[
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _signInWithProvider(p),
          icon: const Icon(Icons.login),
          label: Text(l10n.authContinueWith(p.displayName)),
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
      ],
    ];
  }
}

/// A labelled rule between the password form and the provider buttons.
class _OrSeparator extends StatelessWidget {
  const _OrSeparator({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        const Expanded(child: Divider()),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: ZugvogelSpacing.sm),
          child: Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        const Expanded(child: Divider()),
      ],
    );
  }
}

/// `kIsWeb`, named so the import of `flutter/foundation` does not shadow
/// anything in this file.
const kIsWebPlatform = bool.fromEnvironment('dart.library.js_interop');
