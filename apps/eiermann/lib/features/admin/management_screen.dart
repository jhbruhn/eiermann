import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/audit/audit_screen.dart';
import 'package:eiermann/features/rhythm/rhythm_settings_screen.dart';
import 'package:eiermann/features/team/team_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/back_or_home.dart';
import 'package:eiermann/routing/router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The kinds of thing the hub sorts its sections into.
///
/// Not a WireEnum: nothing stores a group. It is a heading over the hub's rows,
/// and its whole existence is this file's reading order.
///
/// Two groups for three sections, which is not one group too few: what the org
/// IS and what it DECIDED are different questions, and a reader looking for
/// the log is not looking for a form. The heading says which kind a row is
/// before its label has to be read.
enum AdminSectionGroup {
  /// Who the group is, and the numbers it works to.
  organisation,

  /// What the system recorded about itself.
  oversight;

  String title(AppLocalizations l10n) => switch (this) {
    AdminSectionGroup.organisation => l10n.adminGroupOrganisation,
    AdminSectionGroup.oversight => l10n.adminGroupOversight,
  };

  /// The sections in this group, in declaration order.
  Iterable<AdminSection> get sections =>
      AdminSection.values.where((s) => s.group == this);
}

/// One section of the hub. Carries everything both the tile and the router
/// need, so the two cannot drift: the router declares one child route per
/// value rather than repeating the list.
///
/// Declared grouped, so [AdminSectionGroup.sections] is an in-order filter and
/// the hub's reading order is this file's.
///
/// Not a WireEnum: no row in the database names a section. What IS stable about
/// each value is its path segment, and that is a field on it — a rename of a
/// value here cannot silently change a URL somebody bookmarked.
enum AdminSection {
  team(
    AdminSectionGroup.organisation,
    Icons.groups_outlined,
    Routes.team,
    Routes.teamSegment,
  ),
  rhythm(
    AdminSectionGroup.organisation,
    Icons.timelapse_outlined,
    Routes.rhythmSettings,
    Routes.rhythmSegment,
  ),
  audit(
    AdminSectionGroup.oversight,
    Icons.history,
    Routes.audit,
    Routes.auditSegment,
  );

  const AdminSection(this.group, this.icon, this.route, this.segment);

  /// The group this section is listed under.
  final AdminSectionGroup group;

  final IconData icon;

  /// Absolute path, for navigating to this section.
  final String route;

  /// Last path component, for declaring it as a child of the hub route.
  final String segment;

  String title(AppLocalizations l10n) => switch (this) {
    AdminSection.team => l10n.teamTitle,
    AdminSection.rhythm => l10n.rhythmSettingsTitle,
    AdminSection.audit => l10n.auditTitle,
  };

  /// One line on what this section governs. The titles are short nouns —
  /// "Rhythmus", "Protokoll" — which say what a screen is called but not what
  /// changing something in it does to the rest of the app.
  String subtitle(AppLocalizations l10n) => switch (this) {
    AdminSection.team => l10n.adminTeamSubtitle,
    AdminSection.rhythm => l10n.adminRhythmSubtitle,
    AdminSection.audit => l10n.adminAuditSubtitle,
  };

  Widget screen() => switch (this) {
    AdminSection.team => const TeamScreen(),
    AdminSection.rhythm => const RhythmSettingsScreen(),
    AdminSection.audit => const AuditScreen(),
  };
}

/// The management hub: one home for the coordination's errands — the roster,
/// the intervals every due date comes out of, and the log.
///
/// It replaces a popup menu in the dashboard's app bar. The menu worked, and
/// it hid what the coordination actually governs behind three bare words: a
/// reader who had never opened "Rhythmus" had no way to learn from the menu
/// that it decides every due date in the app. A tile with a line under it says
/// so.
///
/// **Every section has a real URL**, and [section] comes from the route rather
/// than from internal state — so a section is linkable, survives a reload, and
/// the address bar tracks where the reader is. This is still not a go_router
/// two-pane: the hub renders the section itself, in the right pane on a wide
/// window and full-screen on a narrow one, so `/admin` stays one ordinary
/// route whose way back to the app never disappears. Declaring the sections as
/// CHILDREN of `/admin` is what puts the hub beneath a directly-opened section
/// URL, and so gives it a working back button.
///
/// Coordination-only, re-checked here so a hand-typed URL degrades into a
/// plain refusal rather than a screen of dead controls. The real boundary is
/// the server's: `audit_entries.listRule`, the rhythm route's own check, and
/// `users.updateRule`.
class ManagementScreen extends ConsumerWidget {
  const ManagementScreen({this.section, super.key});

  /// The section to show, or null for the bare hub.
  final AdminSection? section;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final role = ref.watch(currentUserProvider).value?.role;

    if (!(role?.canAdminister ?? false)) {
      return BackOrHomeScope(
        child: Scaffold(
          appBar: AppBar(
            leading: const BackOrHomeButton(),
            title: Text(l10n.adminTitle),
          ),
          body: EmptyView(
            icon: Icons.lock_outline,
            message: l10n.errorUnauthorized,
          ),
        ),
      );
    }

    final expanded = context.windowSizeClass.isExpanded;

    // Narrow: the section owns the whole screen. Its own app bar carries the
    // back arrow to the hub page below it in the stack.
    if (!expanded && section != null) return section!.screen();

    final hub = Scaffold(
      appBar: AppBar(
        // "Leave the administration", not "pop one page". The hub is on screen
        // either as the whole screen (narrow) or as the left pane beside a
        // section (wide), so this arrow always means leaving it — on a wide
        // window that deliberately skips the deselected in-between state a
        // plain pop would land on, where nothing appears to have happened. A
        // cold open has nothing beneath it to pop at all, which is the other
        // half of the same fix.
        leading: BackButton(onPressed: () => context.go(Routes.dashboard)),
        title: Text(l10n.adminTitle),
      ),
      body: ListView(
        children: [
          for (final group in AdminSectionGroup.values) ...[
            _GroupHeader(title: group.title(l10n)),
            for (final s in group.sections)
              ListTile(
                leading: Icon(s.icon),
                title: Text(s.title(l10n)),
                subtitle: Text(s.subtitle(l10n)),
                trailing: const Icon(Icons.chevron_right),
                // Only the wide layout keeps a selection to highlight.
                selected: expanded && s == section,
                // `go`, never `push`: go_router does not update the address
                // bar for an imperative push, so a pushed section left the URL
                // naming the hub. Because the sections are children of
                // `/admin`, `go` also puts the hub page beneath the section
                // for free — that is what makes the narrow back arrow work —
                // and moving from one section to a sibling swaps the child
                // rather than stacking a third page.
                onTap: () => context.go(s.route),
              ),
          ],
        ],
      ),
    );

    if (!expanded) return BackOrHomeScope(child: hub);

    // Wide: hub on the left, the selected section (its own Scaffold) or the
    // empty-selection placeholder on the right.
    return BackOrHomeScope(
      child: ListDetailScaffold(
        list: hub,
        detail:
            section?.screen() ??
            DetailPanePlaceholder(
              icon: Icons.manage_accounts_outlined,
              message: l10n.adminSelectSection,
            ),
      ),
    );
  }
}

/// Heading over one group of hub rows.
class _GroupHeader extends StatelessWidget {
  const _GroupHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(
        left: ZugvogelSpacing.md,
        right: ZugvogelSpacing.md,
        top: ZugvogelSpacing.lg,
        bottom: ZugvogelSpacing.sm,
      ),
      child: Text(
        title,
        style: theme.textTheme.titleSmall?.copyWith(
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}
