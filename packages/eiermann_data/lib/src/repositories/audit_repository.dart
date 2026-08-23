import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads the audit trail. There is no write side, and that is the point.
///
/// `audit_entries` has no create, update or delete rule at all —
/// superuser-only, the strongest statement PocketBase offers — so the only
/// way a row appears is a hook deciding it should. A repository with a
/// `create` here would be one whose every call comes back 400, and worse, one
/// that suggests the log is something a client contributes to.
///
/// Reading is the coordination's alone (`audit_entries.listRule`). A member
/// seeing who demoted whom is a different product; this table points
/// accountability upwards.
class AuditRepository extends PbReadOnlyRepository<AuditEntry> {
  AuditRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'audit_entries',
        fromRecord: AuditEntry.fromRecord,
      );

  /// Newest first, by when the act was RECORDED.
  ///
  /// `created` and not some observed date, because unlike a visit there is no
  /// difference here: the row is written in the same request as the act. It is
  /// also the column the table is indexed on.
  static const PbSortKey _byRecordedAt = PbSortKey.newestCreated;

  /// One page of the org's log.
  ///
  /// KEYSET paged, never `?page=`. This table only ever grows, and it grows at
  /// exactly the end being read from — so an offset page would skip rows as new
  /// ones arrive. An audit log that silently omits an entry is worse than no
  /// audit log, because it is cited.
  ///
  /// Org scope is the server's: `listRule` compares against the STORED row, so
  /// there is nothing to pass and no way to widen it from here.
  Future<PbPage<AuditEntry>> pageOfLog({PbCursor? after}) =>
      page(after: after, perPage: 30, sortKey: _byRecordedAt);

  /// The log narrowed to one Spot, nest, account or organisation.
  ///
  /// [targetId] matches the stored TEXT id, which is why this still answers for
  /// a target that has since been deleted — the second most useful thing this
  /// screen does.
  Future<PbPage<AuditEntry>> pageForTarget(
    String targetId, {
    PbCursor? after,
  }) => page(
    filter: filterExpr('target = {:target}', {'target': targetId}),
    after: after,
    perPage: 30,
    sortKey: _byRecordedAt,
  );
}
