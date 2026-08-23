import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The one account button in the app bar of every shell destination.
///
/// It replaces what used to be a row of bare icons — the figures, the
/// administration menu, sign out — repeated across four tabs. Three permanent
/// icons gave a monthly errand the same weight as the work itself, and the row
/// differed from tab to tab, so the chrome changed under the reader as they
/// switched.
///
/// **App-bar placement is compact-only.** From [WindowSizeClass.medium] up the
/// nav shell shows a rail, and the rail lists the same entries directly in its
/// trailing area ([AccountRailActions]) — it has the room, so nothing has to
/// be behind a popup. Keeping the button in the app bar as well would show the
/// same destinations twice, so this self-hides once the rail appears.
class AccountMenu extends StatelessWidget {
  const AccountMenu({super.key});

  @override
  Widget build(BuildContext context) {
    if (context.windowSizeClass != WindowSizeClass.compact) {
      return const SizedBox.shrink();
    }
    return const AccountMenuButton();
  }
}

/// The account popup itself: the profile (everybody), the figures (everybody)
/// and the management hub (the coordination).
///
/// The role gate mirrors the server's access rules so nobody is offered an
/// errand that comes back 403 — it is not the security boundary, which stays
/// in the collection rules and the hooks. The hub in particular is
/// coordination-only because a member who opened it would find every control
/// greyed out, and a screen of dead controls reads as a broken app rather than
/// as a permission.
class AccountMenuButton extends ConsumerWidget {
  const AccountMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final role = ref.watch(currentUserProvider).value?.role;

    return PopupMenuButton<void>(
      icon: const Icon(Icons.account_circle_outlined),
      tooltip: l10n.accountTooltip,
      itemBuilder: (_) => buildMenuItems([
        for (final entry in accountEntries(l10n, role))
          MenuAction(
            icon: entry.icon,
            label: entry.label,
            // `go`, not `push`: go_router never updates the address bar for an
            // imperative push, so a pushed account screen left the URL naming
            // the tab underneath it. These are real, linkable locations.
            onTap: () => context.go(entry.route),
          ),
      ]),
    );
  }
}

/// One destination of the account surface.
typedef AccountEntry = ({String route, IconData icon, String label});

/// What the account surface offers a reader in [role], in reading order.
///
/// One list read by both the popup and the rail, so the two cannot come to
/// differ — the whole point of collapsing the app-bar icons was that the
/// chrome stops depending on where you are.
List<AccountEntry> accountEntries(AppLocalizations l10n, UserRole? role) => [
  (
    route: Routes.profile,
    icon: Icons.account_circle_outlined,
    label: l10n.profileTitle,
  ),
  // Readable by everybody, like the roster and the rhythm: the figures are
  // what the group's own work came to, and a number a member is not allowed to
  // see is a number they cannot argue with.
  (
    route: Routes.statistics,
    icon: Icons.insights_outlined,
    label: l10n.statsTitle,
  ),
  if (role?.canAdminister ?? false)
    (
      route: Routes.admin,
      icon: Icons.manage_accounts_outlined,
      label: l10n.adminTitle,
    ),
];

/// The same entries, listed directly in the navigation rail's trailing area on
/// anything wider than a phone.
///
/// Always visible rather than behind a popup, because the rail has the room.
/// Adapts to the rail's [extended] state: icon-and-label rows when extended,
/// tooltipped icon buttons when collapsed.
class AccountRailActions extends ConsumerWidget {
  const AccountRailActions({required this.extended, super.key});

  /// Whether the host rail shows labels beside its icons.
  final bool extended;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final role = ref.watch(currentUserProvider).value?.role;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in accountEntries(l10n, role))
          _RailAction(
            icon: entry.icon,
            label: entry.label,
            extended: extended,
            // `go` for the same reason as the popup above.
            onTap: () => context.go(entry.route),
          ),
      ],
    );
  }
}

/// One [AccountRailActions] entry, at the rail's current density.
class _RailAction extends StatelessWidget {
  const _RailAction({
    required this.icon,
    required this.label,
    required this.extended,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool extended;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    if (!extended) {
      return IconButton(icon: Icon(icon), tooltip: label, onPressed: onTap);
    }
    // The rail measures its trailing widget with an UNBOUNDED width, to derive
    // its own intrinsic width from it. So this row has to shrink-wrap: a flex
    // child here fails the layout rather than looking wrong.
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: ZugvogelSpacing.md,
          vertical: ZugvogelSpacing.sm,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon),
            const SizedBox(width: ZugvogelSpacing.md),
            Text(label),
          ],
        ),
      ),
    );
  }
}
