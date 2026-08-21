import 'package:eiermann/features/areas/areas_section.dart';
import 'package:eiermann/features/history/spot_history_section.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/features/rhythm/due_explanation.dart';
import 'package:eiermann/features/spots/spot_access_sheet.dart';
import 'package:eiermann/features/spots/spot_contact_sheet.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_phase_chip.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/features/visits/packing_card.dart';
import 'package:eiermann/features/visits/visits_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Spot dossier — the screen the work actually happens on.
///
/// The order on the page is the whole design: who and where, then HOW YOU GET
/// IN, then who to ring. The access note comes before the contacts and before
/// the free-form note because it is the single most valuable field for a
/// handover, and the concept is explicit that it is the answer to "die Übergabe
/// ist schmerzhaft" — not a participant list, but what the next person needs to
/// get in at all.
///
/// The two buttons at the bottom are equal rank on purpose — "nicht geprüft" is
/// a fact about the building, not a failure to use the app — and both lead to
/// the one screen that writes a visit.
class SpotDetailScreen extends ConsumerWidget {
  const SpotDetailScreen({required this.spotId, super.key});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final spot = ref.watch(spotProvider(spotId));

    return Scaffold(
      appBar: AppBar(
        title: Text(spot.value?.name ?? l10n.spotsTitle),
        actions: [
          if (spot.value case final loaded?)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.spotDetailEditAction,
              onPressed: () => showSpotSheet(context, spot: loaded),
            ),
        ],
      ),
      body: AsyncValueView(
        value: spot,
        onRetry: () => ref.invalidate(spotProvider(spotId)),
        data: (loaded) => ContentBounds(
          child: ListView(
            padding: const EdgeInsets.all(ZugvogelSpacing.lg),
            children: [
              _Header(loaded),
              const SizedBox(height: ZugvogelSpacing.lg),
              // Above the access note, because it is what somebody acts on
              // FIRST: the two things you do at a building are get in and swap
              // eggs, and the number of Attrappen has to be known before
              // leaving the car.
              _PackingCard(spotId: spotId),
              const SizedBox(height: ZugvogelSpacing.lg),
              _AccessCard(loaded),
              const SizedBox(height: ZugvogelSpacing.lg),
              // Above the contacts, because the concept puts it there: the
              // overview photo is one of the two things that must stand on this
              // screen without scrolling, so you orient yourself physically
              // before reading anything.
              AreasSection(spotId: spotId),
              const SizedBox(height: ZugvogelSpacing.lg),
              if (loaded.phase case SpotPhase.active || SpotPhase.paused) ...[
                _VisitActions(spotId: spotId),
                const SizedBox(height: ZugvogelSpacing.lg),
              ],
              _Contacts(spotId: spotId),
              if (loaded.note case final note?) ...[
                const SizedBox(height: ZugvogelSpacing.lg),
                _Section(
                  icon: Icons.notes_outlined,
                  title: l10n.spotNoteTitle,
                  child: Text(note),
                ),
              ],
              const SizedBox(height: ZugvogelSpacing.lg),
              // LAST on the page, and that is the ordering the dossier is
              // built on: everything above is something somebody acts on
              // before going in, and the history is what you read afterwards.
              // Being last also means the dossier's own scroll drives its
              // paging — the tail only builds once somebody has reached it, so
              // opening a Spot costs one page and not the whole history.
              SpotHistorySection(spotId: spotId),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends ConsumerWidget {
  const _Header(this.spot);

  final Spot spot;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);
    // Both reads are already on this screen for other blocks, so the sentence
    // costs no extra request. It is built HERE and not by the server: the
    // server does not know which language the reader speaks.
    final followUps = ref.watch(openFollowUpsForSpotProvider(spot.id)).value;
    final nests = ref.watch(nestStatesForSpotProvider(spot.id)).value;
    final why = spotDueExplanation(
      l10n,
      spot,
      followUps: followUps ?? const [],
      nests: nests ?? const [],
      // An id with no label next to it is a bug in this app, so the
      // follow-up's nest is resolved through the list that is already loaded.
      nestLabelOf: (id) => {
        for (final nest in nests ?? const <NestState>[]) nest.id: nest.label,
      }[id],
    );

    // The lines under the phase chip are the ones that answer "why is this
    // Spot in this state" — a pause without its end date and a closing without
    // its reason are exactly the states nobody can act on later.
    final footnotes = [
      if (spot.prospectStage case final stage?) prospectStageLabel(l10n, stage),
      if (spot.pausedUntil case final until?)
        l10n.spotPausedUntil(formatLocalDate(materialL10n, until)),
      ?spot.pauseReason,
      if (spot.closedReason case final reason?) closedReasonLabel(l10n, reason),
      if (spot.closedAt case final at?)
        l10n.spotClosedOn(formatLocalDate(materialL10n, at)),
      // Whether a person confirmed the pin, not whether one exists: a guessed
      // pin on the wrong side of a courtyard sends somebody to the wrong door,
      // and the difference has to be visible.
      if (spot.geo == null)
        l10n.spotPinMissing
      else if (!spot.geoConfirmed)
        l10n.spotPinUnconfirmed,
      if (spot.nextDueAt case final due?)
        l10n.spotDueOn(formatLocalDate(materialL10n, due)),
      // Right after the date, which is the point of it: a date without its
      // reason is a date people override.
      ?why,
    ];

    return DetailHeader(
      title: spot.name,
      subtitle: spot.addressLine,
      // The phase rides in `trailing` rather than in `chipLabel`, because here
      // it is not a badge: it is the control that changes the phase, and the
      // built-in chip is text. Top-end, beside the name — the phase is the
      // second thing anybody wants off this screen, after which building it is.
      trailing: SpotPhaseChip(spot),
      footer: footnotes.isEmpty
          ? null
          : Text(
              footnotes.join(' · '),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
    );
  }
}

/// The access note, given a card of its own.
///
/// It is prominent even when EMPTY, which is the unusual part and the point: a
/// Spot with no access note is a handover that will cost somebody a phone call,
/// and hiding the gap is how it stays a gap.
class _AccessCard extends StatelessWidget {
  const _AccessCard(this.spot);

  final Spot spot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final note = spot.accessNote;

    return Card(
      color: note == null
          ? theme.colorScheme.surfaceContainerHighest
          : theme.colorScheme.primaryContainer,
      // The card is the editor's front door, empty or not. Somebody who has
      // just been told which bell to ring is standing at it on a phone: through
      // the Spot form that is four taps and a scroll past the address, and the
      // note does not get written. From here it is one tap on the thing that
      // was showing them the gap.
      child: InkWell(
        onTap: () => showSpotAccessSheet(context, spot: spot),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(ZugvogelSpacing.md),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.key_outlined,
                color: note == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onPrimaryContainer,
              ),
              const SizedBox(width: ZugvogelSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.spotAccessTitle,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: note == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(height: ZugvogelSpacing.xs),
                    Text(
                      note ?? l10n.spotAccessEmpty,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        color: note == null
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.edit_outlined,
                size: 18,
                color: note == null
                    ? theme.colorScheme.onSurfaceVariant
                    : theme.colorScheme.onPrimaryContainer,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Contacts extends ConsumerWidget {
  const _Contacts({required this.spotId});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final contacts = ref.watch(spotContactsProvider(spotId));

    return _Section(
      icon: Icons.contacts_outlined,
      title: l10n.spotContactsTitle,
      action: TextButton.icon(
        onPressed: () => showSpotContactSheet(context, spotId: spotId),
        icon: const Icon(Icons.person_add_alt),
        label: Text(l10n.spotContactsAddAction),
      ),
      child: AsyncValueView(
        value: contacts,
        onRetry: () => ref.invalidate(spotContactsProvider(spotId)),
        data: (rows) => rows.isEmpty
            ? Text(l10n.spotContactsEmpty)
            : Column(
                children: [
                  for (final contact in rows)
                    _ContactTile(contact: contact, spotId: spotId),
                ],
              ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.spotId});

  final SpotContact contact;
  final String spotId;

  /// Hands [uri] to the platform, telling the user when nothing can open it.
  ///
  /// A `tel:` link has no handler on a desktop browser or a tablet without a
  /// dialler, and `launchUrl` reports that by returning false rather than
  /// throwing. A tap that silently did nothing would read as a broken app.
  static Future<void> _launch(BuildContext context, Uri uri) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    var launched = false;
    try {
      launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'launch $uri');
    }
    if (!launched) {
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.spotContactLaunchFailed)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // The note is on its OWN line, not joined onto the end of this one. A
    // ListTile subtitle is a single line, so "nur vormittags erreichbar,
    // klingelt nicht bei Regen" was being ellipsised away — and that sentence
    // is the handover, not decoration around it.
    final reach = [
      contactRoleLabel(l10n, contact.role),
      ?contact.phone,
      ?contact.email,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
      isThreeLine: contact.note != null,
      title: Row(
        children: [
          Flexible(child: Text(contact.name)),
          if (contact.isPrimary) ...[
            const SizedBox(width: ZugvogelSpacing.sm),
            // Spelled out rather than shown as a star: "call first" is a fact
            // somebody needs to read, not decoration.
            TagChip(label: l10n.spotContactPrimary),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(reach, style: theme.textTheme.bodySmall),
          if (contact.note case final note?)
            Text(
              note,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            ),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (contact.phone case final phone?)
            IconButton(
              icon: const Icon(Icons.call_outlined),
              tooltip: l10n.spotContactCallAction,
              onPressed: () =>
                  _launch(context, Uri(scheme: 'tel', path: phone)),
            ),
          if (contact.email case final email?)
            IconButton(
              icon: const Icon(Icons.mail_outline),
              tooltip: l10n.spotContactMailAction,
              onPressed: () =>
                  _launch(context, Uri(scheme: 'mailto', path: email)),
            ),
        ],
      ),
      onTap: () =>
          showSpotContactSheet(context, spotId: spotId, contact: contact),
    );
  }
}

/// An icon, a heading, an optional action, and the section's content — the
/// shape every block on this screen repeats.
class _Section extends StatelessWidget {
  const _Section({
    required this.icon,
    required this.title,
    required this.child,
    this.action,
  });

  final IconData icon;
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconChip(icon),
            const SizedBox(width: ZugvogelSpacing.md),
            Expanded(child: Text(title, style: theme.textTheme.titleMedium)),
            ?action,
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        child,
      ],
    );
  }
}

/// The packing line on the dossier: the shared [PackingCard] over the read the
/// nest list already made.
///
/// While the read is still in flight there is no line at all — a "0 Attrappen"
/// that turns into 3 a moment later is worse than a beat of nothing.
class _PackingCard extends ConsumerWidget {
  const _PackingCard({required this.spotId});

  final String spotId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final nests = ref.watch(nestStatesForSpotProvider(spotId)).value;
    if (nests == null) return const SizedBox.shrink();
    return PackingCard(nests: nests);
  }
}

/// The two ways a visit ends, as two buttons of equal rank.
///
/// "Nicht geprüft" is not an error path: somebody stood in front of the
/// building and did not get in, and that is a fact about the building worth
/// recording. Giving it a lesser control would teach people to leave instead —
/// and a Spot nobody can explain is exactly what the WhatsApp history was full
/// of.
///
/// Both lead to the same screen, so there is one submit path, one retry path
/// and one idempotency key.
///
/// Offered on an ACTIVE or PAUSED Spot only. An Erkundung needs a conversation,
/// not a visit — the concept is explicit about that, and a visit funnel there
/// would be the wrong action made the most prominent one. A closed Spot is done
/// with; if it is not, the phase chip is the control that says so. A pause
/// KEEPS the buttons: it is deliberately temporary, and going past to see
/// whether the scaffolding is gone is exactly how a pause ends.
class _VisitActions extends StatelessWidget {
  const _VisitActions({required this.spotId});

  final String spotId;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Row(
      children: [
        Expanded(
          child: FilledButton.icon(
            onPressed: () => context.push(Routes.spotVisit(spotId)),
            icon: const Icon(Icons.play_arrow),
            label: Text(l10n.visitStartAction),
          ),
        ),
        const SizedBox(width: ZugvogelSpacing.md),
        Expanded(
          child: OutlinedButton.icon(
            onPressed: () =>
                context.push(Routes.spotVisit(spotId, skipped: true)),
            icon: const Icon(Icons.block_outlined),
            label: Text(l10n.visitSkipAction),
          ),
        ),
      ],
    );
  }
}
