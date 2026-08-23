import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/team/invite_sheet.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

import '../../support/harness.dart';

class _MockUsers extends Mock implements UsersRepository {}

const _me = AppUser(
  id: 'u-coord',
  email: 'rita@eiermann.test',
  name: 'Rita',
  role: UserRole.coordinator,
  org: 'org00000default',
);

void main() {
  late AppLocalizations de;
  late _MockUsers users;

  setUpAll(() async {
    de = await germanStrings();
    registerFallbackValue(UserRole.member);
  });

  setUp(() {
    users = _MockUsers();
  });

  /// The server's own report of what it can do. The invite reads exactly one
  /// thing from it — whether a reset mail can be sent — and that single bool
  /// picks between the two entirely different things this flow does.
  ServerInfo info({required bool canMail}) => ServerInfo(
    version: '1.0.0',
    name: 'Eiermann',
    auth: ServerAuthOptions(passwordReset: canMail),
  );

  Future<void> pumpSheet(WidgetTester tester, {bool canMail = true}) async {
    // Opened the way the app opens it, through `showAppSheet`. The discard
    // guard hangs off `Navigator.maybePop`, which only exists for a route that
    // was actually pushed — and a bare `InviteSheet` has no Material ancestor
    // for its fields either.
    tester.useSurface(const Size(900, 1600));
    await tester.pumpApp(
      Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showInviteSheet(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      overrides: [
        usersRepositoryProvider.overrideWith((ref) async => users),
        currentUserProvider.overrideWith((ref) async => _me),
        serverInfoProvider.overrideWith((ref) async => info(canMail: canMail)),
      ],
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Stubs a successful invite and hands back the password it returns.
  String stubInvite({bool mailSent = true}) {
    const password = 'Passwort123456ab';
    when(
      () => users.invite(
        email: any(named: 'email'),
        name: any(named: 'name'),
        role: any(named: 'role'),
        org: any(named: 'org'),
        phone: any(named: 'phone'),
        sendResetEmail: any(named: 'sendResetEmail'),
      ),
    ).thenAnswer(
      (_) async => Invitation(
        user: const AppUser(
          id: 'u-new',
          email: 'neu@eiermann.test',
          name: 'Neu',
          role: UserRole.member,
          org: 'org00000default',
        ),
        password: password,
        mailSent: mailSent,
      ),
    );
    return password;
  }

  testWidgets('a name is required, although the schema allows it empty', (
    tester,
  ) async {
    // Not the form being fussy. Every audit-shaped row in this database stores
    // a text SNAPSHOT of its author, and an account with no name snapshots its
    // email address — which then sits, permanently, in the visit history of
    // every Spot that person touches, exported reports included.
    stubInvite();
    await pumpSheet(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, de.teamFieldEmail),
      'neu@eiermann.test',
    );
    await tester.tap(find.text(de.teamInviteAction));
    await tester.pumpAndSettle();

    expect(find.text(de.fieldRequired), findsOneWidget);
    verifyNever(
      () => users.invite(
        email: any(named: 'email'),
        name: any(named: 'name'),
        role: any(named: 'role'),
        org: any(named: 'org'),
        phone: any(named: 'phone'),
        sendResetEmail: any(named: 'sendResetEmail'),
      ),
    );
  });

  testWidgets('the invite defaults to member, never to the coordination', (
    tester,
  ) async {
    // A dropdown opening on "Koordination" hands out the role that deletes
    // Spots, by inattention. The coordination is granted deliberately, later,
    // on a row somebody has looked at.
    stubInvite();
    await pumpSheet(tester);

    await tester.enterText(
      find.widgetWithText(TextFormField, de.teamFieldEmail),
      'neu@eiermann.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.teamFieldName),
      'Neu',
    );
    await tester.tap(find.text(de.teamInviteAction));
    await tester.pumpAndSettle();

    verify(
      () => users.invite(
        email: 'neu@eiermann.test',
        name: 'Neu',
        role: UserRole.member,
        org: 'org00000default',
      ),
    ).called(1);
  });

  testWidgets("the invited org is the CALLER's, never a field on the form", (
    tester,
  ) async {
    // `users.createRule` pins `@request.body.org` to the caller's own org —
    // the one write in this schema that could cross the tenancy line. A form
    // that asked for it would be a form offering a refusal.
    stubInvite();
    await pumpSheet(tester);

    expect(find.text('org00000default'), findsNothing);
  });

  /// Pumps just the result dialog for [invitation].
  Future<void> pumpResult(
    WidgetTester tester,
    Invitation invitation,
  ) async {
    await tester.pumpApp(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showInvitationResult(context, invitation),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  const created = AppUser(
    id: 'u-new',
    email: 'neu@eiermann.test',
    name: 'Neu',
    role: UserRole.member,
    org: 'org00000default',
  );

  testWidgets('no mailer: the start password is shown, once and plainly', (
    tester,
  ) async {
    // The divergence from federfall, and the case it exists for. federfall
    // hides its invite action when the server cannot mail; here that would mean
    // a self-hosted group that can never add anybody. The server keeps only the
    // hash, so this really is the only time the string can be read.
    await pumpResult(
      tester,
      const Invitation(
        user: created,
        password: 'Passwort123456ab',
        mailSent: false,
      ),
    );

    expect(find.text('Passwort123456ab'), findsOneWidget);
    expect(find.text(de.teamInvitedOnceHint), findsOneWidget);
    // Selectable, because the reader has to be able to get it out of here by
    // hand when the clipboard is unavailable — a web build without clipboard
    // permission, or a screen being read aloud.
    expect(find.byType(SelectableText), findsOneWidget);
  });

  testWidgets('a mail went out: the password is NEVER put on screen', (
    tester,
  ) async {
    // The password still exists — PocketBase refuses a create without one — but
    // it is not the way in any more. Showing it beside "we have mailed them a
    // link" would put a second credential into circulation, and specifically
    // the one the invitee is not going to use.
    await pumpResult(
      tester,
      const Invitation(
        user: created,
        password: 'Passwort123456ab',
        mailSent: true,
      ),
    );

    expect(find.textContaining('neu@eiermann.test'), findsOneWidget);
    expect(find.text('Passwort123456ab'), findsNothing);
    expect(find.byType(SelectableText), findsNothing);
    expect(find.text(de.teamInvitedOnceHint), findsNothing);
  });

  testWidgets('a server with no mailer is not asked to send one', (
    tester,
  ) async {
    // A round trip to a guaranteed failure, and nothing to learn from it: the
    // fallback is the same either way.
    stubInvite(mailSent: false);
    await pumpSheet(tester, canMail: false);

    await tester.enterText(
      find.widgetWithText(TextFormField, de.teamFieldEmail),
      'neu@eiermann.test',
    );
    await tester.enterText(
      find.widgetWithText(TextFormField, de.teamFieldName),
      'Neu',
    );
    await tester.tap(find.text(de.teamInviteAction));
    await tester.pumpAndSettle();

    verify(
      () => users.invite(
        email: 'neu@eiermann.test',
        name: 'Neu',
        role: UserRole.member,
        org: 'org00000default',
        sendResetEmail: false,
      ),
    ).called(1);
  });

  test('a generated password is unguessable and unambiguous', () {
    // Read out loud and retyped off a screenshot, so the alphabet drops the
    // pairs a human cannot tell apart. And `Random.secure`, not the default
    // clock-seeded `Random`: two invites in the same millisecond would
    // otherwise get the same password.
    final generated = List.generate(
      50,
      (_) => UsersRepository.generatePassword(),
    );

    expect(generated.toSet().length, 50, reason: 'two invites collided');
    for (final password in generated) {
      expect(password.length, 16);
      expect(
        RegExp(r'^[A-HJ-NP-Za-km-z2-9]+$').hasMatch(password),
        isTrue,
        reason: '$password contains an ambiguous character',
      );
    }
  });
}
