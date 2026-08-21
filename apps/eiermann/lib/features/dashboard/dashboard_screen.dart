import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_list.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The first screen after signing in.
///
/// The Spot list IS the body: the map is the other way in, but a list of
/// buildings with the most urgent on top is what somebody opens the app for.
/// The dashboard blocks the concept asks for — open Halbgelege at the very top,
/// then overdue, then due today — arrive once there are nests to be due
/// (Phase 04); until then the urgency-ordered list is the whole answer.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;

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
      body: const SpotsList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSpotSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.spotsEmptyAction),
      ),
    );
  }
}
