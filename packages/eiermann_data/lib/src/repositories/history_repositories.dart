import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads the recorded **Besuche**.
///
/// A second repository over `visits`, beside `VisitsRepository`, and the split
/// is the type doing work. That one WRITES, through a route rather than a
/// collection, because `visits` has no create rule; this one only reads, so
/// "save a visit" cannot be spelled through it at all. One class with both
/// would offer a `create` the server refuses.
class VisitHistoryRepository extends PbReadOnlyRepository<Visit> {
  VisitHistoryRepository(PocketBase pb)
    : super(pb: pb, collection: 'visits', fromRecord: Visit.fromRecord);

  /// Paged by the date the visit HAPPENED, not by the date it was written.
  ///
  /// Those differ: the flow holds everything in memory until the last button,
  /// and a visit recorded in the evening is a visit made that afternoon. A
  /// chronology ordered by `created` would put a late-entered morning visit
  /// after an afternoon one, and the reader has no way to see why.
  static const _byVisitDate = PbSortKey('visited_at');

  /// One page of a building's visits, newest first.
  ///
  /// KEYSET paged: a spot's visit list grows at the end being read from, and
  /// `?page=2` would then skip and repeat rows.
  Future<PbPage<Visit>> pageForSpot(String spotId, {PbCursor? after}) => page(
    filter: filterExpr('spot = {:spot}', {'spot': spotId}),
    after: after,
    perPage: 20,
    sortKey: _byVisitDate,
  );
}

/// Reads the recorded checks.
///
/// Read-only by type AND by rule: `nest_checks` has no create, update or
/// delete rule at all. `nest_eggs` and every nest's rhythm state are derived
/// from these rows, so a check edited by hand would leave the derived state
/// describing a visit that did not happen.
class NestChecksRepository extends PbReadOnlyRepository<NestCheck> {
  NestChecksRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'nest_checks',
        fromRecord: NestCheck.fromRecord,
      );

  /// The checks belonging to [visitIds] — one request for a whole page of
  /// visits.
  ///
  /// One request and not one per visit: a chronology that fetched per row is
  /// twenty requests for a screen, which is what makes an app feel broken on a
  /// phone in a stairwell. Empty in, empty out, without asking the server
  /// anything.
  Future<List<NestCheck>> forVisits(List<String> visitIds) async {
    if (visitIds.isEmpty) return const [];
    return list(
      filter: anyOf('visit', visitIds),
      // Ordered so a visit's nests read N1..N4 rather than in write order.
      sort: 'checked_at,nest',
      // An id with no label next to it is a bug in this app, and PocketBase
      // resolves the relation server-side — so this stays ONE request.
      expand: 'nest',
    );
  }
}

/// Reads the recorded **Funde**.
///
/// Read-only by type, which is narrower than the collection: `findings` has an
/// update rule, because the note and the species label are the two things
/// somebody realises afterwards. Nothing offers that yet, so nothing here
/// spells it — the type states today's capability rather than reserving one.
class FindingsRepository extends PbReadOnlyRepository<Finding> {
  FindingsRepository(PocketBase pb)
    : super(pb: pb, collection: 'findings', fromRecord: Finding.fromRecord);

  /// The Funde belonging to [visitIds] — one request for a whole page of
  /// visits.
  Future<List<Finding>> forVisits(List<String> visitIds) async {
    if (visitIds.isEmpty) return const [];
    return list(
      filter: anyOf('visit', visitIds),
      sort: 'found_at',
      expand: 'nest',
    );
  }

  /// One page of the org's Funde, newest first — the list behind the dashboard
  /// number.
  ///
  /// Spans every building, so `expand=spot`: an id with no name next to it is
  /// unreadable, and this is the one list where the building is the first thing
  /// somebody needs.
  Future<PbPage<Finding>> pageRecent({PbCursor? after}) => page(
    after: after,
    perPage: 30,
    sortKey: const PbSortKey('found_at'),
    expand: 'spot,nest',
  );

  /// How many Funde were recorded since [since] — counted SERVER-side.
  ///
  /// A count and not a list length: the dashboard wants one number, and pulling
  /// every row over the wire to call `.length` on it is the same request with a
  /// payload nobody reads.
  Future<int> countSince(DateTime since) => count(
    filter: filterExpr('found_at >= {:since}', {
      'since': since.toUtc().toIso8601String(),
    }),
  );
}

/// `field = a || field = b || …`, with every value BOUND.
///
/// PocketBase has no `IN`, so a set-membership test is an OR chain. Only the
/// generated placeholder NAMES — `{:v0}`, `{:v1}` — reach the expression
/// string; the values go through [PbReadOnlyRepository.filterExpr], which is
/// the only way a [PbFilter] can be built at all. That is exactly the rule this
/// obeys: never interpolate a value into a filter.
///
/// An extension because `filterExpr` is an instance method, and a helper that
/// could not reach it would mean repeating this expression at every call site —
/// which is the thing that drifts. It belongs in zugvogel eventually ("no IN"
/// is a PocketBase fact, not an eiermann one); that move is the neighbour of
/// `eiermann-a0v` and waits for the same push.
extension AnyOfFilter<T> on PbReadOnlyRepository<T> {
  /// A filter matching any of [values] on [field]. Never call with an empty
  /// list: an empty OR chain is an empty expression, which matches EVERYTHING.
  PbFilter anyOf(String field, List<String> values) {
    assert(values.isNotEmpty, 'an empty anyOf would match every row');
    final params = <String, dynamic>{};
    final terms = <String>[];
    for (final (index, value) in values.indexed) {
      params['v$index'] = value;
      terms.add('$field = {:v$index}');
    }
    return filterExpr(terms.join(' || '), params);
  }
}
