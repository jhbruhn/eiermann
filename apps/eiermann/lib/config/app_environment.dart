import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

export 'package:zugvogel_pb_client/zugvogel_pb_client.dart' show MapMode;

/// Build-time application configuration.
///
/// Values are injected via `--dart-define-from-file=dart_defines/<flavor>.json`
/// and read here through `String.fromEnvironment`. Because these are
/// compile-time constants they are tree-shaken and safe to reference anywhere.
///
/// They are also, therefore, NOT configuration a self-hoster can change: they
/// are baked into the web bundle and the APK. Anything an operator must be able
/// to repoint is prescribed by the server through `/api/eiermann/info` instead
/// — the map source is the standing example (see `mapMode` and friends, which
/// are only the fallback).
enum AppFlavor { development, staging, production }

abstract final class AppEnvironment {
  /// Raw flavor name from the `FLAVOR` define (defaults to development so a
  /// bare `flutter run` without a defines file still works).
  static const String flavorName = String.fromEnvironment(
    'FLAVOR',
    defaultValue: 'development',
  );

  static AppFlavor get flavor => switch (flavorName) {
    'production' => AppFlavor.production,
    'staging' => AppFlavor.staging,
    _ => AppFlavor.development,
  };

  static bool get isProduction => flavor == AppFlavor.production;

  /// Human-facing app name for the current flavor (e.g. `[DEV] Eiermann`).
  static const String appName = String.fromEnvironment(
    'APP_NAME',
    defaultValue: 'Eiermann',
  );

  /// Optional build-time PocketBase base URL.
  ///
  /// Mainly a dev/web convenience. At runtime the base URL is resolved per
  /// platform: on web from the app's own serving origin, on native from the
  /// user-configured server URL. When this override is non-empty it seeds that
  /// resolution.
  static const String pocketbaseUrlOverride = String.fromEnvironment(
    'POCKETBASE_URL',
  );

  static bool get hasPocketbaseUrlOverride => pocketbaseUrlOverride.isNotEmpty;

  // The MAP_* defines below are only the FALLBACK map source. The server can
  // prescribe one at runtime through `/api/eiermann/info` — it has to be able
  // to, since these constants are baked into the web bundle and the APK and are
  // not configuration at all on a published image. Read the effective values
  // through `mapConfigProvider`, never from here directly.

  static const String mapModeName = String.fromEnvironment(
    'MAP_MODE',
    defaultValue: 'raster',
  );

  /// Which map rendering path the spot map uses.
  ///
  /// `raster` (the default) draws a classic `{z}/{x}/{y}.png` tile server as
  /// plain images. `vector` renders a MapLibre style through
  /// `vector_map_tiles`, which rasterizes on the Dart canvas with no GPU path —
  /// cheaper to host, worse frame rate and label quality.
  static MapMode get mapMode => switch (mapModeName) {
    'vector' => MapMode.vector,
    _ => MapMode.raster,
  };

  static const String mapStyleUrl = String.fromEnvironment(
    'MAP_STYLE_URL',
    defaultValue: 'https://tiles.openfreemap.org/styles/liberty',
  );

  /// Raster tile URL template. Defaults to the public OSM tile server.
  ///
  /// The OSM Tile Usage Policy does not really cover an application backend, so
  /// an operator with more than a handful of users is expected to repoint this
  /// (`EIERMANN_MAP_TILE_URL` on the server, no rebuild needed). What the app
  /// owes the policy either way it already does: it identifies itself in the
  /// tile layer's user agent, caches tiles on disk, and never bulk-prefetches.
  static const String mapTileUrl = String.fromEnvironment(
    'MAP_TILE_URL',
    defaultValue: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
  );

  static const String mapAttribution = String.fromEnvironment(
    'MAP_ATTRIBUTION',
    defaultValue: '© OpenStreetMap contributors',
  );

  static const String mapAttributionUrl = String.fromEnvironment(
    'MAP_ATTRIBUTION_URL',
    defaultValue: 'https://www.openstreetmap.org/copyright',
  );
}
