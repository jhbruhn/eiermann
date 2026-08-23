import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/team/team_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

import '../../support/harness.dart';

class _MockUsers extends Mock implements UsersRepository {}

AppUser user({
  required String id,
  String? name = 'Name',
  String email = 'wer@eiermann.test',
  UserRole? role = UserRole.member,
  bool isActive = true,
  String? phone,
  // Verified by default, so only the tests that are ABOUT an unclaimed
  // invitation carry the flag that produces the badge.
  bool verified = true,
}) => AppUser(
  id: id,
  email: email,
  name: name,
  phone: phone,
  role: role,
  org: 'org00000default',
  isActive: isActive,
  verified: verified,
);

void main() {
  late AppLocalizations de;
  late _MockUsers users;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(<String, dynamic>{});
    registerFallbackValue(UserRole.member);
  });

  setUp(() {
    users = _MockUsers();
  });

  /// Pumps the roster as [me]. The signed-in account is deliberately a
  /// parameter of every test here: almost everything this screen decides —
  /// whether there are controls at all, and whether THIS row has them — comes
  /// from who is looking.
  Future<void> pumpTeam(
    WidgetTester tester,
    List<AppUser> roster, {
    required AppUser me,
    bool canMail = false,
    bool canPassword = true,
  }) async {
    tester.useSurface(const Size(900, 1600));
    when(users.team).thenAnswer((_) async => roster);
    await tester.pumpApp(
      const TeamScreen(),
      overrides: [
        usersRepositoryProvider.overrideWith((ref) async => users),
        currentUserProvider.overrideWith((ref) async => me),
        serverInfoProvider.overrideWith(
          (ref) async => ServerInfo(
            version: '1.0.0',
            name: 'Eiermann',
            auth: ServerAuthOptions(
              password: canPassword,
              passwordReset: canMail,
            ),
          ),
        ),
      ],
    );
    await tester.pumpAndSettle();
  }

  final coordinator = user(
    id: 'u-coord',
    name: 'Rita',
    email: 'koordination@eiermann.test',
    role: UserRole.coordinator,
  );

  testWidgets('a departed member is still on the list, and said to be', (
    tester,
  ) async {
    // The reason nobody is deleted: their name appears on every visit they
    // recorded. A roster that filtered them out would leave a reader looking
    // at a name they cannot place.
    await pumpTeam(
      tester,
      [
        coordinator,
        user(id: 'u-gone', name: 'Meike', isActive: false),
      ],
      me: coordinator,
    );

    expect(find.text('Meike'), findsOneWidget);
    expect(find.text(de.teamSectionFormer), findsOneWidget);
    expect(find.text(de.teamSectionFormerHint), findsOneWidget);
  });

  testWidgets('an account waiting for a role sorts ABOVE the working team', (
    tester,
  ) async {
    // The only row on this screen that is waiting on the reader. Sorted in
    // among the rest by name, an account provisioned by an identity provider
    // sits unnoticed for a week — which from the other side looks like an app
    // that never let them in.
    await pumpTeam(
      tester,
      [
        // Alphabetically first, so a name sort alone would put it on top and
        // the test would pass for the wrong reason.
        user(id: 'u-a', name: 'Anna'),
        coordinator,
        user(id: 'u-wait', name: 'Zoe', role: UserRole.guest),
      ],
      me: coordinator,
    );

    final waiting = tester.getRect(find.text(de.teamSectionWaiting));
    final active = tester.getRect(find.text(de.teamSectionActive));
    expect(waiting.top, lessThan(active.top));
    expect(
      tester.getRect(find.text('Zoe')).top,
      lessThan(tester.getRect(find.text('Anna')).top),
    );
    // And it is named as not-yet-let-in rather than shown as a role.
    expect(find.text(de.teamRolePending), findsOneWidget);
  });

  testWidgets('a member reads the roster and is offered NOTHING to change', (
    tester,
  ) async {
    // Both halves. The read is deliberate — a visit names its author, and a
    // name nobody can resolve is worse than no name. The absence of controls is
    // too: `users.updateRule` would refuse every one of them, and a button that
    // exists to come back 403 is worse than no button.
    final me = user(id: 'u-me', name: 'Feldteam');
    await pumpTeam(tester, [coordinator, me], me: me);

    expect(find.text('Rita'), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.text(de.teamInviteAction), findsNothing);
  });

  testWidgets('the coordinator cannot act on their OWN row, and is told why', (
    tester,
  ) async {
    // The invariant that keeps a group from locking itself out: the server puts
    // a self-edited privilege field back, so offering the control here would be
    // offering a guaranteed refusal. Greying it out silently reads as a bug in
    // the app — hence the sentence.
    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-other', name: 'Anna')],
      me: coordinator,
    );

    expect(find.text(de.teamYou), findsOneWidget);
    expect(find.text(de.teamSelfLockedHint), findsOneWidget);
    // Exactly one menu: Anna's. Not the coordinator's own.
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
  });

  testWidgets('promoting somebody writes the role and re-reads the roster', (
    tester,
  ) async {
    when(() => users.setRole(any(), any())).thenAnswer(
      (_) async => user(id: 'u-other', role: UserRole.coordinator),
    );
    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-other', name: 'Anna')],
      me: coordinator,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamMakeCoordinatorAction));
    await tester.pumpAndSettle();

    verify(() => users.setRole('u-other', UserRole.coordinator)).called(1);
    // Twice: the initial read, and the re-read after the write. A screen that
    // wrote and did not re-read keeps showing the role somebody was moved out
    // of.
    verify(users.team).called(2);
  });

  testWidgets('ending access is confirmed first, and says what it costs', (
    tester,
  ) async {
    // Not a nicety. `users.authRule` is re-evaluated on every request, so this
    // signs somebody out mid-request — in practice, in a stairwell, halfway
    // through recording a visit.
    when(() => users.setActive(any(), active: any(named: 'active'))).thenAnswer(
      (_) async => user(id: 'u-other', isActive: false),
    );
    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-other', name: 'Anna')],
      me: coordinator,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamDeactivateAction));
    await tester.pumpAndSettle();

    expect(find.text(de.teamDeactivateTitle), findsOneWidget);
    verifyNever(() => users.setActive(any(), active: any(named: 'active')));

    // Dismissing the dialog leaves the account exactly as it was.
    await tester.tap(find.text(de.actionCancel));
    await tester.pumpAndSettle();
    verifyNever(() => users.setActive(any(), active: any(named: 'active')));

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamDeactivateAction));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamDeactivateConfirm));
    await tester.pumpAndSettle();

    verify(() => users.setActive('u-other', active: false)).called(1);
  });

  testWidgets('a refused write says so and leaves the row alone', (
    tester,
  ) async {
    // The server is the boundary, not this screen. When it refuses anyway — a
    // rule this client does not model, a session that just expired — the reader
    // has to see that nothing happened.
    when(() => users.setRole(any(), any())).thenThrow(
      const RepositoryException('nope', kind: RepositoryErrorKind.unauthorized),
    );
    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-other', name: 'Anna')],
      me: coordinator,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamMakeCoordinatorAction));
    await tester.pumpAndSettle();

    expect(find.text(de.errorUnauthorized), findsOneWidget);
  });

  testWidgets('an invitation nobody took up is named on the row', (
    tester,
  ) async {
    // `verified` is set when somebody completes a password reset, which for an
    // invited account is the moment they choose their own password. So an
    // active, unverified member is one who never arrived — and without the
    // badge they look exactly like a member who is simply quiet, which is how
    // an invitation sent to a mistyped address goes unnoticed for a month.
    await pumpTeam(
      tester,
      [
        coordinator,
        user(id: 'u-new', name: 'Anna', verified: false),
        user(id: 'u-old', name: 'Bert'),
      ],
      me: coordinator,
    );

    expect(find.text(de.teamInvitePending), findsOneWidget);
  });

  testWidgets('resending is offered only where it can do something', (
    tester,
  ) async {
    // Two conditions, and each removes it on its own: the link needs a mailer,
    // and somebody who already set their own password has nothing to resend.
    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-new', name: 'Anna', verified: false)],
      me: coordinator,
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(
      find.text(de.teamResendInviteAction),
      findsNothing,
      reason: 'no mailer, so there is no link to send',
    );
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    await pumpTeam(
      tester,
      [coordinator, user(id: 'u-done', name: 'Bert')],
      me: coordinator,
      canMail: true,
    );
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(
      find.text(de.teamResendInviteAction),
      findsNothing,
      reason: 'Bert already set his own password',
    );
  });

  testWidgets('a resent invitation says so, because a mail leaves no trace', (
    tester,
  ) async {
    // The only action on this screen whose result is invisible in the row. A
    // coordinator who taps it and sees nothing cannot tell a sent mail from a
    // dead button.
    when(() => users.resendInvitation(any())).thenAnswer((_) async {});
    await pumpTeam(
      tester,
      [
        coordinator,
        user(
          id: 'u-new',
          name: 'Anna',
          email: 'anna@eiermann.test',
          verified: false,
        ),
      ],
      me: coordinator,
      canMail: true,
    );

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(de.teamResendInviteAction));
    await tester.pumpAndSettle();

    verify(() => users.resendInvitation('anna@eiermann.test')).called(1);
    expect(
      find.text(de.teamInviteResent('anna@eiermann.test')),
      findsOneWidget,
    );
  });

  testWidgets('a server without password sign-in offers no invite at all', (
    tester,
  ) async {
    // An OIDC-only instance. A password account created there could never sign
    // in, so the action is hidden rather than left to produce a dead account —
    // federfall's rule, and its reason. What is NOT required is a mailer: this
    // app hands the start password over instead of hiding the button.
    await pumpTeam(
      tester,
      [coordinator],
      me: coordinator,
      canPassword: false,
    );

    expect(find.text(de.teamInviteAction), findsNothing);
  });
}
