import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `tours` — the reusable route templates.
///
/// Any active member may build one: in this group the person who knows a route
/// is the person who walks it, not necessarily the one holding the coordinator
/// role. Deleting is the coordination's, because it takes the route's stop list
/// with it and orphans every round ever walked under it. [retire] is the move a
/// member has instead.
///
/// **The name is unique per org, case-insensitively**, enforced by an index.
/// "Tour 1 fortsetzen" has to mean one thing, and two templates with that name
/// make every sentence the app says about a tour ambiguous. A rename or a
/// create that collides comes back as a validation failure, so the sheet shows
/// it on the field rather than as a mystery.
class ToursRepository extends PbRepository<Tour> {
  ToursRepository(PocketBase pb)
    : super(pb: pb, collection: 'tours', fromRecord: Tour.fromRecord);

  /// The order the group thinks in — "Tour 1", "Tour 2", the Thursday round —
  /// with `name` breaking the tie so two templates with no index yet still land
  /// somewhere stable rather than in record order.
  static const _order = 'sort_index,name';

  /// Every template that is still walked, in the group's own order.
  ///
  /// Unpaged: a volunteer group has a handful of routes, and a picker that
  /// showed only the first page would hide one somebody is looking for.
  Future<List<Tour>> active() =>
      list(filter: filterExpr('is_active = true'), sort: _order);

  /// Every template including the retired ones — the management screen's read.
  Future<List<Tour>> all() => list(sort: _order);

  /// Takes a route out of use without destroying it.
  ///
  /// The alternative a member does NOT have is deleting: that removes the stop
  /// list and leaves last spring's rounds pointing at nothing. Retiring keeps
  /// the route readable next to the rounds walked on it.
  Future<Tour> retire(String id) => update(id, {'is_active': false});

  /// Puts a retired route back into use.
  Future<Tour> reactivate(String id) => update(id, {'is_active': true});

  /// The body a create or an update sends.
  ///
  /// [org] belongs to the create path only — the update rule refuses it, which
  /// is what makes a template un-re-tenantable.
  static Map<String, dynamic> body({
    required String name,
    String? note,
    bool isActive = true,
    int? sortIndex,
    String? org,
  }) => {
    'name': name,
    'note': note ?? '',
    'is_active': isActive,
    'sort_index': ?sortIndex,
    'org': ?org,
  };
}

/// Reads and writes `tour_spots` — the ordered route itself.
///
/// Its own repository rather than a method on [ToursRepository], because it is
/// its own collection with its own rules: only `sort_index` is editable. A stop
/// cannot be re-pointed at another building or moved to another route, and that
/// is not a missing feature — re-pointing silently rewrites what a route IS
/// while every screen keeps showing the same row. Removing the stop and adding
/// the right one is the honest operation and costs one tap.
class TourStopsRepository extends PbRepository<TourStop> {
  TourStopsRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'tour_spots',
        fromRecord: TourStop.fromRecord,
      );

  /// One route, in order.
  ///
  /// `expand=spot` and not a lookup per row: this is the list somebody walks,
  /// and a request per stop is what makes an app feel broken on a phone in a
  /// stairwell. Still one request — PocketBase resolves the relation
  /// server-side.
  ///
  /// Unpaged, deliberately. A route is a thing a person walks in a day; if one
  /// ever outgrows a single response, the answer is a shorter route.
  Future<List<TourStop>> forTour(String tourId) => list(
    filter: filterExpr('tour = {:tour}', {'tour': tourId}),
    sort: 'sort_index,id',
    expand: 'spot',
  );

  /// Writes [order] as the route's new sequence.
  ///
  /// One request per moved stop, and there is no batch endpoint to hide that:
  /// PocketBase has no bulk update. The saving grace is that a drag moves ONE
  /// row's neighbours — the loop skips every stop whose index is already right,
  /// so a reorder of a twelve-stop route sends two or three writes, not twelve.
  ///
  /// Sequential rather than concurrent. These writes all land on rows of one
  /// route that the screen is about to re-read, and a half-applied concurrent
  /// batch would leave an order nobody chose; sequential means a failure stops
  /// at a known point.
  Future<void> reorder(List<TourStop> order) async {
    for (var index = 0; index < order.length; index++) {
      if (order[index].sortIndex == index) continue;
      await update(order[index].id, {'sort_index': index});
    }
  }

  /// The body a new stop sends. There is no update path worth a helper: the one
  /// editable field is `sort_index`, which [reorder] writes.
  static Map<String, dynamic> body({
    required String tour,
    required String spot,
    required int sortIndex,
    String? org,
  }) => {
    'tour': tour,
    'spot': spot,
    'sort_index': sortIndex,
    'org': ?org,
  };
}
