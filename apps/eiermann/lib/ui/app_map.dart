import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart' as zv;

/// eiermann's tile layer: the shared one, plus this app's own identity.
///
/// The identity is required rather than defaulted in zugvogel, and that is the
/// point — a shared package that answered for it would have every Zugvogel app
/// identify itself as the same one in tile requests, which the OSM Tile Usage
/// Policy is specifically about. Wrapped here so the string is written once
/// instead of at every map.
class AppMapTileLayer extends StatelessWidget {
  const AppMapTileLayer({super.key});

  /// The application id, matching the Android `applicationId`.
  static const String userAgentPackageName = 'de.jhbruhn.eiermann';

  @override
  Widget build(BuildContext context) =>
      const zv.MapTileLayer(userAgentPackageName: userAgentPackageName);
}

/// Where a map starts with nothing to frame: Germany, wide.
///
/// Wide on purpose. A tight zoom over an arbitrary city would put a crosshair
/// on a plausible-looking building somebody could confirm by reflex; at this
/// zoom it is visibly on nothing, so the only sensible next move is to search.
const LatLng kMapFallbackCentre = LatLng(51.2, 10.4);
const double kMapFallbackZoom = 5;

/// Close enough to tell two entrances of one building apart, which is what
/// placing a Spot's pin is actually about.
const double kMapPinnedZoom = 18;

/// The raster tile pyramid ends here. Past it flutter_map only magnifies the
/// last real tiles, so allowing more zoom buys blur.
const double kMapMaxZoom = 19;

/// Framing for a set of pins, with the two guards this needs to be given.
///
/// `forceIntegerZoomLevel` is not cosmetic: a raster tile is pixel-exact only
/// on an integer zoom. Off one, `TileLayer` fetches `zoom.round()` and draws
/// each 256px tile at `256 * 2^(zoom - round(zoom))` — between 71% and 141% of
/// native — so a fitted zoom of 8.37 renders the whole map through a resample.
/// Invisible on a phone's 3x screen, glaring at devicePixelRatio 1.
///
/// The `maxZoom` guards a degenerate fit: `CameraFit.bounds` divides the
/// viewport by the bounds' pixel size, so a single pin — or two Spots recorded
/// at the same coordinates — gives a zero-size bounds, an infinite scale and a
/// zoom of `double.infinity`.
CameraFit appCameraFit(LatLngBounds bounds) => CameraFit.bounds(
  bounds: bounds,
  padding: const EdgeInsets.all(zv.ZugvogelSpacing.xl),
  maxZoom: kMapPinnedZoom - 2,
  forceIntegerZoomLevel: true,
);
