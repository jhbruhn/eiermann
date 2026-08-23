import 'package:eiermann/features/home/account_menu.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The app's top-level navigation: a [NavigationBar] along the bottom on a
/// phone, a [NavigationRail] beside the content from [WindowSizeClass.medium]
/// up (extended once the window is expanded).
///
/// Each destination is a [StatefulShellBranch], which is what makes a tab
/// switch cheap: every branch keeps its own navigator and its own widget tree,
/// so the list keeps its scroll offset and — the reason this matters here — the
/// map keeps its camera. `SpotsMapScreen` applies `initialCameraFit` once per
/// `State`, so a shell that rebuilt the branch on every switch would yank a
/// reader who had panned to one district back out to the whole city.
///
/// **Why the Spot dossier is not in here.** It is a top-level route over the
/// shell, so no branch can ever be parked on a detail page. That removes the
/// trap federfall's own shell has a paragraph about: a cross-branch jump leaves
/// a branch sitting on a detail, and re-tapping that tab then restores the
/// stale detail full-screen with no bar to escape by. Nothing to hide, nothing
/// to reset. The price is that a wide window loses the rail while a dossier is
/// open, which is what a two-pane layout would fix (eiermann-uvr).
class NavShell extends StatelessWidget {
  const NavShell({required this.navigationShell, super.key});

  /// The branch navigator state provided by `StatefulShellRoute`.
  final StatefulNavigationShell navigationShell;

  void _go(int index) {
    navigationShell.goBranch(
      index,
      // Re-tapping the active tab returns it to its root. That is what drops
      // the urgency filter a dashboard tile applied: the filter lives in the
      // location (`/spots?urgency=0`), so returning the branch to `/spots` is
      // the same gesture as clearing it.
      initialLocation: index == navigationShell.currentIndex,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final destinations = [
      (
        icon: Icons.dashboard_outlined,
        selectedIcon: Icons.dashboard,
        label: l10n.navDashboard,
      ),
      (
        icon: Icons.map_outlined,
        selectedIcon: Icons.map,
        label: l10n.navMap,
      ),
      (
        icon: Icons.list_alt_outlined,
        selectedIcon: Icons.list_alt,
        label: l10n.navSpots,
      ),
      // Fourth destination, and the reason it is a destination at all: a round
      // is where the day STARTS. The Erkundung funnel stayed a dashboard tile
      // because it is a periodic review; this is the screen somebody opens in
      // the car. Four is still inside Material's 3–5 for a NavigationBar.
      (
        icon: Icons.route_outlined,
        selectedIcon: Icons.route,
        label: l10n.navTours,
      ),
    ];
    final sizeClass = context.windowSizeClass;

    if (sizeClass != WindowSizeClass.compact) {
      final extended = sizeClass.isExpanded;
      return Scaffold(
        body: Row(
          children: [
            NavigationRail(
              extended: extended,
              selectedIndex: navigationShell.currentIndex,
              onDestinationSelected: _go,
              labelType: extended
                  ? NavigationRailLabelType.none
                  : NavigationRailLabelType.all,
              // The account entries — profile, the figures, the administration
              // — live HERE whenever the rail is showing, rather than in each
              // screen's app bar: the rail has the room to list them outright,
              // and [AccountMenu] self-hides so the same three destinations are
              // never offered twice. Bottom-aligned, as Material recommends for
              // a rail's trailing widget.
              trailing: Expanded(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: ZugvogelSpacing.md),
                    child: AccountRailActions(extended: extended),
                  ),
                ),
              ),
              destinations: [
                for (final d in destinations)
                  NavigationRailDestination(
                    icon: Icon(d.icon),
                    selectedIcon: Icon(d.selectedIcon),
                    label: Text(d.label),
                  ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: navigationShell),
          ],
        ),
      );
    }

    return Scaffold(
      body: navigationShell,
      bottomNavigationBar: NavigationBar(
        selectedIndex: navigationShell.currentIndex,
        onDestinationSelected: _go,
        destinations: [
          for (final d in destinations)
            NavigationDestination(
              icon: Icon(d.icon),
              selectedIcon: Icon(d.selectedIcon),
              label: d.label,
            ),
        ],
      ),
    );
  }
}
