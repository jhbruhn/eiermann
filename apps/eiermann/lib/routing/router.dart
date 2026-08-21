import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/areas/area_editor_screen.dart';
import 'package:eiermann/features/auth/login_screen.dart';
import 'package:eiermann/features/auth/pending_screen.dart';
import 'package:eiermann/features/dashboard/dashboard_screen.dart';
import 'package:eiermann/features/findings/findings_screen.dart';
import 'package:eiermann/features/home/nav_shell.dart';
import 'package:eiermann/features/server_setup/setup_screen.dart';
import 'package:eiermann/features/spots/prospects_screen.dart';
import 'package:eiermann/features/spots/spot_detail_screen.dart';
import 'package:eiermann/features/spots/spots_map_screen.dart';
import 'package:eiermann/features/spots/spots_screen.dart';
import 'package:eiermann/features/startup/splash_screen.dart';
import 'package:eiermann/features/tours/tour_editor_screen.dart';
import 'package:eiermann/features/tours/tour_run_screen.dart';
import 'package:eiermann/features/tours/tours_screen.dart';
import 'package:eiermann/features/visits/visit_flow_screen.dart';
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

  /// Where an account that may not reach any data waits.
  ///
  /// A gate screen like the three above, and for the same reason: a guest can
  /// sign in — that is the whole point, they have to be able to be TOLD
  /// something — but every collection refuses them, so the app behind this
  /// would be a wall of empty lists and buttons that 403.
  static const pending = '/pending';
  static const dashboard = '/';
  static const map = '/map';
  static const spots = '/spots';

  /// The Erkundung funnel. Its own location, so the dashboard's Erkundung tile
  /// leads somewhere a web reader can keep — and so the pipeline is a place
  /// rather than a mode of the Spot list.
  static const prospects = '/prospects';

  /// Every Fund in the org, newest first — where the dashboard's Funde number
  /// leads.
  ///
  /// Its own location, like the Erkundung funnel and for the same reason: a
  /// number on the dashboard has to be a way IN, and a count that cannot be
  /// opened is a fact nobody can act on.
  static const findings = '/findings';

  /// The Touren screen: the templates, and the way into a round.
  ///
  /// A nav destination rather than a dashboard tile, unlike the Erkundung
  /// funnel. The funnel is a periodic review — "bei wem hängt es?" — while a
  /// tour is where a round STARTS, which is the first thing somebody does when
  /// they open the app in the car. A tile would put that behind a count.
  static const tours = '/tours';

  /// One template's ordered stop list.
  static const tourEditorPattern = '/tours/:id';

  /// One round in progress.
  ///
  /// Its own top-level location rather than a mode of the Touren screen: a
  /// round is the thing a phone sits on for two hours, and a URL that names it
  /// is what makes a state restore come back on the right one.
  static const tourRunPattern = '/runs/:id';
  static const spotDetailPattern = '/spots/:id';

  /// The Besuchsablauf for one building.
  ///
  /// Under the dossier's path rather than beside it: a visit is always a visit
  /// TO a building, and the URL says so — which is also what makes a state
  /// restore come back on the right one.
  static const spotVisitPattern = '/spots/:id/visit';
  static const areaEditorPattern = '/areas/:id';

  /// The query parameter that narrows the Spot list to one urgency rank.
  static const urgencyParam = 'urgency';

  /// The query parameter that opens the visit flow straight on "nicht geprüft".
  ///
  /// A parameter rather than a second route, because it is the same screen with
  /// the same single submit path — the dossier just offers both outcomes as
  /// equal-rank buttons, the way the concept draws them.
  static const skipParam = 'skip';

  /// The query parameter that says which round a visit belongs to.
  ///
  /// In the location for the same reason the skip flag is: the visit screen can
  /// be restored after Android reclaims the process, and a round handed down
  /// through a provider would be gone by then — leaving a visit that quietly
  /// records itself outside the round somebody is walking.
  static const runParam = 'run';

  /// The detail route for one Spot. A function, not a constant, so the pattern
  /// above stays the single spelling of it — a hand-built '/spots/$id' at a
  /// call site is how a rename leaves a dead link behind.
  static String spotDetail(String id) => '/spots/$id';

  /// The Besuchsablauf for one Spot. [skipped] opens the "nicht geprüft" sheet
  /// on arrival, which is where the dossier's second button leads.
  static String spotVisit(String id, {bool skipped = false, String? run}) {
    final query = [
      if (skipped) '$skipParam=1',
      if (run != null) '$runParam=$run',
    ].join('&');
    return '/spots/$id/visit${query.isEmpty ? '' : '?$query'}';
  }

  /// One template's stop list.
  static String tourEditor(String tourId) => '/tours/$tourId';

  /// One round in progress.
  static String tourRun(String runId) => '/runs/$runId';

  /// The pin editor for one Bereich.
  ///
  /// Keyed by the Bereich alone, not nested under its Spot: a Bereich knows
  /// which building it belongs to, and a URL that repeated it could be made to
  /// disagree with the record.
  static String areaEditor(String areaId) => '/areas/$areaId';

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
  static const toursBranch = 'branch-tours';
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
    GoRoute(
      path: Routes.pending,
      builder: (_, _) => const PendingScreen(),
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
        StatefulShellBranch(
          restorationScopeId: _RestoreIds.toursBranch,
          routes: [
            GoRoute(
              path: Routes.tours,
              builder: (_, _) => const ToursScreen(),
            ),
          ],
        ),
      ],
    ),
    // The Erkundung funnel: over the shell like the dossier, and for the same
    // reason — a branch that can be parked on it is a branch that comes back
    // showing it. It is not a fourth destination either: the pipeline is where
    // the dashboard's Erkundung tile leads, not a tab somebody switches to
    // between rounds.
    GoRoute(
      path: Routes.prospects,
      builder: (_, _) => const ProspectsScreen(),
    ),
    // The Funde list: over the shell for the same reason as the funnel — where
    // a dashboard number leads is a place, not a tab.
    GoRoute(
      path: Routes.findings,
      builder: (_, _) => const FindingsScreen(),
    ),
    // The template editor and the running round: over the shell, like the
    // dossier, so no branch can be parked on either. The run especially — a
    // branch sitting on a finished round would offer to continue it.
    GoRoute(
      path: Routes.tourEditorPattern,
      builder: (_, state) {
        final id = state.pathParameters['id'];
        return id == null || id.isEmpty
            ? const ToursScreen()
            : TourEditorScreen(tourId: id);
      },
    ),
    GoRoute(
      path: Routes.tourRunPattern,
      builder: (_, state) {
        final id = state.pathParameters['id'];
        return id == null || id.isEmpty
            ? const ToursScreen()
            : TourRunScreen(runId: id);
      },
    ),
    // The pin editor: over the shell, for the same reason as the dossier under
    // it — and full-screen because the photo is the working surface.
    GoRoute(
      path: Routes.areaEditorPattern,
      builder: (_, state) {
        final id = state.pathParameters['id'];
        return id == null || id.isEmpty
            ? const DashboardScreen()
            : AreaEditorScreen(areaId: id);
      },
    ),
    // The visit flow, over the dossier for the same reason the dossier is over
    // the shell: a branch that can be parked on a form somebody is filling in
    // comes back showing it. Its own location rather than a mode of the
    // dossier, so the browser back button leaves the visit instead of leaving
    // the building.
    GoRoute(
      path: Routes.spotVisitPattern,
      builder: (_, state) {
        final id = state.pathParameters['id'];
        return id == null || id.isEmpty
            ? const DashboardScreen()
            : VisitFlowScreen(
                spotId: id,
                startSkipped:
                    state.uri.queryParameters[Routes.skipParam] == '1',
                tourRun: state.uri.queryParameters[Routes.runParam],
              );
      },
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

/// Where the gate sends a reader, given everything it knows. Null means stay.
///
/// A pure function on purpose. The ORDER of these questions is the design — and
/// three of the four answers are the kind that only show up in a state nobody
/// reproduces by hand: a session still being read, a profile read that failed,
/// a role that changed while the app was open. Inside [_Gate] this was
/// reachable only by standing up a PocketBase client, a storage layer and a
/// session, which is why it had no tests at all.
@visibleForTesting
String? gateRedirect({
  required AsyncValue<bool> configured,
  required AsyncValue<bool> signedIn,
  required AsyncValue<AppUser?> me,
  required String here,
}) {
  // 1. Still reading the persisted server URL or the persisted session: hold,
  // do not guess. Guessing "not signed in" while the session is still being
  // read bounces a returning user to a login form they did not need.
  if (configured.isLoading || signedIn.isLoading) {
    return here == Routes.splash ? null : Routes.splash;
  }

  // 2. No server yet — on native, first run. Nothing else can work before it:
  // the client cannot even be built without a base URL.
  if (configured.value != true) {
    return here == Routes.setup ? null : Routes.setup;
  }

  // 3. Not signed in.
  if (signedIn.value != true) {
    return here == Routes.login ? null : Routes.login;
  }

  // 4. Signed in — but may this account reach anything? A guest is refused by
  // every access rule (migration 014), so the app behind the gate would be
  // empty lists and buttons that answer 403.
  if (me.isLoading) {
    return here == Routes.splash ? null : Routes.splash;
  }
  // An ERROR is not a wall. A member whose profile read failed — a dropped
  // connection on resume — must not be told they are waiting for access: that
  // reads as a decision somebody made about them, and it has no way out. Let
  // them into the app, where a failed read shows itself as one.
  final role = me.value?.role;
  if (me.hasValue && !role.opensData) {
    return here == Routes.pending ? null : Routes.pending;
  }

  // Signed in and let in: leave the gate screens — including the waiting one,
  // which is how a promotion lands without a second sign-in.
  if (here == Routes.splash ||
      here == Routes.setup ||
      here == Routes.login ||
      here == Routes.pending) {
    return Routes.dashboard;
  }
  return null;
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
      // The ROLE decides whether there is an app to show, so a change to it has
      // to re-run the redirect: a coordinator promoting a guest must move that
      // reader off the waiting screen without asking them to sign in again.
      _ref.listen(currentUserProvider, (_, _) => notifyListeners()),
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
    return gateRedirect(
      // Mapped to a bool here so the decision below needs none of zugvogel's
      // types — which is what makes it testable without standing up a client.
      configured: config.whenData((value) => value is ServerConfigured),
      signedIn: _ref.read(authStatusProvider),
      me: _ref.read(currentUserProvider),
      here: state.matchedLocation,
    );
  }
}
