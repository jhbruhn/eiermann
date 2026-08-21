import 'package:eiermann/features/spots/spot_contact_sheet.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
/// The areas, the nests and the visit history land under this in Phase 03/04.
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
              _AccessCard(loaded),
              const SizedBox(height: ZugvogelSpacing.lg),
              _Contacts(spotId: spotId),
              if (loaded.note case final note?) ...[
                const SizedBox(height: ZugvogelSpacing.lg),
                _Section(
                  icon: Icons.notes_outlined,
                  title: l10n.spotNoteTitle,
                  child: Text(note),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.spot);

  final Spot spot;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

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
    ];

    return DetailHeader(
      title: spot.name,
      subtitle: spot.addressLine,
      chipLabel: spotPhaseLabel(l10n, spot.phase),
      chipAlert: spot.phase == SpotPhase.closed,
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
          ],
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
    final subtitle = [
      contactRoleLabel(l10n, contact.role),
      ?contact.phone,
      ?contact.email,
      ?contact.note,
    ].join(' · ');

    return ListTile(
      contentPadding: EdgeInsets.zero,
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
      subtitle: Text(subtitle, style: theme.textTheme.bodySmall),
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
