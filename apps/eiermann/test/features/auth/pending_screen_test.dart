import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/auth/pending_screen.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';

void main() {
  late AppLocalizations de;

  setUpAll(() async => de = await germanStrings());

  Future<void> pump(WidgetTester tester, {AppUser? me}) => tester.pumpApp(
    const PendingScreen(),
    overrides: [currentUserProvider.overrideWith((ref) async => me)],
  );

  const guest = AppUser(
    id: 'u9',
    email: 'neu@example.org',
    role: UserRole.guest,
    org: 'org00000default',
  );

  testWidgets('says the sign-in WORKED and who decides next', (tester) async {
    // A reader who thinks the app is broken reloads it all afternoon.
    await pump(tester, me: guest);
    await tester.pumpAndSettle();

    expect(find.text(de.pendingHeadline), findsOneWidget);
    expect(find.text(de.pendingMessage), findsOneWidget);
  });

  testWidgets('names the address, because that is the usual cause', (
    tester,
  ) async {
    // The identity provider knows a different address than the invitation used.
    await pump(tester, me: guest);
    await tester.pumpAndSettle();

    expect(find.text('neu@example.org'), findsOneWidget);
    expect(find.text(de.pendingWrongAddressHint), findsOneWidget);
  });

  testWidgets('a profile still loading is not a spinner', (tester) async {
    // The gate already decided this screen is the right one. Waiting for the
    // address would leave somebody looking at a spinner that explains nothing.
    await pump(tester);

    expect(find.text(de.pendingHeadline), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
