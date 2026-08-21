import 'package:eiermann_models/eiermann_models.dart';
import 'package:meta/meta.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Where a [SpotOverviewRepository.dueFirst] page left off.
///
/// Three columns, not the library's [PbCursor] two, because the order is
/// `urgency, name, id`: the resume predicate has to compare exactly what the
/// `ORDER BY` compares, or a page silently skips and repeats rows. Sorting by
/// urgency alone and tie-breaking on `id` would work as paging but hand the
/// reader forty overdue Spots in record order, which is no order at all.
@immutable
class SpotOverviewCursor {
  const SpotOverviewCursor({
    required this.urgency,
    required this.name,
    required this.id,
  });

  /// The last row's rank, as an INT. The whole reason this cursor exists —
  /// see [SpotOverviewRepository.dueFirst].
  final int urgency;

  /// The last row's name. Compared under the server's collation (SQLite
  /// BINARY), the same one the `ORDER BY` uses, so `Zora` sorts before `berta`
  /// in both places and the resume stays consistent even where it looks odd.
  final String name;

  final String id;

  @override
  bool operator ==(Object other) =>
      other is SpotOverviewCursor &&
      other.urgency == urgency &&
      other.name == name &&
      other.id == id;

  @override
  int get hashCode => Object.hash(urgency, name, id);

  @override
  String toString() => 'SpotOverviewCursor($urgency, $name, $id)';
}

/// One page of [SpotOverviewRepository.dueFirst].
@immutable
class SpotOverviewPage {
  const SpotOverviewPage({required this.items, this.cursor});

  final List<SpotOverview> items;

  /// Pass to the next `dueFirst` call, or null when this was the last page.
  final SpotOverviewCursor? cursor;

  bool get hasMore => cursor != null;
}

/// Reads the `spot_overview` view: the Spot list and the map, in one query.
///
/// **Read-only by type.** `PbReadOnlyRepository` has no create/update/delete,
/// so a write against a PocketBase view is a compile error here rather than the
/// runtime 400 it would otherwise be. Writes go to `SpotsRepository`.
class SpotOverviewRepository extends PbReadOnlyRepository<SpotOverview> {
  SpotOverviewRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'spot_overview',
        fromRecord: SpotOverview.fromRecord,
      );

  /// The order the list and the map both use: loudest first, then by name.
  static const _dueFirstSort = 'urgency,name,id';

  /// Where the urgency keyset resumes from. One expression, so the `ORDER BY`
  /// and the predicate cannot drift apart.
  static const _keysetExpr =
      '(urgency > {:u} || (urgency = {:u} && (name > {:n} '
      '|| (name = {:n} && id > {:i}))))';

  /// The columns [search] matches, in the order a reader would try them.
  static const _searchExpr =
      '(name ~ {:q} || street ~ {:q} || city ~ {:q} || postal_code ~ {:q})';

  /// One page of Spots, most urgent first, resumed from [after].
  ///
  /// Keyset, not `?page=`: Spots are added while the list is being read, and
  /// with an offset every row written in between shifts the window, so the
  /// reader sees some rows twice and misses others. Asking for "after the last
  /// row I saw" cannot skip or repeat.
  ///
  /// **Why this is not `PbReadOnlyRepository.page`.** That one builds its
  /// resume predicate from a [PbCursor], whose value is a `String`, and
  /// `pb.filter` binds a String as a quoted SQL literal. `urgency` is a
  /// COMPUTED view column, so PocketBase reports it as `json` and SQLite gives
  /// it no affinity — which means no conversion happens in the comparison and
  /// SQLite's storage-class ordering applies: an INTEGER is always less than
  /// TEXT. `urgency > '0'` is therefore false for every row, so the second page
  /// comes back empty and the list silently ends after fifty Spots. Verified
  /// against the running server. Binding the rank as an int is the fix, and it
  /// needs a cursor that can carry one.
  Future<SpotOverviewPage> dueFirst({
    SpotOverviewCursor? after,
    String query = '',
    int perPage = 50,
  }) {
    return guard(() async {
      final result = await service.getList(
        page: 1,
        perPage: perPage,
        skipTotal: true,
        filter: _filter(query: query, after: after)?.expression,
        sort: _dueFirstSort,
      );
      final items = result.items.map(fromRecord).toList();
      // A short page means the end. A full one might be the end too; the next
      // call returning nothing settles it, which costs one request and never
      // stops early on a boundary.
      final last = items.isEmpty || items.length < perPage ? null : items.last;
      return SpotOverviewPage(
        items: items,
        cursor: last == null
            ? null
            : SpotOverviewCursor(
                urgency: last.urgency,
                name: last.name,
                id: last.id,
              ),
      );
    });
  }

  /// Every Spot whose name or address contains [query], by name.
  ///
  /// Unpaged, because its callers want the whole matching set at once: the map
  /// draws all of them as pins, and a search that returned only the first page
  /// would hide pins the reader is looking straight at. An empty [query]
  /// returns every Spot in the org.
  Future<List<SpotOverview>> search(String query) => list(
    filter: _filter(query: query),
    sort: 'name',
  );

  /// The bound filter for a query and an optional resume point, or null when
  /// neither applies.
  ///
  /// Built through [filterExpr] with the values as params, never interpolated:
  /// [query] is whatever somebody typed into a search field, and a filter
  /// expression is a query language.
  PbFilter? _filter({String query = '', SpotOverviewCursor? after}) {
    final trimmed = query.trim();
    if (trimmed.isEmpty && after == null) return null;
    return filterExpr(
      [
        if (trimmed.isNotEmpty) _searchExpr,
        if (after != null) _keysetExpr,
      ].join(' && '),
      {
        if (trimmed.isNotEmpty) 'q': trimmed,
        if (after != null) ...{
          'u': after.urgency,
          'n': after.name,
          'i': after.id,
        },
      },
    );
  }
}
