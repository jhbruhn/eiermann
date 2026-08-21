import 'package:flutter/widgets.dart';
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
