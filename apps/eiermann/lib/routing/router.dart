import 'package:eiermann/features/auth/login_screen.dart';
import 'package:eiermann/features/dashboard/dashboard_screen.dart';
import 'package:eiermann/features/server_setup/setup_screen.dart';
import 'package:eiermann/features/spots/spot_detail_screen.dart';
import 'package:eiermann/features/startup/splash_screen.dart';
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
  static const spotDetailPattern = '/spots/:id';

  /// The detail route for one Spot. A function, not a constant, so the pattern
  /// above stays the single spelling of it — a hand-built '/spots/$id' at a
  /// call site is how a rename leaves a dead link behind.
  static String spotDetail(String id) => '/spots/$id';
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
    routes: [
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
        path: Routes.dashboard,
        builder: (_, _) => const DashboardScreen(),
      ),
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
    ],
  );
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
