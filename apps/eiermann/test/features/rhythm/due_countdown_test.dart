import 'package:eiermann/features/rhythm/due_countdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('dueInDays', () {
    test('counts calendar days, not elapsed hours', () {
      final now = DateTime(2026, 8, 22, 9);
      expect(dueInDays(DateTime(2026, 8, 22, 23, 30), now: now), 0);
      expect(dueInDays(DateTime(2026, 8, 23, 0, 5), now: now), 1);
      expect(dueInDays(DateTime(2026, 8, 29), now: now), 7);
    });

    test('is negative for an overdue date', () {
      final now = DateTime(2026, 8, 22, 9);
      expect(dueInDays(DateTime(2026, 8, 21), now: now), -1);
      expect(dueInDays(DateTime(2026, 5, 24), now: now), -90);
    });

    // A PocketBase timestamp is UTC. In CET everything after 22:00 UTC belongs
    // to the NEXT local day, and reading it raw is the defect that reaches
    // users one screen at a time while a UTC CI machine sees nothing.
    test('reads a UTC timestamp on the local calendar', () {
      final utcDue = DateTime.utc(2026, 8, 22, 22, 30);
      final localNow = DateTime.utc(2026, 8, 22, 22).toLocal();
      final local = utcDue.toLocal();
      expect(
        dueInDays(utcDue, now: localNow),
        DateTime.utc(local.year, local.month, local.day)
            .difference(
              DateTime.utc(localNow.year, localNow.month, localNow.day),
            )
            .inDays,
      );
    });

    // ── The trap the UTC anchor exists for ────────────────────────────────
    //
    // Two LOCAL midnights across a daylight-saving switch are 23 or 25 hours
    // apart, and `inDays` truncates towards zero, so a naive subtraction
    // answers the wrong day. The pair matters: in CET the spring switch
    // happens at 02:00 ON 29 March 2026, so 28→29 is a full 24 hours and
    // proves nothing. It is 29→30 that is 23 hours, and a naive implementation
    // answers 0 there — "due today" on the day before.
    //
    // These are only teeth on a machine that observes DST. The sweep below is
    // what makes the guard portable.
    test('a switch-spanning pair is still one day apart', () {
      expect(
        dueInDays(DateTime(2026, 3, 30), now: DateTime(2026, 3, 29, 12)),
        1,
      );
      expect(
        dueInDays(DateTime(2026, 3, 30), now: DateTime(2026, 3, 28, 12)),
        2,
      );
      // Autumn, where the same subtraction gives 25 hours.
      expect(
        dueInDays(DateTime(2026, 10, 26), now: DateTime(2026, 10, 25, 12)),
        1,
      );
    });

    // Every adjacent pair of local dates across a full year is exactly one day
    // apart. On a DST machine this walks over both switches and fails on the
    // naive form; on a UTC CI machine it is a tautology that costs nothing.
    // Written as a sweep rather than as two dates because the switch dates move
    // every year, and a test pinned to 2026 stops guarding in 2027.
    test('every adjacent day pair is one day, all year', () {
      var day = DateTime(2026, 1, 1, 12);
      for (var i = 0; i < 365; i++) {
        final next = DateTime(day.year, day.month, day.day + 1, 12);
        expect(dueInDays(next, now: day), 1, reason: 'from $day to $next');
        day = next;
      }
    });
  });
}
