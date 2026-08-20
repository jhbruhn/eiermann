import 'package:eiermann/config/app_environment.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// First run on native: which server does this app talk to.
///
/// The address is PROBED before it is stored. Persisting an unverified URL is
/// how somebody ends up staring at a login form that can never succeed, with
/// nothing on screen to say why — so the probe's outcome is turned into a
/// sentence that names the actual problem.
class SetupScreen extends ConsumerStatefulWidget {
  const SetupScreen({super.key});

  @override
  ConsumerState<SetupScreen> createState() => _SetupScreenState();
}

class _SetupScreenState extends ConsumerState<SetupScreen> {
  final _formKey = GlobalKey<FormState>();
  // Prefilled from the build-time override in development, where it points at
  // the local containerised backend. It only ever PREFILLS — it never
  // auto-configures, because that would skip this screen entirely and nobody
  // would find out the address was wrong until the first request.
  late final _controller = TextEditingController(
    text: AppEnvironment.pocketbaseUrlOverride,
  );
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final l10n = context.l10n;
    setState(() {
      _busy = true;
      _error = null;
    });

    final probe = ref.read(serverProbeProvider);
    final result = await probe.probe(_controller.text);
    if (!mounted) return;

    switch (result) {
      case ProbeReachable(:final baseUrl):
        // Only now does it get stored. The controller also purges any persisted
        // session, because a token belongs to the origin that issued it.
        await ref
            .read(serverConfigControllerProvider.notifier)
            .setServerUrl(baseUrl);
        // The router's gate takes it from here.
        return;
      case ProbeInvalidUrl():
        setState(() => _error = l10n.setupErrorInvalidUrl);
      case ProbeInsecureHttp():
        setState(() => _error = l10n.setupErrorInsecure);
      case ProbeUnreachable():
        setState(() => _error = l10n.setupErrorUnreachable);
      case ProbeWrongService():
        setState(() => _error = l10n.setupErrorWrongService);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(l10n.setupTitle)),
      body: ContentBounds(
        maxWidth: 480,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(ZugvogelSpacing.lg),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(l10n.setupExplanation, style: theme.textTheme.bodyLarge),
                const SizedBox(height: ZugvogelSpacing.lg),
                AppTextField(
                  label: l10n.setupUrlLabel,
                  hintText: l10n.setupUrlHint,
                  controller: _controller,
                  enabled: !_busy,
                  autofocus: true,
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.go,
                  onSubmitted: (_) => _connect(),
                  validator: Validators.required(EiermannStrings(l10n)),
                ),
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
                  label: l10n.setupConnectAction,
                  isLoading: _busy,
                  onPressed: _connect,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
