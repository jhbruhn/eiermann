import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `tour_runs` — one walking of a route.
///
/// Almost nothing about a round is the client's to say. `started_by`,
/// `started_by_name`, `started_at` and `tour_name` are all written by the
/// server (`app_tour_rules.js`), because a snapshot a client supplies is a
/// snapshot that can lie — and it would lie in the one direction nobody could
/// catch, since the whole point of those fields is that the template or the
/// account they name may no longer exist to compare against.
///
/// So [start] sends the template and nothing else, and the record that comes
/// back is the truth about who started what and when.
class TourRunsRepository extends PbRepository<TourRun> {
  TourRunsRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'tour_runs',
        fromRecord: TourRun.fromRecord,
      );

  /// A PocketBase date field that was never set stores the empty string, so
  /// "still going" is `finished_at = ''` and not `finished_at = null`.
  static const _open = "finished_at = ''";

  /// My own round that is still going, or null.
  ///
  /// The dashboard's "Tour 1 fortsetzen" reads exactly this, and it is what
  /// makes a round survive the app being killed: the open row IS the resume
  /// point, so nothing has to be kept on the device. [userId] is passed rather
  /// than inferred — the filter has to name a person, and the access rule
  /// already limits the answer to the org.
  ///
  /// **Somebody else's open round is deliberately not offered.** Two people
  /// walking one round would each record visits into it and neither would see
  /// the other's progress until a refresh; worse, the second one to press
  /// "fertig" would be finishing a round still being walked.
  ///
  /// More than one open round for one person should not happen — the app offers
  /// resuming rather than starting — but a crash between two taps could produce
  /// it, so the newest wins: that is the one that matches what they just did.
  /// Not `firstWhere`, which cannot say which one it means.
  Future<TourRun?> openFor(String userId) async {
    final rows = await list(
      filter: filterExpr('$_open && started_by = {:me}', {'me': userId}),
      sort: '-started_at',
    );
    return rows.firstOrNull;
  }

  /// Starts a round, optionally following [tour].
  ///
  /// No [tour] is the improvised round, and it is not a fallback: it is how the
  /// three-buildings-on-the-way-home case gets recorded at all.
  Future<TourRun> start({String? tour, String? org}) =>
      create({'tour': ?tour, 'org': ?org});

  /// Closes the round. [note] is the one thing worth writing afterwards.
  ///
  /// The timestamp sent here is a flag, not a value: the server stamps its own
  /// clock and refuses any later change, so finishing happens once. Sending
  /// the client's `now` anyway keeps the intent readable at the call site — and
  /// the server would reject an empty string as "not finished".
  Future<TourRun> finish(String id, {String? note}) => update(id, {
    'finished_at': DateTime.now().toUtc().toIso8601String(),
    'note': ?note,
  });

  /// Throws away a round that was started by mistake.
  ///
  /// Only works on your OWN round while it is still open — the access rule says
  /// so, and a finished round is history that nothing deletes, not even the
  /// coordination. Any visit already recorded in it stands: `visits.tour_run`
  /// does not cascade, because the visit is the observation this app exists to
  /// keep and the round is only the bag it was carried in.
  Future<void> discard(String id) => delete(id);
}

/// Reads `visits` — the recorded Besuche.
///
/// **Read-only by type**, and that is the whole reason it is a separate class
/// from `VisitsRepository`: `visits` has no create rule at all, because a visit
/// written record-by-record could end up half-there and a half-visit is
/// indistinguishable from nests somebody chose not to touch. The writer is the
/// transactional endpoint; this is the read, and `PbReadOnlyRepository` makes
/// the wrong one a compile error rather than a runtime 400.
class VisitLogRepository extends PbReadOnlyRepository<Visit> {
  VisitLogRepository(PocketBase pb)
    : super(pb: pb, collection: 'visits', fromRecord: Visit.fromRecord);

  /// Every visit recorded on one round, oldest first.
  ///
  /// This is a round's progress — there is no per-stop table to read instead
  /// (see `tourProgress`). `expand=spot` because an addition to the route has
  /// no `tour_spots` row to take a name from, and an id with no label next to
  /// it is a bug in this app.
  ///
  /// Unpaged: a round is what one person walks in a day.
  Future<List<Visit>> forRun(String runId) => list(
    filter: filterExpr('tour_run = {:run}', {'run': runId}),
    sort: 'visited_at,id',
    expand: 'spot',
  );
}
