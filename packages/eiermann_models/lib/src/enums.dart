import 'package:zugvogel_core/zugvogel_core.dart';

/// A team member's role (`users.role`).
///
/// Two roles, not four: this is a small team where everybody does the field
/// work. See `RolePermissions` in the app for what each may do.
enum UserRole implements WireEnum {
  /// Walks the tour and records what they found.
  member('member'),

  /// Additionally decides the things that are hard to undo — deleting a Spot,
  /// overriding a rhythm, taking a nest out of `protected`, managing the team.
  coordinator('coordinator');

  const UserRole(this.wire);

  @override
  final String wire;

  static UserRole? fromWire(Object? v) => wireEnum(values, v);
}

/// Where a Spot is in its life (`spots.phase`).
enum SpotPhase implements WireEnum {
  /// Erkundung: somebody has seen the building but there is no permission yet.
  prospect('prospect'),

  /// In the rhythm — visited, checked, counted.
  active('active'),

  /// Deliberately out of the rhythm for a while: scaffolding, winter, a
  /// caretaker on holiday. Drops out of every due list.
  paused('paused'),

  /// Done with, and why is recorded — netted, permission withdrawn, building
  /// gone, no pigeons.
  closed('closed');

  const SpotPhase(this.wire);

  @override
  final String wire;

  static SpotPhase? fromWire(Object? v) => wireEnum(values, v);
}

/// How far the Erkundung got (`spots.prospect_stage`).
///
/// Stays set after the Spot goes active: the history of how permission was
/// obtained is part of the dossier, and losing it is how the same conversation
/// gets had twice.
enum ProspectStage implements WireEnum {
  untouched('untouched'),
  tenantSpoken('tenant_spoken'),
  ownerSpoken('owner_spoken'),
  permitted('permitted'),
  refused('refused');

  const ProspectStage(this.wire);

  @override
  final String wire;

  static ProspectStage? fromWire(Object? v) => wireEnum(values, v);
}

/// Why a Spot was closed (`spots.closed_reason`).
///
/// Mandatory when closing, because "closed" without a reason is the state
/// nobody can act on later: [netted] and [buildingGone] mean never come back,
/// while [permissionWithdrawn] and [noPigeons] are the two a conversation can
/// reopen.
enum ClosedReason implements WireEnum {
  /// The ledges were netted — the building is out of the method's reach.
  netted('netted'),

  /// The owner side took the permission back.
  permissionWithdrawn('permission_withdrawn'),

  /// The building is gone.
  buildingGone('building_gone'),

  /// Nothing nesting there after all.
  noPigeons('no_pigeons');

  const ClosedReason(this.wire);

  @override
  final String wire;

  static ClosedReason? fromWire(Object? v) => wireEnum(values, v);
}

/// Who a contact person is to the building (`spot_contacts.role`).
enum ContactRole implements WireEnum {
  owner('owner'),
  management('management'),

  /// The Hausmeister — in practice the one number that gets somebody in.
  caretaker('caretaker'),
  tenant('tenant'),
  other('other');

  const ContactRole(this.wire);

  @override
  final String wire;

  static ContactRole? fromWire(Object? v) => wireEnum(values, v);
}

/// The `spot_overview.urgency` ladder, named.
///
/// Not a [WireEnum]: the server does not store this, it computes it in the
/// view's CASE expression, and the number is what the list sorts and pages by.
/// The names exist so the screen that renders it switches exhaustively instead
/// of over bare integers — a rank the app has no name for must be visible as
/// such, not silently drawn as "in Rhythmus".
enum SpotUrgency {
  /// A due date in the past.
  overdue(0),
  dueToday(1),
  dueThisWeek(2),

  /// Active and not due yet — including an active Spot with no due date at
  /// all, which is waiting for its first nest rather than overdue.
  inRhythm(3),

  /// Needs a conversation, not a visit.
  prospect(4),
  paused(5),
  closed(6);

  const SpotUrgency(this.rank);

  /// The integer the view emits, and the key the list is ordered by.
  final int rank;

  static SpotUrgency? fromRank(int? rank) {
    for (final value in values) {
      if (value.rank == rank) return value;
    }
    return null;
  }
}

/// The `nest_state.urgency` ladder, named.
///
/// Not a [WireEnum]: the server computes it in the view's CASE expression, and
/// the number is what the nest list sorts by. Two rungs are not about dates at
/// all — see the view's own header for why they sit where they do.
enum NestUrgency {
  /// A due date in the past.
  overdue(0),
  dueToday(1),
  dueThisWeek(2),

  /// Active and not due yet — including a nest that has never been checked,
  /// which is waiting rather than late.
  inRhythm(3),

  /// A protected species. Below every actionable date on purpose: every egg
  /// mutation on such a nest is refused server-side, so a due date on it
  /// describes nothing anybody may act on. It keeps a rank of its own rather
  /// than dropping out of the list — a jackdaw in the attic is exactly what the
  /// next person needs to see before they go up there.
  protectedSpecies(4),

  /// Gone. Recorded history rather than work; a nest is never deleted, because
  /// a nest that disappeared is information about the building.
  gone(5);

  const NestUrgency(this.rank);

  /// The integer the view emits, and the key the list is ordered by.
  final int rank;

  static NestUrgency? fromRank(int? rank) {
    for (final value in values) {
      if (value.rank == rank) return value;
    }
    return null;
  }
}

/// What a nest holds, biologically (`nests.species`).
///
/// The way INTO [protected] is open to everybody — seeing a protected species
/// and saying so must never be gated. The way out is a coordinator's, because
/// it re-enables egg removal on that nest.
enum NestSpecies implements WireEnum {
  feralPigeon('feral_pigeon'),

  /// A protected species. Every egg mutation on this nest is refused
  /// server-side, on every path.
  protected('protected'),

  /// Not yet identified. Treated as workable — an unknown is a question, not a
  /// prohibition.
  unknown('unknown');

  const NestSpecies(this.wire);

  @override
  final String wire;

  static NestSpecies? fromWire(Object? v) => wireEnum(values, v);
}

/// Whether a nest is still there (`nests.status`).
enum NestStatus implements WireEnum {
  active('active'),

  /// Gone — the nest itself, not its eggs. A cleared ledge, a sealed gap.
  gone('gone');

  const NestStatus(this.wire);

  @override
  final String wire;

  static NestStatus? fromWire(Object? v) => wireEnum(values, v);
}

/// What is in an egg slot (`nest_eggs.kind`).
enum EggKind implements WireEnum {
  /// A real egg. What the work is there to replace.
  real('real'),

  /// An Attrappe — a dummy the birds keep brooding, which is the whole method.
  dummy('dummy');

  const EggKind(this.wire);

  @override
  final String wire;

  static EggKind? fromWire(Object? v) => wireEnum(values, v);
}

/// What happened at a nest (`nest_checks.state`).
enum CheckState implements WireEnum {
  /// Every real egg replaced by a dummy.
  swapped('swapped'),

  /// THE Halbgelege: after the swap a real egg is still in the nest. Creates a
  /// Nachkontrolle, because coming back in a few days is the whole point.
  partial('partial'),

  /// Nothing in the nest. The only state that advances the rhythm ladder.
  empty('empty'),

  /// Something there, deliberately left alone.
  untouched('untouched'),

  /// Could not get to the nest at all.
  notReachable('not_reachable'),

  /// The nest is gone.
  gone('gone'),

  /// A protected species is nesting. Recorded, never touched.
  protected('protected');

  const CheckState(this.wire);

  @override
  final String wire;

  static CheckState? fromWire(Object? v) => wireEnum(values, v);
}

/// How a Besuch ended (`visits.outcome`).
enum VisitOutcome implements WireEnum {
  checked('checked'),

  /// Nobody there, no key, no time. A skipped visit does NOT enter the rhythm:
  /// it documents a non-event, not the observation of an empty nest.
  skipped('skipped');

  const VisitOutcome(this.wire);

  @override
  final String wire;

  static VisitOutcome? fromWire(Object? v) => wireEnum(values, v);
}

/// Why a Nachkontrolle exists (`follow_ups.reason`).
enum FollowUpReason implements WireEnum {
  /// A Halbgelege — the automatic one.
  halfClutch('half_clutch'),

  /// Somebody asked for it.
  manual('manual');

  const FollowUpReason(this.wire);

  @override
  final String wire;

  static FollowUpReason? fromWire(Object? v) => wireEnum(values, v);
}

/// What was found (`findings.kind`).
enum FindingKind implements WireEnum {
  deadBird('dead_bird'),
  chick('chick'),
  otherSpecies('other_species'),

  /// The building changed in a way that matters — netting, scaffolding, a new
  /// lock. Offers "close this Spot" as a follow-up action.
  siteChange('site_change');

  const FindingKind(this.wire);

  @override
  final String wire;

  static FindingKind? fromWire(Object? v) => wireEnum(values, v);
}
