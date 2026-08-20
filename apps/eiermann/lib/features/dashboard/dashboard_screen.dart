import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The first screen after signing in.
///
/// A placeholder with real plumbing: it reads the signed-in user through the
/// same provider every later screen will, so the auth path is exercised end to
/// end rather than mocked. The Spot map and the due list land on top of this.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final me = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.appTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: l10n.authSignOutAction,
            onPressed: () async {
              final repo = await ref.read(authRepositoryProvider.future);
              repo.signOut();
            },
          ),
        ],
      ),
      body: AsyncValueView(
        value: me,
        onRetry: () => ref.invalidate(currentUserProvider),
        data: (user) => ContentBounds(
          child: ListView(
            padding: const EdgeInsets.all(ZugvogelSpacing.lg),
            children: [
              DetailHeader(
                title: user?.name?.isNotEmpty ?? false
                    ? user!.name!
                    : user?.email ?? '',
                subtitle: user?.role?.wire,
                chipLabel: user != null && user.role?.canAdminister == true
                    ? 'Koordination'
                    : null,
              ),
              const SizedBox(height: ZugvogelSpacing.lg),
              const EmptyView(
                icon: Icons.egg_outlined,
                title: 'Noch keine Spots',
                message: 'Sobald ein Standort angelegt ist, steht er hier.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
