import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/app_map.dart';
import 'package:eiermann/ui/device_location.dart';
import 'package:eiermann/ui/locate_me_button.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// What the picker came back with.
@immutable
class PickedPin {
  const PickedPin(this.point, this.resolved);

  final GeoPoint point;

  /// The address the geocoder gave for this pin, when it gave one. Offered so
  /// the form can show what was matched — never written over what somebody
  /// typed.
  final GeoResult? resolved;
}

/// Opens the map so somebody can put the pin on the actual door.
///
/// [initial] seeds the centre; [searchSeed] pre-fills the search box, so
/// arriving from a form that already has an address means one tap rather than
/// retyping it.
Future<PickedPin?> showSpotPinPicker(
  BuildContext context, {
  GeoPoint? initial,
  String? searchSeed,
}) {
  return Navigator.of(context).push<PickedPin>(
    MaterialPageRoute(
      builder: (_) => SpotPinPicker(initial: initial, searchSeed: searchSeed),
      fullscreenDialog: true,
    ),
  );
}

/// Place or correct a Spot's pin by moving the map under a fixed crosshair.
///
/// The pin does not move; the map does. On a phone held one-handed in a
/// stairwell, dragging a marker means covering it with a thumb and letting go
/// where you cannot see — whereas panning under a fixed centre keeps the target
/// visible the whole time.
///
/// Confirming is deliberately NOT gated on the reverse geocode succeeding, and
/// that is a divergence from federfall's picker. Here the pin is the answer and
/// the address is commentary: a courtyard entrance behind a block may have no
/// address of its own, and an unreachable geocoder must not stop somebody who
/// is standing at the door from recording where it is.
class SpotPinPicker extends ConsumerStatefulWidget {
  const SpotPinPicker({this.initial, this.searchSeed, super.key});

  final GeoPoint? initial;
  final String? searchSeed;

  @override
  ConsumerState<SpotPinPicker> createState() => _SpotPinPickerState();
}

class _SpotPinPickerState extends ConsumerState<SpotPinPicker> {
  final _map = MapController();
  late final _search = TextEditingController(text: widget.searchSeed ?? '');

  late LatLng _centre;
  GeoResult? _resolved;
  List<GeoResult> _candidates = const [];
  bool _searched = false;
  bool _searching = false;
  bool _reversing = false;
  String? _error;

  /// Monotonic id of the newest reverse lookup. A response for a centre the map
  /// has since left is dropped rather than applied — otherwise a slow answer
  /// arrives after a fast one and labels the new pin with the old address.
  int _resolveSeq = 0;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _centre = initial == null
        ? kMapFallbackCentre
        : LatLng(initial.lat, initial.lon);
    if (initial != null) {
      // Resolve what is already under the pin, so a correction starts by saying
      // where the pin currently is rather than showing a blank strip.
      WidgetsBinding.instance.addPostFrameCallback((_) => _resolveCentre());
    } else {
      // A NEW Spot is nearly always being recorded from the pavement in front
      // of it, so start there rather than over the middle of Germany at zoom 5.
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => unawaited(_startAtMe()),
      );
    }
  }

  /// Opens the map on the device's position — but only if it may.
  ///
  /// [DeviceLocation.currentIfPermitted] and never `current()`: opening a
  /// screen is not asking, and a system permission dialog on top of a map
  /// somebody merely navigated to is a question they did not pose. Without the
  /// permission this quietly leaves [kMapFallbackCentre] where it is.
  ///
  /// A failure is silent for the same reason — there is no refusal to report to
  /// somebody who did not ask. Only [LocateMeButton] explains itself.
  ///
  /// Correcting an existing pin never gets here (see [initState]): that pin is
  /// the statement being corrected, and where the phone happens to be standing
  /// is not an improvement on it.
  Future<void> _startAtMe() async {
    final LocationFix? fix;
    try {
      fix = await ref.read(deviceLocationProvider).currentIfPermitted();
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'pin picker auto-locate');
      return;
    }
    if (fix == null || !mounted) return;
    _moveTo(fix);
  }

  /// Camera to [fix], then resolve what landed under the crosshair.
  ///
  /// The resolve is the part that is easy to forget: the fix moves the CAMERA,
  /// and what gets taken is still whatever sits under the crosshair when
  /// somebody presses confirm. Without it the address strip would stay on "no
  /// address" until the first pan — a blank line under a map that is already
  /// showing the right building.
  void _moveTo(LocationFix fix) {
    // The same height the spot map uses for "mein Standort": close enough to
    // pick out a building, wide enough that a fix off by a few dozen metres
    // still has the right one on screen.
    _centreOn(LatLng(fix.lat, fix.lon), kMapPinnedZoom - 3);
  }

  /// Drives the camera AND the state that describes it.
  ///
  /// Both halves, always, because only a gesture reports back: flutter_map
  /// emits `MapEventMoveEnd` when a drag ends and nothing at all for a
  /// programmatic [MapController.move], so [_onMapEvent] never sees one. A
  /// caller that moved the camera and left [_centre] alone would leave the
  /// picker describing — and on confirm, RETURNING — the place it used to be
  /// looking at. That is how a tap on the map used to work.
  void _centreOn(LatLng target, double zoom) {
    _centre = target;
    _map.move(target, zoom);
    unawaited(_resolveCentre());
  }

  @override
  void dispose() {
    _search.dispose();
    _map.dispose();
    super.dispose();
  }

  void _onMapEvent(MapEvent event) {
    // Only when the movement ENDS. Resolving during a drag would fire a request
    // per frame at a rate-limited third party.
    if (event is MapEventMoveEnd) {
      _centre = event.camera.center;
      unawaited(_resolveCentre());
    }
  }

  /// Reverse-geocodes the current centre for the strip at the bottom.
  ///
  /// A failure clears the address rather than keeping the last one: an address
  /// paired with coordinates it does not belong to is worse than no address,
  /// because it reads as confirmation.
  Future<void> _resolveCentre() async {
    final seq = ++_resolveSeq;
    setState(() {
      _reversing = true;
      _error = null;
    });
    try {
      final repo = await ref.read(geocodingRepositoryProvider.future);
      final result = await repo.reverse(_centre.latitude, _centre.longitude);
      if (!mounted || seq != _resolveSeq) return;
      setState(() {
        _reversing = false;
        _resolved = result;
      });
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'reverse geocode');
      if (!mounted || seq != _resolveSeq) return;
      setState(() {
        _reversing = false;
        _resolved = null;
        _error = _message(error);
      });
    }
  }

  Future<void> _runSearch() async {
    final query = _search.text.trim();
    if (query.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _searched = true;
      _error = null;
    });
    try {
      final repo = await ref.read(geocodingRepositoryProvider.future);
      final results = await repo.forward(query);
      if (!mounted) return;
      setState(() {
        _searching = false;
        _candidates = results;
      });
      // One hit is not a choice. Going straight there saves a tap and is what
      // happens for a well-formed street address nine times out of ten.
      if (results.length == 1) _goTo(results.single);
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'forward geocode');
      if (!mounted) return;
      setState(() {
        _searching = false;
        _candidates = const [];
        _error = _message(error);
      });
    }
  }

  String _message(Object error) => error is RepositoryException
      ? errorMessage(EiermannStrings(context.l10n), error)
      : context.l10n.errorGenericTitle;

  void _goTo(GeoResult result) {
    setState(() {
      _candidates = const [];
      _resolved = result;
    });
    _centre = LatLng(result.lat, result.lon);
    _map.move(_centre, kMapPinnedZoom);
  }

  void _confirm() {
    Navigator.of(context).pop(
      PickedPin(
        GeoPoint(lat: _centre.latitude, lon: _centre.longitude),
        _resolved,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.spotPinPickerTitle)),
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: _centre,
              initialZoom: widget.initial == null
                  ? kMapFallbackZoom
                  : kMapPinnedZoom,
              maxZoom: kMapMaxZoom,
              interactionOptions: const InteractionOptions(
                flags: MapWheelZoom.flags,
              ),
              onMapEvent: _onMapEvent,
              // A tap centres rather than dropping a pin: the crosshair is the
              // pin, so a second way to place one would be two answers to the
              // same question.
              onTap: (_, point) => _centreOn(point, kMapPinnedZoom),
            ),
            children: const [
              AppMapTileLayer(),
              MapWheelZoom(),
              MapAttribution(),
            ],
          ),
          const IgnorePointer(child: _Crosshair()),
          Positioned(
            top: ZugvogelSpacing.sm,
            left: ZugvogelSpacing.sm,
            right: ZugvogelSpacing.sm,
            child: _SearchBar(
              controller: _search,
              busy: _searching,
              candidates: _candidates,
              searched: _searched,
              error: _error,
              onSubmit: _runSearch,
              onSelect: _goTo,
            ),
          ),
          // The button and the strip in ONE bottom-anchored column, rather
          // than the button as the Scaffold's `floatingActionButton`.
          //
          // Both of the Scaffold's obvious slots are already occupied on this
          // screen: the default bottom-right corner is the address strip, whose
          // confirm button is the one control that ends the screen, and
          // `endTop` lands the FAB inside the full-width search card — measured
          // at 336..384 x 80..128 against a card of 8..392 x 64..136, right on
          // top of the search arrow. A column stacks the two instead of
          // guessing an offset, so the button rides up when the strip grows a
          // second line.
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              // The button hugs the right edge; the strip below it still spans
              // the full width.
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Padding(
                  padding: const EdgeInsets.only(
                    right: ZugvogelSpacing.md,
                    bottom: ZugvogelSpacing.sm,
                  ),
                  child: LocateMeButton(
                    heroTag: 'pin-picker-locate',
                    onFix: _moveTo,
                  ),
                ),
                _AddressStrip(
                  resolved: _resolved,
                  reversing: _reversing,
                  onConfirm: _confirm,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The pin, fixed at the centre of the screen.
class _Crosshair extends StatelessWidget {
  const _Crosshair();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.location_on,
            size: 44,
            color: theme.colorScheme.error,
            // A dark outline, because a red pin over a red-roofed building is
            // invisible and the tiles are not ours to recolour.
            shadows: const [Shadow(blurRadius: 4)],
          ),
          // The tip of the icon is not its centre, so the dot marks the point
          // that is actually being chosen.
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              color: theme.colorScheme.error,
              shape: BoxShape.circle,
              border: Border.all(color: theme.colorScheme.onError),
            ),
          ),
          // Balances the icon's height so the dot sits on the true centre.
          const SizedBox(height: 44),
        ],
      ),
    );
  }
}

/// Address search, and the candidates it found.
class _SearchBar extends StatelessWidget {
  const _SearchBar({
    required this.controller,
    required this.busy,
    required this.candidates,
    required this.searched,
    required this.error,
    required this.onSubmit,
    required this.onSelect,
  });

  final TextEditingController controller;
  final bool busy;
  final List<GeoResult> candidates;
  final bool searched;
  final String? error;
  final VoidCallback onSubmit;
  final ValueChanged<GeoResult> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Card(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(ZugvogelSpacing.sm),
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: l10n.spotPinSearchHint,
                prefixIcon: const Icon(Icons.search),
                border: InputBorder.none,
                suffixIcon: busy
                    ? const Padding(
                        padding: EdgeInsets.all(ZugvogelSpacing.sm),
                        child: SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : IconButton(
                        icon: const Icon(Icons.arrow_forward),
                        tooltip: l10n.spotPinSearchAction,
                        onPressed: onSubmit,
                      ),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          if (error case final message?)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ZugvogelSpacing.md,
                0,
                ZugvogelSpacing.md,
                ZugvogelSpacing.sm,
              ),
              child: Text(
                message,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            )
          else if (searched && !busy && candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(
                ZugvogelSpacing.md,
                0,
                ZugvogelSpacing.md,
                ZugvogelSpacing.sm,
              ),
              // Not an error: plenty of buildings a group cares about are not
              // in a geocoder, and the crosshair still works.
              child: Text(
                l10n.spotPinSearchNoMatch,
                style: theme.textTheme.bodySmall,
              ),
            ),
          if (candidates.isNotEmpty)
            ConstrainedBox(
              // Capped so the list cannot cover the whole map it is meant to
              // help read.
              constraints: const BoxConstraints(maxHeight: 220),
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final candidate in candidates)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined),
                      title: Text(
                        candidate.displayName.isEmpty
                            ? l10n.spotPinCoordinates(
                                candidate.lat.toStringAsFixed(5),
                                candidate.lon.toStringAsFixed(5),
                              )
                            : candidate.displayName,
                      ),
                      subtitle: candidate.region.isEmpty
                          ? null
                          : Text(candidate.region),
                      onTap: () => onSelect(candidate),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// What is under the pin, and the button that takes it.
class _AddressStrip extends StatelessWidget {
  const _AddressStrip({
    required this.resolved,
    required this.reversing,
    required this.onConfirm,
  });

  final GeoResult? resolved;
  final bool reversing;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final address = resolved?.displayName ?? '';

    return Card(
      margin: const EdgeInsets.all(ZugvogelSpacing.sm),
      child: Padding(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              switch (true) {
                _ when reversing => l10n.spotPinResolving,
                _ when address.isNotEmpty => address,
                // No address is a normal outcome here, not a failure — a
                // courtyard door may not have one. Say so rather than leaving
                // the line blank.
                _ => l10n.spotPinNoAddress,
              },
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: ZugvogelSpacing.md),
            PrimaryButton(
              label: l10n.spotPinConfirmAction,
              icon: Icons.check,
              // Never disabled by a failed lookup: the pin is the answer and
              // the address is commentary. Somebody standing at the door has to
              // be able to record where it is with the geocoder down.
              onPressed: onConfirm,
            ),
          ],
        ),
      ),
    );
  }
}
