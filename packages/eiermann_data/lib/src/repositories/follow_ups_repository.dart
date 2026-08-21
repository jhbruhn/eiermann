import 'package:eiermann_models/eiermann_models.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:zugvogel_data/zugvogel_data.dart';

/// Reads and writes `follow_ups`: the Nachkontrollen.
///
/// A member may create a MANUAL one — "look at that lock again next week" is a
/// legitimate note to the team — and the access rule pins the reason to
/// `manual`, so a hand-made row cannot claim to be a Halbgelege the rhythm
/// never saw. The `half_clutch` ones are `app_rhythm.js`'s to create, and
/// resolving any of them is a later CHECK's job: [FollowUp.resolvedAt] is
/// refused from a client, because a Nachkontrolle marked done by hand is one
/// nobody carried out.
class FollowUpsRepository extends PbRepository<FollowUp> {
  FollowUpsRepository(PocketBase pb)
    : super(
        pb: pb,
        collection: 'follow_ups',
        fromRecord: FollowUp.fromRecord,
      );

  /// A PocketBase date field that was never set stores the empty string, so
  /// "not resolved" is `resolved_at = ''` and not `resolved_at = null`.
  static const _open = "resolved_at = ''";

  /// The two relations a row needs a NAME for, not an id.
  static const _labels = 'spot,nest';

  /// Every open Nachkontrolle in the org, earliest first.
  ///
  /// This is the dashboard's top block, and it is unpaged on purpose: a group
  /// with more open half-clutch returns than a screen holds has a problem a
  /// second page would not help with. The org scope comes from the access rule,
  /// not from the filter — a client that named its own org would be asking the
  /// server to trust it.
  Future<List<FollowUp>> open() => list(
    filter: filterExpr(_open),
    sort: 'due_at',
    // Expanded, not looked up afterwards: this list spans every building, and
    // an id with no label next to it is a bug in this app. Still ONE request —
    // PocketBase resolves the relations server-side.
    expand: _labels,
  );

  /// The open Nachkontrollen of one building — the dossier's second date.
  Future<List<FollowUp>> openForSpot(String spotId) => list(
    filter: filterExpr('spot = {:spot} && $_open', {'spot': spotId}),
    sort: 'due_at',
    expand: _labels,
  );

  /// The body a manual follow-up sends. Nothing else is writable: the reason is
  /// pinned by the access rule and the resolution belongs to a check.
  static Map<String, dynamic> manualBody({
    required String spot,
    required DateTime dueAt,
    String? nest,
    String? note,
    String? org,
  }) => {
    'spot': spot,
    'due_at': dueAt.toUtc().toIso8601String(),
    'reason': FollowUpReason.manual.wire,
    'nest': ?nest,
    'note': note ?? '',
    'org': ?org,
  };
}
