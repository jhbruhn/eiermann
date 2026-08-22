/// How many LOCAL calendar days lie between today and [dueAt].
///
/// Negative when overdue, 0 when due today, positive when still to come.
/// [now] is injectable so a test can stand on a date rather than on the
/// machine's clock.
///
/// This is computed in the CLIENT and not in SQL, and that is the rule rather
/// than a convenience: `nest_state`'s own header refuses a "days in state"
/// column because PocketBase stores UTC and SQLite's `DATE('now')` is UTC too,
/// so a difference taken there is right in Greenwich and a day out in CET for
/// everything recorded after 22:00 local. The views therefore send the dates
/// raw and every subtraction happens here — the same reason every
/// `DateTime`→text conversion goes through `formatLocalDate`.
///
/// Two traps live in these four lines, and each produces an off-by-one that a
/// UTC-clocked CI machine cannot see:
///
///  * PocketBase timestamps are UTC, so [dueAt] is converted with `toLocal()`
///    first. Without it a date written at 23:00 CET counts as the day before.
///  * The subtraction is anchored in **UTC on purpose**. Two LOCAL midnights
///    are 23 or 25 hours apart across a daylight-saving switch, and `inDays`
///    truncates towards zero — in CET, 28 to 29 March 2026 comes out as zero
///    days. Rebuilding the local year-month-day inside `DateTime.utc` makes
///    every day exactly 24 hours long, which is what a day count means.
int dueInDays(DateTime dueAt, {DateTime? now}) {
  final due = dueAt.toLocal();
  final today = (now ?? DateTime.now()).toLocal();
  return DateTime.utc(
    due.year,
    due.month,
    due.day,
  ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
}
