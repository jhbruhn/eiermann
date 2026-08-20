import 'package:eiermann/config/app_environment.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart';

export 'package:zugvogel_pb_client/zugvogel_pb_client.dart'
    show MapConfig, MapMode, ServerMapConfig, mapConfigProvider;

/// The build-time map defaults from `dart_defines/<flavor>.json`.
///
/// Only the FALLBACK: the server may prescribe a source through
/// `/api/eiermann/info`, and that wins. Read the effective values through
/// `mapConfigProvider`, never from here.
MapConfig mapConfigFromDefines() {
  final mode = AppEnvironment.mapMode;
  return MapConfig(
    mode: mode,
    url: mode == MapMode.raster
        ? AppEnvironment.mapTileUrl
        : AppEnvironment.mapStyleUrl,
    attribution: AppEnvironment.mapAttribution,
    attributionUrl: AppEnvironment.mapAttributionUrl.isEmpty
        ? null
        : AppEnvironment.mapAttributionUrl,
    // No define counterpart on purpose: the shipped default provider needs no
    // key, and the defines files are committed — a key does not belong there.
  );
}
