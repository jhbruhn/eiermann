import 'dart:async';
import 'dart:math' as math;

import 'package:eiermann/features/home/account_menu.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spot_sheet.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/router.dart';
import 'package:eiermann/ui/app_map.dart';
import 'package:eiermann/ui/device_location.dart';
import 'package:eiermann/ui/locate_me_button.dart';
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
  final _searchController = TextEditingController();
  Timer? _searchTimer;

  /// The term the map is currently reading for — the DEBOUNCED one, never the
  /// field's live text. See [kSpotSearchDebounce]: one keystroke is one query.
  String _query = '';

  /// Show only this rank, or all of them.
  ///
  /// Screen state and deliberately not a route parameter, unlike the list's
  /// rank (`Routes.spotsByUrgency`). That one is in the URL because a dashboard
  /// tile links to it; nothing links to a filtered map, and a camera position
  /// is not in the URL either — so a location that claimed to describe this
  /// screen would describe half of it.
  SpotUrgency? _rank;

  /// Where the reader is, once they asked. Null until then: a map that showed a
  /// position nobody asked for would be tracking somebody.
  LocationFix? _me;

  /// The camera's current zoom, so the clustering can follow it.
  ///
  /// Held in state rather than read from the controller during build: the
  /// controller has no camera until the map is laid out, and a build that
  /// touched it would throw on the first frame.
  double _zoom = kMapFallbackZoom;

  @override
  void dispose() {
    _searchTimer?.cancel();
    _searchController.dispose();
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

  void _onSearchChanged(String text) {
    _searchTimer?.cancel();
    _searchTimer = Timer(kSpotSearchDebounce, () {
      if (mounted) setState(() => _query = text);
    });
  }

  /// Puts the camera where the reader is.
  ///
  /// Moves the camera and drops a marker rather than filtering the pins to a
  /// radius: "in meiner Nähe" is answered by SEEING which buildings are around
  /// you, and a radius filter would hide the one 300 metres away that is the
  /// actual reason to walk. It also has an honest failure — a refused
  /// permission leaves every pin where it was, and [LocateMeButton] says why.
  void _showMe(LocationFix fix) {
    setState(() => _me = fix);
    // After the setState, so the marker exists by the time the camera
    // arrives — moving first draws a jump to an empty patch of map.
    _map.move(LatLng(fix.lat, fix.lon), kMapPinnedZoom - 3);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final pins = ref.watch(spotsMatchingProvider(_query));
    // The rows already known, which during a search is the PREVIOUS result:
    // the chips are built from these, so they do not flicker away between
    // keystrokes. The map itself waits for the answer (below), exactly as the
    // list does.
    final known = pins.value ?? const <SpotOverview>[];
    final visible = known.where(_matchesRank).toList();
    // "No building here" is only true when nothing is narrowing the view. With
    // a search or a chip on, an empty answer means the FILTER found nothing —
    // and calling an org full of buildings empty is the one thing this screen
    // must not do.
    final unnarrowed = _query.trim().isEmpty && _rank == null;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.spotsMapTitle),
        actions: const [AccountMenu()],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: AsyncValueView(
              value: pins,
              onRetry: () => ref.invalidate(spotsMatchingProvider(_query)),
              data: (rows) => _Map(
                rows: rows.where(_matchesRank).toList(),
                me: _me,
                controller: _map,
                zoom: _zoom,
                onMapEvent: _onMapEvent,
              ),
            ),
          ),
          // The controls sit ABOVE the map's own async state, not inside it:
          // rebuilt through the loading view, the search field would lose focus
          // on every request and the reader could type one term at a time.
          Positioned(
            top: ZugvogelSpacing.sm,
            left: ZugvogelSpacing.sm,
            right: ZugvogelSpacing.sm,
            child: _Controls(
              controller: _searchController,
              onSearchChanged: _onSearchChanged,
              counts: countByUrgency(known),
              rank: _rank,
              onRank: (rank) => setState(() => _rank = rank),
              notice: _notice(l10n, known: known, visible: visible),
            ),
          ),
          if (pins.hasValue && known.isEmpty && unnarrowed)
            Center(
              child: Card(
                margin: const EdgeInsets.all(ZugvogelSpacing.lg),
                child: Padding(
                  padding: const EdgeInsets.all(ZugvogelSpacing.md),
                  child: Text(l10n.spotsEmptyTitle),
                ),
              ),
            ),
        ],
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          LocateMeButton(onFix: _showMe),
          const SizedBox(height: ZugvogelSpacing.sm),
          FloatingActionButton.extended(
            heroTag: 'add',
            onPressed: () => showSpotSheet(context),
            icon: const Icon(Icons.add),
            label: Text(l10n.spotsEmptyAction),
          ),
        ],
      ),
    );
  }

  bool _matchesRank(SpotOverview row) => _rank == null || row.level == _rank;

  /// What the map cannot show, in the order that answers the reader's question.
  ///
  /// The order is the point. An empty map has three different causes and only
  /// one of them is "there is nothing here": the chip narrowed it away, the
  /// search did, or the buildings that match have no pin. Each says so itself:
  /// a map that went quiet would read as a complete picture of the work.
  String? _notice(
    AppLocalizations l10n, {
    required List<SpotOverview> known,
    required List<SpotOverview> visible,
  }) {
    // The chip emptied it: rows came back, none of them at the selected rank.
    if (visible.isEmpty && known.isNotEmpty) return l10n.spotsFilterEmpty;
    // The search did: the server matched nothing at all.
    if (visible.isEmpty && _query.trim().isEmpty) return null;
    if (visible.isEmpty) return l10n.spotsNoMatches;
    final unpinned = visible.where((row) => row.geo == null).length;
    // Named, not hidden. Four buildings quietly missing from a map is a map
    // that lies about how much work there is.
    return unpinned > 0 ? l10n.spotsMapUnpinned(unpinned) : null;
  }
}

/// The map's controls: a search field, the rank chips, and what is not drawn.
///
/// One card over the map rather than an app-bar row, because both controls act
/// on what is UNDER them and the connection has to be visible. It is also the
/// only place a phone has room for seven chips.
class _Controls extends StatelessWidget {
  const _Controls({
    required this.controller,
    required this.onSearchChanged,
    required this.counts,
    required this.rank,
    required this.onRank,
    this.notice,
  });

  final TextEditingController controller;
  final ValueChanged<String> onSearchChanged;

  /// How many Spots sit at each rank, over the searched rows — so a chip's
  /// number always describes the set the map is drawing from.
  final Map<SpotUrgency, int> counts;

  final SpotUrgency? rank;
  final ValueChanged<SpotUrgency?> onRank;

  /// What the map cannot show: unpinned buildings, or nothing matching.
  final String? notice;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.sm),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: controller,
              onChanged: onSearchChanged,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: l10n.spotsSearchHint,
                isDense: true,
                border: const OutlineInputBorder(),
              ),
            ),
            if (counts.isNotEmpty) ...[
              const SizedBox(height: ZugvogelSpacing.sm),
              // Horizontally scrollable: there are seven ranks, and wrapping
              // them onto three lines would put the map behind the controls on
              // a phone.
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    // Ranks in their own order, most urgent first — the order
                    // the list sorts by, so the two screens read the same way.
                    for (final level in SpotUrgency.values)
                      // A chip exists for a rank that has rows — and for the
                      // SELECTED one even when it has none. Dropping it would
                      // take away the only way to switch it off: a search that
                      // matched nothing at that rank would leave the map
                      // filtered by a chip that is no longer on screen.
                      if (counts[level] ?? (rank == level ? 0 : null)
                          case final count?) ...[
                        Padding(
                          padding: const EdgeInsets.only(
                            right: ZugvogelSpacing.xs,
                          ),
                          child: FilterChip(
                            selected: rank == level,
                            avatar: Icon(
                              spotUrgencyIcon(level),
                              size: 18,
                              color: spotUrgencyColor(context, level),
                            ),
                            // The count is on the chip, so the filter says how
                            // much work it is about to show before it is
                            // tapped.
                            label: Text(
                              '${spotUrgencyLabel(l10n, level)} · $count',
                            ),
                            // Tapping the selected chip clears it. One gesture
                            // for both directions; the reader does not have to
                            // find a separate "all" chip.
                            onSelected: (selected) =>
                                onRank(selected ? level : null),
                          ),
                        ),
                      ],
                  ],
                ),
              ),
            ],
            if (notice case final line?) ...[
              const SizedBox(height: ZugvogelSpacing.xs),
              Text(line, style: theme.textTheme.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

class _Map extends StatelessWidget {
  const _Map({
    required this.rows,
    required this.me,
    required this.controller,
    required this.zoom,
    required this.onMapEvent,
  });

  /// The rows the map draws: searched on the server, then narrowed to the
  /// selected rank here. The rank is filtered locally on purpose — it is the
  /// value the view already computed and the pin is already coloured by, so a
  /// second query for it could only disagree with the colour on screen. The
  /// search is the other way round: the columns a term is tried against exist
  /// only in the view's filter, so re-implementing that match in Dart would be
  /// the second definition.
  final List<SpotOverview> rows;

  /// Where the reader is, if they asked.
  final LocationFix? me;

  final MapController controller;
  final double zoom;
  final void Function(MapEvent) onMapEvent;

  @override
  Widget build(BuildContext context) {
    // A Spot with no pin is not drawable. The count is stated by the controls
    // above rather than dropped in silence.
    final pinned = rows.where((row) => row.geo != null).toList();
    final points = pinned.map((row) => LatLng(row.geo!.lat, row.geo!.lon));
    final bounds = points.isEmpty
        ? null
        : LatLngBounds.fromPoints(points.toList());

    return FlutterMap(
      mapController: controller,
      // NOT keyed on the data. `initialCameraFit` applies once per State, so
      // re-keying on every refresh would yank the camera back to the whole city
      // each time somebody added a contact — or each time a filter chip was
      // tapped, which is the worse one: the reader loses the district they
      // panned to for asking a question about it.
      options: MapOptions(
        initialCameraFit: bounds == null ? null : appCameraFit(bounds),
        // What the tile layer loads on mount, before the fit applies. Over the
        // pins and on a whole zoom level, so those requests are not spent on
        // the wrong part of the country.
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
    );
  }

  /// One marker per cluster, which for most of the map is one marker per Spot,
  /// plus the reader's own position when they asked for it.
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
      if (me case final fix?)
        Marker(
          point: LatLng(fix.lat, fix.lon),
          width: 28,
          height: 28,
          // A dot, not a pin: it marks a point rather than a building, and the
          // difference is what keeps somebody from reading their own position
          // as a Spot nobody has recorded yet.
          child: _MeDot(),
        ),
    ];
  }
}

/// Where the reader is: a dot, with a ring so it survives a dark aerial tile.
class _MeDot extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: context.l10n.spotsMapYouAreHere,
      child: Container(
        decoration: BoxDecoration(
          color: colors.primary,
          shape: BoxShape.circle,
          border: Border.all(color: colors.surface, width: 3),
          boxShadow: const [BoxShadow(blurRadius: 3)],
        ),
      ),
    );
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
      message: '${row.name}\n${spotDueLabel(l10n, row.level, row.nextDueAt)}',
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
                    spotDueLabel(sheetContext.l10n, row.level, row.nextDueAt),
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
                  spotDueLabel(l10n, row.level, row.nextDueAt),
                  if (row.nextDueAt case final due?)
                    formatLocalDate(materialL10n, due),
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
