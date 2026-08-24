import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/admin/management_screen.dart';
import 'package:eiermann/features/audit/audit_screen.dart';
import 'package:eiermann/features/team/team_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:mocktail/mocktail.dart';

import '../../support/harness.dart';

class _MockAudit extends Mock implements AuditRepository {}

class _MockUsers extends Mock implements UsersRepository {}

class _MockRhythm extends Mock implements RhythmRepository {}

const _rhythm = RhythmSettings(
  baseIntervalDays: 7,
  emptyChecksPerStep: 3,
  intervalSteps: [7, 14, 28],
  halfClutchReturnDays: 4,
  pauseAutoResume: true,
);

const _coordinator = AppUser(
  id: 'u1',
  email: 'koordination@eiermann.test',
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
  late _MockAudit audit;
  late _MockUsers users;
  late _MockRhythm rhythm;

  setUpAll(() async {
    de = await germanStrings();
  });

  setUp(() {
    audit = _MockAudit();
    users = _MockUsers();
    rhythm = _MockRhythm();
    when(rhythm.fetch).thenAnswer((_) async => _rhythm);
    when(
      () => audit.pageOfLog(after: any(named: 'after')),
    ).thenAnswer((_) async => const PbPage<AuditEvent>(items: []));
    when(users.team).thenAnswer((_) async => [_coordinator, _member]);
  });

  /// Pumps the REAL route table at [at], so a test of the hub is also a test
  /// of the child routes underneath it — the whole reason the sections are
  /// children rather than top-level siblings is what happens on a back press,
  /// and a test that mounted [ManagementScreen] by hand could not see it.
  Future<void> pumpAt(
    WidgetTester tester,
    String at, {
    AppUser me = _coordinator,
    Size surface = const Size(500, 1400),
  }) async {
    tester.useSurface(surface);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserProvider.overrideWith((ref) async => me),
          auditRepositoryProvider.overrideWith((ref) async => audit),
          usersRepositoryProvider.overrideWith((ref) async => users),
          rhythmRepositoryProvider.overrideWith((ref) async => rhythm),
        ],
        child: MaterialApp.router(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('de'),
          routerConfig: GoRouter(routes: appRoutes(), initialLocation: at),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the hub lists every section under its group heading', (
    tester,
  ) async {
    await pumpAt(tester, Routes.admin);

    expect(find.text(de.adminGroupOrganisation), findsOneWidget);
    expect(find.text(de.adminGroupOversight), findsOneWidget);
    for (final section in AdminSection.values) {
      expect(
        find.text(section.title(de)),
        findsOneWidget,
        reason: '${section.name} has no tile',
      );
      // The line under the label is what says what the section GOVERNS. A tile
      // with only a noun on it ("Rhythmus") is the popup menu this replaced.
      expect(
        find.text(section.subtitle(de)),
        findsOneWidget,
        reason: '${section.name} has a title but no explanation',
      );
    }
  });

  testWidgets('a member gets a refusal instead of the hub', (tester) async {
    await pumpAt(tester, Routes.admin, me: _member);

    expect(find.text(de.errorUnauthorized), findsOneWidget);
    expect(find.text(de.teamTitle), findsNothing);
  });

  testWidgets('a member reaching a SECTION by URL is refused too', (
    tester,
  ) async {
    // The gate is on the hub, and the section is rendered BY the hub — so this
    // asserts the refusal covers a hand-typed child URL, not just `/admin`.
    await pumpAt(tester, Routes.audit, me: _member);

    expect(find.text(de.errorUnauthorized), findsOneWidget);
    expect(find.byType(AuditScreen), findsNothing);
  });

  testWidgets('a narrow window gives the section the whole screen', (
    tester,
  ) async {
    await pumpAt(tester, Routes.team);

    expect(find.byType(TeamScreen), findsOneWidget);
    // The hub is BENEATH it, not beside it: no tile is on screen.
    expect(find.text(de.adminGroupOrganisation), findsNothing);
  });

  testWidgets('a directly-opened section can go back to the hub', (
    tester,
  ) async {
    // The point of declaring the sections as children of `/admin`: a cold open
    // on `/admin/team` has the hub page beneath it, so the app bar's arrow
    // leads somewhere instead of not existing.
    await pumpAt(tester, Routes.team);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();

    expect(find.text(de.adminGroupOrganisation), findsOneWidget);
    expect(find.byType(TeamScreen), findsNothing);
  });

  testWidgets('a wide window shows the hub AND the section', (tester) async {
    await pumpAt(
      tester,
      Routes.audit,
      surface: const Size(1400, 1400),
    );

    expect(find.byType(AuditScreen), findsOneWidget);
    expect(find.text(de.adminGroupOversight), findsOneWidget);
  });

  testWidgets('a wide window with no section prompts for one', (tester) async {
    await pumpAt(
      tester,
      Routes.admin,
      surface: const Size(1400, 1400),
    );

    expect(find.text(de.adminSelectSection), findsOneWidget);
  });

  testWidgets('every section is reachable from the hub', (tester) async {
    // One tap per tile rather than one test per section: a new section that
    // nobody wired a route for would be a tile that leads nowhere, and this is
    // the test that notices.
    for (final section in AdminSection.values) {
      await pumpAt(tester, Routes.admin);
      await tester.tap(find.text(section.title(de)));
      await tester.pumpAndSettle();

      final screenType = section.screen().runtimeType;
      expect(
        find.byWidgetPredicate((w) => w.runtimeType == screenType),
        findsOneWidget,
        reason: '${section.name} does not open',
      );
    }
  });

  testWidgets('leaving the hub lands on the app, not on nothing', (
    tester,
  ) async {
    // `/admin` is reached by `go` from the account menu, so its stack can be
    // one page deep. An implied back arrow would be absent exactly then.
    await pumpAt(tester, Routes.admin);

    await tester.tap(find.byType(BackButton));
    // `pump`, not `pumpAndSettle`: the dashboard behind the hub sits on its
    // loading spinner here, and a spinner animates forever.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(find.text(de.adminGroupOrganisation), findsNothing);
    // Scoped to the app bar: "Dashboard" is also the nav bar's own label.
    expect(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.text(de.dashboardTitle),
      ),
      findsOneWidget,
    );
  });
}
