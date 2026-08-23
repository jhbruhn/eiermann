import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/home/account_menu.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import '../../support/harness.dart';

const _coordinator = AppUser(
  id: 'u1',
  email: 'rita@eiermann.test',
  name: 'Rita',
  role: UserRole.coordinator,
  org: 'org00000default',
);

const _member = AppUser(
  id: 'u2',
  email: 'feld@eiermann.test',
  name: 'Meike',
  role: UserRole.member,
  org: 'org00000default',
);

void main() {
  late AppLocalizations de;

  setUpAll(() async {
    de = await germanStrings();
  });

  /// Pumps [child] with a router only so `go` has somewhere to land. The routed
  /// screens are not the subject here — the entries are.
  ///
  /// The app bar hosts the popup button and the BODY hosts the rail actions:
  /// the rail lists three rows in a Column, and an app bar is one row tall, so
  /// putting them there would overflow the harness rather than the app.
  Future<GoRouter> pumpMenu(
    WidgetTester tester, {
    AppUser me = _coordinator,
    Size surface = const Size(500, 900),
    Widget child = const AccountMenu(),
    bool inAppBar = true,
  }) async {
    tester.useSurface(surface);
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (_, _) => Scaffold(
            appBar: AppBar(actions: [if (inAppBar) child]),
            body: inAppBar ? null : Align(child: child),
          ),
        ),
        for (final path in [Routes.profile, Routes.statistics, Routes.admin])
          GoRoute(
            path: path,
            builder: (_, _) => Scaffold(body: Text(path)),
          ),
      ],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [currentUserProvider.overrideWith((ref) async => me)],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('de'),
          routerConfig: router,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return router;
  }

  testWidgets('the coordination is offered the administration too', (
    tester,
  ) async {
    await pumpMenu(tester);
    await tester.tap(find.byType(AccountMenuButton));
    await tester.pumpAndSettle();

    expect(find.text(de.profileTitle), findsOneWidget);
    expect(find.text(de.statsTitle), findsOneWidget);
    expect(find.text(de.adminTitle), findsOneWidget);
  });

  testWidgets('a member sees the profile and the figures, not the hub', (
    tester,
  ) async {
    // The gate mirrors the server's rules rather than replacing them: a member
    // who opened the hub would find every control in it refused, and a screen
    // of dead controls reads as a broken app.
    await pumpMenu(tester, me: _member);
    await tester.tap(find.byType(AccountMenuButton));
    await tester.pumpAndSettle();

    expect(find.text(de.profileTitle), findsOneWidget);
    expect(find.text(de.statsTitle), findsOneWidget);
    expect(find.text(de.adminTitle), findsNothing);
  });

  testWidgets('an entry goes to a real location, not a push', (tester) async {
    // `go`, not `push`: go_router does not update the address bar for an
    // imperative push, so a pushed account screen left the URL naming the tab
    // underneath it — invisible on a phone, wrong on the web.
    final router = await pumpMenu(tester);
    await tester.tap(find.byType(AccountMenuButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.profileTitle));
    await tester.pumpAndSettle();

    expect(
      router.routerDelegate.currentConfiguration.uri.path,
      Routes.profile,
    );
  });

  testWidgets('the app-bar button stands down once the rail can list them', (
    tester,
  ) async {
    // Anything wider than a phone gets the rail, and the rail lists the same
    // entries outright. Two offers of the same three destinations is the row of
    // duplicated icons this menu was collapsed out of.
    await pumpMenu(tester, surface: const Size(1000, 900));

    expect(find.byType(AccountMenuButton), findsNothing);
  });

  testWidgets('the extended rail entries carry their labels', (tester) async {
    await pumpMenu(
      tester,
      surface: const Size(1400, 900),
      child: const AccountRailActions(extended: true),
      inAppBar: false,
    );

    expect(find.text(de.profileTitle), findsOneWidget);
    expect(find.text(de.statsTitle), findsOneWidget);
    expect(find.text(de.adminTitle), findsOneWidget);
  });

  testWidgets('a collapsed rail entry keeps its label as a tooltip', (
    tester,
  ) async {
    // The label is the only thing that says what an icon is for. Dropping it
    // with the text would leave three unexplained glyphs at the bottom of the
    // rail.
    await pumpMenu(
      tester,
      surface: const Size(1000, 900),
      child: const AccountRailActions(extended: false),
      inAppBar: false,
    );

    expect(find.byTooltip(de.profileTitle), findsOneWidget);
    expect(find.byTooltip(de.statsTitle), findsOneWidget);
    expect(find.byTooltip(de.adminTitle), findsOneWidget);
  });
}
