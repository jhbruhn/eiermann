import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/home/sign_out_action.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Erkundung funnel: every building whose permission is still being asked
/// for, grouped by what it is waiting on.
///
/// The question this screen exists to answer is "bei wem hängt es?" — and the
/// Spot list cannot, because there the Erkundungen are scattered among the
/// buildings that are simply due. Grouped by stage, the shape of the pipeline
/// is the answer: four under "Unberührt" means nobody has asked yet, three
/// under "Eigentümer gesprochen" means three replies are outstanding.
///
/// **It reads `allSpots` and filters here.** No query of its own: the phase and
/// the stage are columns of the row the map and the dashboard already read, so
/// a separate request could only cost a round trip to return the same rows —
/// and the dashboard's Erkundung tile, which leads here, counts from that very
/// read. Two reads could show two different numbers on two screens describing
/// one pipeline.
class ProspectsScreen extends ConsumerWidget {
  const ProspectsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spots = ref.watch(allSpotsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.prospectsTitle),
        actions: const [SignOutAction()],
      ),
      body: AsyncValueView(
        value: spots,
        onRetry: () => ref.invalidate(allSpotsProvider),
        data: (rows) => _Funnel(rows: rows),
      ),
    );
  }
}

/// Which Spots are in the funnel, and in which group.
///
/// `phase == prospect`, not `urgency == prospect`: the two agree today (the
/// view's CASE ranks a prospect 4) but a PAUSED Erkundung ranks as paused, and
/// what belongs here is the phase itself. A rank is a display order; the phase
/// is the fact.
///
/// A row whose stage the wire could not name lands under [ProspectStage
/// .untouched]: an Erkundung with no recorded step is exactly one nobody has
/// taken yet, and a sixth group called "unbekannt" would be a group nobody can
/// act on.
Map<ProspectStage, List<SpotOverview>> prospectsByStage(
  List<SpotOverview> rows,
) {
  final groups = <ProspectStage, List<SpotOverview>>{};
  for (final row in rows) {
    if (row.phase != SpotPhase.prospect) continue;
    final stage = row.prospectStage ?? ProspectStage.untouched;
    groups.putIfAbsent(stage, () => []).add(row);
  }
  for (final group in groups.values) {
    // Stalest first, and that is the whole ranking: within one stage, the
    // building nobody has touched for six weeks is where it hangs. `updated` is
    // the record's last change and not the date of the conversation — which is
    // why the row says "zuletzt geändert" and not "seit dem Gespräch".
    group.sort((a, b) {
      final left = a.updated;
      final right = b.updated;
      if (left == null || right == null) return left == null ? -1 : 1;
      return left.compareTo(right);
    });
  }
  return groups;
}

class _Funnel extends ConsumerWidget {
  const _Funnel({required this.rows});

  final List<SpotOverview> rows;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final groups = prospectsByStage(rows);

    if (groups.isEmpty) {
      return EmptyView(
        icon: Icons.forum_outlined,
        title: l10n.prospectsEmptyTitle,
        message: l10n.prospectsEmptyMessage,
        actionLabel: l10n.spotsEmptyAction,
        actionIcon: Icons.add,
        onAction: () => showSpotSheet(context),
      );
    }

    return RefreshIndicator(
      onRefresh: () => ref.refresh(allSpotsProvider.future),
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          ContentBounds(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // In FUNNEL order, always — unberührt, Mieter, Eigentümer,
                // erlaubt, abgelehnt — so the pipeline reads in order even
                // though it is drawn top to bottom. An empty stage is left
                // out: a header with a zero under it costs a screenful on a
                // phone and says nothing a reader can act on.
                for (final stage in ProspectStage.values)
                  if (groups[stage] case final group?)
                    _Group(stage: stage, rows: group),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One stage: what it is, how many are in it, and what moves them on.
class _Group extends StatelessWidget {
  const _Group({required this.stage, required this.rows});

  final ProspectStage stage;
  final List<SpotOverview> rows;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.only(bottom: ZugvogelSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              IconChip(prospectStageIcon(stage)),
              const SizedBox(width: ZugvogelSpacing.md),
              Expanded(
                child: Text(
                  '${prospectStageLabel(l10n, stage)} · ${rows.length}',
                  style: theme.textTheme.titleMedium,
                ),
              ),
            ],
          ),
          const SizedBox(height: ZugvogelSpacing.xs),
          // The next action belongs to the STAGE, not to the row: it is the
          // same sentence for every building waiting on the same thing, and
          // repeated per row it would be five lines of the same instruction.
          Padding(
            padding: const EdgeInsets.only(left: ZugvogelSpacing.xl),
            child: Text(
              prospectStageNextAction(l10n, stage),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
          Card(
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0) const Divider(height: 1),
                  ProspectTile(row),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One building in the funnel: which it is, whether anybody can be rung about
/// it, how long it has sat there — and the one field this screen writes.
class ProspectTile extends ConsumerWidget {
  const ProspectTile(this.row, {super.key});

  final SpotOverview row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

    return ListTile(
      title: Text(row.name),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (row.addressLine case final address?) Text(address),
          // A Spot with nobody to ring is not waiting on a reply — it is
          // waiting on somebody to find out who to ask, which is a different
          // job and the reason it is called out rather than counted.
          if (row.contactCount == 0)
            Text(
              l10n.prospectsNoContact,
              style: theme.textTheme.bodySmall?.copyWith(
                color: context.zvColors.warning,
              ),
            )
          else
            Text(
              l10n.spotContactCount(row.contactCount),
              style: theme.textTheme.bodySmall,
            ),
          if (row.updated case final changed?)
            Text(
              l10n.prospectsLastChanged(
                formatLocalDate(materialL10n, changed),
              ),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      isThreeLine: true,
      // Recording the step is the point of standing in front of the building,
      // so it is one menu here rather than a trip through the dossier's edit
      // form. It writes ONE field (`SpotsRepository.stageBody`) — a form body
      // would clear the address somebody just typed.
      trailing: PopupMenuButton<ProspectStage>(
        tooltip: l10n.prospectsStageAction,
        icon: const Icon(Icons.more_vert),
        onSelected: (stage) => unawaited(_move(context, ref, stage)),
        itemBuilder: (context) => [
          // Every OTHER stage, in funnel order, and no invented graph: the
          // server has no ordering rule for stages, so a client that offered
          // only "the next one" would be a rule nothing enforces — and it
          // would have no way to record that the tenant turned out to be the
          // owner all along.
          for (final stage in ProspectStage.values)
            if (stage != (row.prospectStage ?? ProspectStage.untouched))
              PopupMenuItem(
                value: stage,
                child: Row(
                  children: [
                    Icon(prospectStageIcon(stage), size: 18),
                    const SizedBox(width: ZugvogelSpacing.sm),
                    // Expanded, not bare: a popup menu is 256px wide and
                    // "Eigentümer gesprochen" beside an icon overflows it by
                    // 66px — measured, as a red test.
                    Expanded(child: Text(prospectStageLabel(l10n, stage))),
                  ],
                ),
              ),
        ],
      ),
      onTap: () => unawaited(context.push(Routes.spotDetail(row.id))),
    );
  }

  /// Writes the new stage, then lets every Spot view re-read.
  ///
  /// No confirmation snackbar on success: the row leaves its group and appears
  /// under the new one, which is a better answer than a sentence over the top
  /// of it. A failure DOES get one, because nothing else on screen would
  /// change.
  Future<void> _move(
    BuildContext context,
    WidgetRef ref,
    ProspectStage stage,
  ) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(spotsRepositoryProvider.future);
      await repo.update(row.id, SpotsRepository.stageBody(stage));
    } on Object catch (error, stackTrace) {
      if (error is! RepositoryException) {
        reportCaughtError(
          error,
          stackTrace,
          context: 'move prospect stage ${row.id}',
        );
      }
      messenger.showSnackBar(
        SnackBar(content: Text(errorMessage(EiermannStrings(l10n), error))),
      );
      return;
    }
    invalidateSpotViews(ref);
  }
}
