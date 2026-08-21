import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Signing out, as an app-bar action.
///
/// One widget rather than the same `IconButton` in three app bars: every
/// destination of the nav shell needs it, because a reader who wants out should
/// not have to find the one tab that offers it. The router's gate does the
/// navigating — clearing the session notifies it and the redirect lands on the
/// login screen — so there is nothing to pop here.
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
