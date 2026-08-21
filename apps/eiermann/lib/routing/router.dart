import 'package:eiermann/features/auth/login_screen.dart';
import 'package:eiermann/features/dashboard/dashboard_screen.dart';
import 'package:eiermann/features/home/nav_shell.dart';
import 'package:eiermann/features/server_setup/setup_screen.dart';
import 'package:eiermann/features/spots/spot_detail_screen.dart';
import 'package:eiermann/features/spots/spots_map_screen.dart';
import 'package:eiermann/features/spots/spots_screen.dart';
import 'package:eiermann/features/startup/splash_screen.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

part 'router.g.dart';

/// Route paths, so nothing spells one twice.
abstract final class Routes {
  static const splash = '/splash';
  static const setup = '/setup';
  static const login = '/login';
  static const dashboard = '/';
  static const map = '/map';
  static const spots = '/spots';
  static const spotDetailPattern = '/spots/:id';

  /// The query parameter that narrows the Spot list to one urgency rank.
  static const urgencyParam = 'urgency';

  /// The detail route for one Spot. A function, not a constant, so the pattern
  /// above stays the single spelling of it — a hand-built '/spots/$id' at a
  /// call site is how a rename leaves a dead link behind.
  static String spotDetail(String id) => '/spots/$id';

  /// The Spot list, narrowed to one urgency rank — where a dashboard tile
  /// leads.
  ///
  /// The filter travels in the LOCATION rather than in a provider handed from
  /// one branch to another. Three things follow from that and none of them
  /// needs code: a state restore comes back filtered, a web reader can keep the
  /// link, and tapping the tab again drops the filter because it returns the
  /// branch to its root.
  static String spotsByUrgency(SpotUrgency level) =>
      '$spots?$urgencyParam=${level.rank}';

  /// The rank in [location]'s query, or null for the unfiltered list.
  ///
  /// An unparseable or unknown rank reads as "no filter", never as rank 0: a
  /// hand-typed `?urgency=banana` must not show the reader the overdue Spots
  /// and call them everything.
  static SpotUrgency? urgencyOf(Uri location) => SpotUrgency.fromRank(
    int.tryParse(location.queryParameters[urgencyParam] ?? ''),
  );
}

/// State-restoration ids. Scoping the shell and each branch is what lets
/// go_router bring back the open tab after Android reclaims the process; the
/// ids have to be stable strings, so they live here rather than inline.
abstract final class _RestoreIds {
  static const shell = 'shell';
  static const dashboardBranch = 'branch-dashboard';
  static const mapBranch = 'branch-map';
  static const spotsBranch = 'branch-spots';
}

/// The app's router, with one redirect gate in front of everything.
///
/// The gate answers three questions in order, and the order is the whole
/// design:
///
/// 1. **Is a server configured?** On native, first run has no URL, so it goes
/// to setup. Nothing else can work before this — the PocketBase client cannot
/// even be built without a base URL. 2. **Are we signed in?** If not, the login
/// screen. 3. Otherwise the app.
///
/// Both gating questions are read as `AsyncValue`s and a *loading* one holds
/// the user on the splash screen rather than guessing. Guessing "not signed in"
/// while the persisted session is still being read is how an app bounces a
/// returning user to a login form they did not need — a full second of
/// pointless doubt on every cold start.
@Riverpod(keepAlive: true)
GoRouter router(Ref ref) {
  final gate = _Gate(ref);
  return GoRouter(
    restorationScopeId: 'router',
    initialLocation: Routes.dashboard,
    refreshListenable: gate,
    redirect: gate.redirect,
    routes: appRoutes(),
  );
}

/// The route table, without the gate in front of it.
///
/// Its own function so a test can pump the REAL tree — branch order, the shell,
/// the urgency parameter, the dossier sitting over all of it — without standing
/// up a server config and a session first. A test that had to rebuild the
/// routes by hand would only be a test of the copy.
List<RouteBase> appRoutes() {
  return [
    GoRoute(
      path: Routes.splash,
      builder: (_, _) => const SplashScreen(),
    ),
    GoRoute(
      path: Routes.setup,
      builder: (_, _) => const SetupScreen(),
    ),
    GoRoute(
      path: Routes.login,
      builder: (_, _) => const LoginScreen(),
    ),
    // The three destinations of the nav shell. One branch each: go_router
    // keeps a branch's navigator alive across a switch, which is what makes
    // the list keep its scroll offset and the map keep its camera.
    StatefulShellRoute.indexedStack(
      restorationScopeId: _RestoreIds.shell,
      builder: (_, _, navigationShell) =>
          NavShell(navigationShell: navigationShell),
      branches: [
        StatefulShellBranch(
          restorationScopeId: _RestoreIds.dashboardBranch,
          routes: [
            GoRoute(
              path: Routes.dashboard,
              builder: (_, _) => const DashboardScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          restorationScopeId: _RestoreIds.mapBranch,
          routes: [
            GoRoute(
              path: Routes.map,
              builder: (_, _) => const SpotsMapScreen(),
            ),
          ],
        ),
        StatefulShellBranch(
          restorationScopeId: _RestoreIds.spotsBranch,
          routes: [
            GoRoute(
              path: Routes.spots,
              builder: (_, state) =>
                  SpotsScreen(urgency: Routes.urgencyOf(state.uri)),
            ),
          ],
        ),
      ],
    ),
    // The dossier sits OVER the shell rather than inside a branch: a branch
    // that can be parked on a detail is the trap federfall's NavShell has a
    // paragraph about. See [NavShell].
    GoRoute(
      path: Routes.spotDetailPattern,
      // A missing id cannot happen through the pattern, but a hand-typed URL
      // on web can produce one — and falling back to the dashboard is a
      // better answer than a screen that queries for the empty string.
      builder: (_, state) {
        final id = state.pathParameters['id'];
        return id == null || id.isEmpty
            ? const DashboardScreen()
            : SpotDetailScreen(spotId: id);
      },
    ),
  ];
}

/// Turns the two gating providers into one [Listenable] go_router can refresh
/// on, and holds the redirect that reads them.
class _Gate extends ChangeNotifier {
  _Gate(this._ref) {
    // `listen` rather than `watch`: a change here must re-run the redirect, not
    // rebuild the router itself — rebuilding it would throw away the navigation
    // stack on every auth tick, including the token refresh that happens
    // whenever a web tab regains focus.
    _subs = [
      _ref.listen(serverConfigControllerProvider, (_, _) => notifyListeners()),
      _ref.listen(authStatusProvider, (_, _) => notifyListeners()),
    ];
  }

  final Ref _ref;
  late final List<ProviderSubscription<Object?>> _subs;

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.close();
    }
    super.dispose();
  }

  String? redirect(BuildContext context, GoRouterState state) {
    final config = _ref.read(serverConfigControllerProvider);
    final signedIn = _ref.read(authStatusProvider);
    final here = state.matchedLocation;

    // Still reading the persisted server URL or the persisted session: hold,
    // do not guess. See the class doc.
    if (config.isLoading || signedIn.isLoading) {
      return here == Routes.splash ? null : Routes.splash;
    }

    final configured = config.value is ServerConfigured;
    if (!configured) {
      return here == Routes.setup ? null : Routes.setup;
    }

    if (signedIn.value != true) {
      return here == Routes.login ? null : Routes.login;
    }

    // Signed in: nothing to do here any more, so leave the gate screens.
    if (here == Routes.splash || here == Routes.setup || here == Routes.login) {
      return Routes.dashboard;
    }
    return null;
  }
}
