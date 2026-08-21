import 'package:eiermann_data/eiermann_data.dart';
import 'package:pocketbase/pocketbase.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

part 'repository_providers.g.dart';

/// The configured client. Every repository below hangs off this one await, so
/// switching servers rebuilds all of them at once.
Future<PocketBase> _client(Ref ref) => ref.watch(pocketBaseProvider.future);

@Riverpod(keepAlive: true)
Future<AuthRepository> authRepository(Ref ref) async =>
    AuthRepository(await _client(ref));

@Riverpod(keepAlive: true)
Future<SpotsRepository> spotsRepository(Ref ref) async =>
    SpotsRepository(await _client(ref));

/// Address ⇄ coordinate lookups, through this app's own proxy route.
///
/// The interface type, not the implementation: a screen that took
/// `PbGeocodingRepository` would be a screen a test can only fake by standing
/// up a PocketBase client.
@Riverpod(keepAlive: true)
Future<GeocodingRepository> geocodingRepository(Ref ref) async =>
    PbGeocodingRepository(await _client(ref));

@Riverpod(keepAlive: true)
Future<SpotContactsRepository> spotContactsRepository(Ref ref) async =>
    SpotContactsRepository(await _client(ref));

/// The Bereiche of a building — and with them the overview photos the nest
/// pins sit on.
@Riverpod(keepAlive: true)
Future<AreasRepository> areasRepository(Ref ref) async =>
    AreasRepository(await _client(ref));

/// The nests: the pins on those photos, and the rows the rhythm runs on.
@Riverpod(keepAlive: true)
Future<NestsRepository> nestsRepository(Ref ref) async =>
    NestsRepository(await _client(ref));

/// The read-only view behind the nest list: a nest plus what is in it.
///
/// A separate provider from [nestsRepository] rather than a method on it,
/// because the type is the guard — `PbReadOnlyRepository` has no `create`, so a
/// write against a PocketBase view cannot be spelled at all.
@Riverpod(keepAlive: true)
Future<NestStateRepository> nestStateRepository(Ref ref) async =>
    NestStateRepository(await _client(ref));

/// The vocabulary behind every Artbezeichnung field: what this org has actually
/// called the birds it has seen.
///
/// Read-only by type, and that IS the feature — the list grows by being used,
/// and "add a species" is a compile error rather than a curated list somebody
/// has to maintain. `keepAlive` because it is read from three sheets and
/// changes only when a visit is written.
@Riverpod(keepAlive: true)
Future<SpeciesLabelsRepository> speciesLabelsRepository(Ref ref) async =>
    SpeciesLabelsRepository(await _client(ref));

/// The read-only view behind the Spot list and the map.
///
/// A separate provider from [spotsRepository] rather than a method on it,
/// because the type is the guard: `PbReadOnlyRepository` has no `create`, so a
/// write against a PocketBase view cannot be spelled at all.
@Riverpod(keepAlive: true)
Future<SpotOverviewRepository> spotOverviewRepository(Ref ref) async =>
    SpotOverviewRepository(await _client(ref));

/// The Ist-Gelege of one nest, slot by slot.
///
/// Read-only by type, and the collection has no write rule at all: the only
/// writer is the visit endpoint, which rewrites the whole row set from the
/// outcome of a check. The dossier's nest list does not use this — it reads the
/// counts off `nest_state` in one query — so what hangs off it is the egg-slot
/// row of ONE nest, where each slot needs its own age.
@Riverpod(keepAlive: true)
Future<NestEggsRepository> nestEggsRepository(Ref ref) async =>
    NestEggsRepository(await _client(ref));

/// The transactional visit endpoint. Not a collection repository, because
/// `visits` has no create rule: there is no per-record path to writing a visit.
@Riverpod(keepAlive: true)
Future<VisitsRepository> visitsRepository(Ref ref) async =>
    VisitsRepository(await _client(ref));

/// The route templates: "Tour 1" as a shared name and identity.
@Riverpod(keepAlive: true)
Future<ToursRepository> toursRepository(Ref ref) async =>
    ToursRepository(await _client(ref));

/// The ordered stops of a route.
///
/// Its own repository rather than a method on [toursRepository], because
/// `tour_spots` is its own collection with its own rules — only `sort_index` is
/// editable, so a stop cannot be quietly re-pointed at another building.
@Riverpod(keepAlive: true)
Future<TourStopsRepository> tourStopsRepository(Ref ref) async =>
    TourStopsRepository(await _client(ref));

/// One walking of a route — including the improvised one, which has no
/// template at all.
@Riverpod(keepAlive: true)
Future<TourRunsRepository> tourRunsRepository(Ref ref) async =>
    TourRunsRepository(await _client(ref));

/// The READ side of `visits`.
///
/// Separate from [visitsRepository] because the collection has no create rule:
/// the endpoint above is the only writer, and this type has no write methods at
/// all. A round's progress is these rows and nothing else — there is no
/// per-stop progress table.
@Riverpod(keepAlive: true)
Future<VisitLogRepository> visitLogRepository(Ref ref) async =>
    VisitLogRepository(await _client(ref));

/// The Nachkontrollen — the second date that beats the rhythm.
@Riverpod(keepAlive: true)
Future<FollowUpsRepository> followUpsRepository(Ref ref) async =>
    FollowUpsRepository(await _client(ref));
