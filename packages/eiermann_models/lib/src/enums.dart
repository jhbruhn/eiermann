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
