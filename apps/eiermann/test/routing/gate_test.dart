import 'package:eiermann/routing/router.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

/// The four questions the gate asks, and the order it asks them in.
void main() {
  const loading = AsyncLoading<bool>();
  const yes = AsyncData(true);
  const no = AsyncData(false);
  const member = AsyncData<AppUser?>(
    AppUser(id: 'u1', email: 'feld@eiermann.test', role: UserRole.member),
  );
  const guest = AsyncData<AppUser?>(
    AppUser(id: 'u9', email: 'neu@example.org', role: UserRole.guest),
  );

  String? at(
    String here, {
    AsyncValue<bool> configured = yes,
    AsyncValue<bool> signedIn = yes,
    AsyncValue<AppUser?> me = member,
  }) => gateRedirect(
    configured: configured,
    signedIn: signedIn,
    me: me,
    here: here,
  );

  group('holds rather than guesses', () {
    test('a session still being read stays on the splash', () {
      // Guessing "not signed in" here bounces a returning user to a login form
      // they did not need — a second of pointless doubt on every cold start.
      expect(at('/', signedIn: loading), '/splash');
      expect(at('/splash', signedIn: loading), isNull);
    });

    test('a profile still being read stays there too', () {
      expect(at('/', me: const AsyncLoading()), '/splash');
    });
  });

  test('no server configured outranks every other question', () {
    // The client cannot be built without a base URL, so this comes first even
    // when a session somehow exists.
    expect(at('/', configured: no), '/setup');
    expect(at('/', configured: no, me: guest), '/setup');
  });

  test('not signed in goes to login', () {
    expect(at('/', signedIn: no), '/login');
  });

  group('the guest wall', () {
    test('a guest waits, wherever they aimed', () {
      // Every access rule refuses `guest` by name (migration 014), so the app
      // behind the gate would be empty lists and buttons that answer 403.
      expect(at('/', me: guest), '/pending');
      expect(at('/spots', me: guest), '/pending');
      expect(at('/pending', me: guest), isNull);
    });

    test('a role this build cannot name is walled off as well', () {
      // The server refuses it too. Guessing the other way puts the reader in
      // front of errors instead of an explanation.
      expect(at('/', me: const AsyncData<AppUser?>(null)), '/pending');
    });

    test('a promotion moves the reader on, with no second sign-in', () {
      // What a coordinator letting somebody in looks like from the waiting
      // screen: the gate listens to the role, so the redirect re-runs.
      expect(at('/pending'), '/');
    });

    test('a FAILED profile read is NOT a wall', () {
      // A member whose read failed on resume must not be told they are waiting
      // for access: that reads as a decision about them and has no way out.
      const failed = AsyncError<AppUser?>('offline', StackTrace.empty);
      expect(at('/spots', me: failed), isNull);
      expect(at('/', me: failed), isNull);
    });
  });

  test('a member deep in the app is left alone', () {
    expect(at('/spots/s1'), isNull);
    expect(at('/areas/a1'), isNull);
  });

  test('...and is taken off every gate screen', () {
    for (final gate in ['/splash', '/setup', '/login', '/pending']) {
      expect(at(gate), '/', reason: gate);
    }
  });
}
