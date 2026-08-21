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

/// The read-only view behind the Spot list and the map.
///
/// A separate provider from [spotsRepository] rather than a method on it,
/// because the type is the guard: `PbReadOnlyRepository` has no `create`, so a
/// write against a PocketBase view cannot be spelled at all.
@Riverpod(keepAlive: true)
Future<SpotOverviewRepository> spotOverviewRepository(Ref ref) async =>
    SpotOverviewRepository(await _client(ref));
