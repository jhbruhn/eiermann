import 'dart:async';
import 'dart:math' as math;

import 'package:eiermann/features/home/sign_out_action.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann/ui/app_map.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The map: every Spot as a pin, coloured by how overdue it is.
///
/// Reads `spot_overview` and nothing else, which is what makes it one query for
/// the whole screen. The urgency rank a pin is coloured by is computed in the
/// view's CASE expression, so a pin cannot disagree with the list row for the
/// same building.
///
/// The tile source comes from `mapConfigProvider` — the server's prescription
/// when it sends one, the build-time defines otherwise — and never from the
/// environment constants directly. A self-hosted instance gets to name its own
/// provider, and the CSP is derived from the same URLs so the server cannot
/// block what it prescribed.
class SpotsMapScreen extends ConsumerStatefulWidget {
  const SpotsMapScreen({super.key});

  @override
  ConsumerState<SpotsMapScreen> createState() => _SpotsMapScreenState();
}

class _SpotsMapScreenState extends ConsumerState<SpotsMapScreen> {
  final _map = MapController();

  /// The camera's current zoom, so the clustering can follow it.
  ///
  /// Held in state rather than read from the controller during build: the
  /// controller has no camera until the map is laid out, and a build that
  /// touched it would throw on the first frame.
  double _zoom = kMapFallbackZoom;

  @override
  void dispose() {
    _map.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    final zoom = event.camera.zoom;
    // Whole levels only. The clustering re-buckets on a change, and doing that
    // for every intermediate value of a pinch would rebuild the marker list
    // dozens of times per gesture for no visible difference.
    if (zoom.round() != _zoom.round()) setState(() => _zoom = zoom);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pins = ref.watch(allSpotsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.spotsMapTitle),
        actions: const [SignOutAction()],
      ),
      body: AsyncValueView(
        value: pins,
        onRetry: () => ref.invalidate(allSpotsProvider),
        data: (rows) => _Map(
          rows: rows,
          controller: _map,
          zoom: _zoom,
          onMapEvent: _onMapEvent,
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSpotSheet(context),
        icon: const Icon(Icons.add),
        label: Text(l10n.spotsEmptyAction),
      ),
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({
    required this.rows,
    required this.controller,
    required this.zoom,
    required this.onMapEvent,
  });

  final List<SpotOverview> rows;
  final MapController controller;
  final double zoom;
  final void Function(MapEvent) onMapEvent;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    // A Spot with no pin is not drawable, and silently dropping it would make
    // the map look complete when it is not. The count is stated instead.
    final pinned = rows.where((row) => row.geo != null).toList();
    final unpinned = rows.length - pinned.length;
    final points = pinned.map((row) => LatLng(row.geo!.lat, row.geo!.lon));
    final bounds = points.isEmpty
        ? null
        : LatLngBounds.fromPoints(points.toList());

    return Stack(
      children: [
        FlutterMap(
          mapController: controller,
          // NOT keyed on the data. `initialCameraFit` applies once per State,
          // so re-keying on every refresh would yank the camera back to the
          // whole city each time somebody added a contact — while never
          // re-framing is exactly right: a reader who panned to a district
          // stays there.
          options: MapOptions(
            initialCameraFit: bounds == null ? null : appCameraFit(bounds),
            // What the tile layer loads on mount, before the fit applies. Over
            // the pins and on a whole zoom level, so those requests are not
            // spent on the wrong part of the country.
            initialCenter: bounds?.center ?? kMapFallbackCentre,
            initialZoom: bounds == null ? kMapFallbackZoom : kMapPinnedZoom - 2,
            maxZoom: kMapMaxZoom,
            interactionOptions: const InteractionOptions(
              flags: MapWheelZoom.flags,
            ),
            onMapEvent: onMapEvent,
          ),
          children: [
            const AppMapTileLayer(),
            const MapWheelZoom(),
            MarkerLayer(markers: _markers(context)),
            const MapAttribution(),
          ],
        ),
        if (rows.isEmpty)
          Center(
            child: Card(
              margin: const EdgeInsets.all(ZugvogelSpacing.lg),
              child: Padding(
                padding: const EdgeInsets.all(ZugvogelSpacing.md),
                child: Text(l10n.spotsEmptyTitle),
              ),
            ),
          )
        else if (unpinned > 0)
          Positioned(
            top: ZugvogelSpacing.sm,
            left: ZugvogelSpacing.sm,
            right: ZugvogelSpacing.sm,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(ZugvogelSpacing.md),
                // Named, not hidden. A map that quietly omits four buildings
                // reads as a complete picture of the group's work.
                child: Text(l10n.spotsMapUnpinned(unpinned)),
              ),
            ),
          ),
      ],
    );
  }

  /// One marker per cluster, which for most of the map is one marker per Spot.
  List<Marker> _markers(BuildContext context) {
    return [
      for (final cluster in _clusters(rows, zoom))
        Marker(
          point: cluster.centre,
          width: 44,
          height: 44,
          // The tip of a pin is at its bottom, so the anchor has to be the
          // bottom centre or every Spot sits half a building too far north.
          alignment: Alignment.topCenter,
          child: cluster.rows.length == 1
              ? _SpotPin(cluster.rows.single)
              : _ClusterPin(cluster),
        ),
    ];
  }
}

/// Spots that fall in one screen-space bucket at the current zoom.
@immutable
class _Cluster {
  const _Cluster(this.centre, this.rows);

  final LatLng centre;
  final List<SpotOverview> rows;

  /// The loudest rank in the bucket — what the cluster is coloured by, because
  /// a cluster hiding one overdue building among nine tidy ones must not read
  /// as tidy.
  SpotUrgency? get worst {
    SpotUrgency? worst;
    for (final row in rows) {
      final level = row.level;
      if (level == null) continue;
      if (worst == null || level.rank < worst.rank) worst = level;
    }
    return worst;
  }
}

/// Buckets [rows] onto a grid whose cell shrinks as [zoom] grows.
///
/// Clustering here is about LEGIBILITY, not performance — a group has tens of
/// buildings, and a plain marker layer would draw them all comfortably. The
/// problem it solves is a dense old-town block: five Spots within thirty metres
/// overlap into one blob where you can neither count them nor tap the one you
/// want.
///
/// Hand-rolled rather than taken from a package on purpose. The cluster
/// packages for flutter_map have a long history of lagging its major versions,
/// and a dependency that lags is one that blocks the whole app's upgrade —
/// which is a high price for forty lines of grid arithmetic.
///
/// Two approximations, both deliberate. The grid is in degrees rather than true
/// screen space, so a cell is off by the cosine of the latitude. And a fixed
/// grid has a boundary case: two Spots a metre apart either side of a cell edge
/// stay two pins. Neither is worth fixing here — the cell only decides which
/// pins are too close to tell apart, and the failure mode of both is drawing
/// one pin too many, never hiding a building.
List<_Cluster> _clusters(List<SpotOverview> rows, double zoom) {
  // A cell of roughly 64 screen pixels, a little wider than the 44px pin: the
  // world is one 256px tile at zoom 0, so 360/256 degrees per pixel, halving
  // each level — 64 * 360 / (256 * 2^zoom), i.e. 90 / 2^zoom.
  //
  // Getting this constant wrong is silent. An earlier version used 3 instead of
  // 90, giving a five-metre cell at zoom 16, so pins eleven metres apart still
  // overlapped on screen and still drew as separate blobs — clustering that
  // only ever fired at country zoom, where nobody needs it. The test that
  // caught it is the one placing three buildings in one block.
  final cell = 90 * math.pow(0.5, zoom.clamp(1, kMapMaxZoom)).toDouble();
  final buckets = <String, List<SpotOverview>>{};
  for (final row in rows) {
    final geo = row.geo;
    if (geo == null) continue;
    final key = '${(geo.lat / cell).floor()}:${(geo.lon / cell).floor()}';
    buckets.putIfAbsent(key, () => []).add(row);
  }

  return [
    for (final bucket in buckets.values)
      _Cluster(
        // The centroid, so a cluster badge sits among its Spots rather than on
        // the corner of a grid cell nobody can see.
        LatLng(
          bucket.map((r) => r.geo!.lat).reduce((a, b) => a + b) / bucket.length,
          bucket.map((r) => r.geo!.lon).reduce((a, b) => a + b) / bucket.length,
        ),
        bucket,
      ),
  ];
}

/// One Spot's pin: the urgency colour, and the urgency icon inside it.
///
/// Colour AND shape, always. A red pin says nothing to a colour-blind reader,
/// and colour as the only carrier of meaning fails WCAG 1.4.1 — the same rule
/// the list obeys by spelling the rank out in words.
class _SpotPin extends StatelessWidget {
  const _SpotPin(this.row);

  final SpotOverview row;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colour = spotUrgencyColor(context, row.level);

    return Tooltip(
      message: '${row.name}\n${spotUrgencyLabel(l10n, row.level)}',
      child: GestureDetector(
        onTap: () => _showSpotCallout(context, row),
        child: Stack(
          alignment: Alignment.topCenter,
          children: [
            Icon(
              Icons.location_on,
              size: 40,
              color: colour,
              shadows: const [Shadow(blurRadius: 3)],
            ),
            Padding(
              padding: const EdgeInsets.only(top: 7),
              child: Icon(
                spotUrgencyIcon(row.level),
                size: 15,
                color: Theme.of(context).colorScheme.surface,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Several Spots too close together to tell apart: how many, and the loudest
/// rank among them.
class _ClusterPin extends StatelessWidget {
  const _ClusterPin(this.cluster);

  final _Cluster cluster;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colour = spotUrgencyColor(context, cluster.worst);

    return GestureDetector(
      // Opens the list rather than zooming. Zooming is a guess at how far in
      // the pins separate, and two Spots in one courtyard never do — whereas
      // the list always answers "which of these is which".
      onTap: () => _showClusterSheet(context, cluster),
      child: Container(
        decoration: BoxDecoration(
          color: colour,
          shape: BoxShape.circle,
          border: Border.all(color: theme.colorScheme.surface, width: 2),
        ),
        alignment: Alignment.center,
        child: Text(
          '${cluster.rows.length}',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.surface,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}

/// What a tapped pin says: enough to decide whether to go, and a way in.
void _showSpotCallout(BuildContext context, SpotOverview row) {
  unawaited(
    showAppSheet<void>(
      context,
      builder: (sheetContext) => Padding(
        padding: const EdgeInsets.fromLTRB(
          ZugvogelSpacing.lg,
          0,
          ZugvogelSpacing.lg,
          ZugvogelSpacing.lg,
        ),
        child: _Callout(row),
      ),
    ),
  );
}

/// The Spots in one cluster, as a list.
void _showClusterSheet(BuildContext context, _Cluster cluster) {
  unawaited(
    showAppSheet<void>(
      context,
      builder: (sheetContext) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.only(bottom: ZugvogelSpacing.lg),
          children: [
            for (final row in cluster.rows)
              ListTile(
                leading: Icon(
                  spotUrgencyIcon(row.level),
                  color: spotUrgencyColor(sheetContext, row.level),
                ),
                title: Text(row.name),
                subtitle: Text(
                  [
                    spotUrgencyLabel(sheetContext.l10n, row.level),
                    ?row.addressLine,
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(sheetContext.push(Routes.spotDetail(row.id)));
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _Callout extends StatelessWidget {
  const _Callout(this.row);

  final SpotOverview row;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final materialL10n = MaterialLocalizations.of(context);

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(row.name, style: theme.textTheme.titleLarge),
        if (row.addressLine case final address?) ...[
          const SizedBox(height: ZugvogelSpacing.xs),
          Text(
            address,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        const SizedBox(height: ZugvogelSpacing.sm),
        Row(
          children: [
            Icon(
              spotUrgencyIcon(row.level),
              size: 18,
              color: spotUrgencyColor(context, row.level),
            ),
            const SizedBox(width: ZugvogelSpacing.xs),
            Expanded(
              child: Text(
                [
                  spotUrgencyLabel(l10n, row.level),
                  if (row.nextDueAt case final due?)
                    l10n.spotDueOn(formatLocalDate(materialL10n, due)),
                ].join(' · '),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: spotUrgencyColor(context, row.level),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: ZugvogelSpacing.xs),
        Row(
          children: [
            TagChip(label: spotPhaseLabel(l10n, row.phase)),
            const SizedBox(width: ZugvogelSpacing.sm),
            Text(
              l10n.spotContactCount(row.contactCount),
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
        // Whether a PERSON confirmed the pin, not whether one exists. The map
        // is exactly where this matters: a guessed pin on the wrong side of a
        // courtyard is what sends somebody to the wrong door.
        if (!row.geoConfirmed) ...[
          const SizedBox(height: ZugvogelSpacing.xs),
          Text(
            l10n.spotPinUnconfirmed,
            style: theme.textTheme.bodySmall?.copyWith(
              color: context.zvColors.warning,
            ),
          ),
        ],
        const SizedBox(height: ZugvogelSpacing.md),
        PrimaryButton(
          label: l10n.spotsMapOpenAction,
          icon: Icons.arrow_forward,
          onPressed: () {
            Navigator.of(context).pop();
            unawaited(context.push(Routes.spotDetail(row.id)));
          },
        ),
      ],
    );
  }
}
