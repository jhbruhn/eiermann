import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Signing out, as an app-bar action — for the screens with no app behind them.
///
/// It used to sit in every shell destination's app bar. Inside the app, leaving
/// is now the last row of the profile screen, reached from the account menu:
/// three permanent icons gave a once-a-day act the same weight as the work.
/// What is left is the GATE screens — the waiting room in particular, where
/// every collection refuses the reader, so there is no profile to reach and
/// signing out is the only thing there is to do.
///
/// The router's gate does the navigating — clearing the session notifies it and
/// the redirect lands on the login screen — so there is nothing to pop here.
class SignOutAction extends ConsumerWidget {
  const SignOutAction({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return IconButton(
      icon: const Icon(Icons.logout),
      tooltip: l10n.authSignOutAction,
      onPressed: () async {
        final repo = await ref.read(authRepositoryProvider.future);
        repo.signOut();
      },
    );
  }
}
