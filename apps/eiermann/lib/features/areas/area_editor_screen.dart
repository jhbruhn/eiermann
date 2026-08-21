import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/features/nests/nest_sheet.dart';
import 'package:eiermann/features/nests/nests_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The Bereich editor: the overview photo with its nest pins, placed and moved
/// by hand.
///
/// Tap the photo to add a nest where you tapped. Drag a pin to correct it.
/// Tap a pin to open the nest. A nest that has no pin yet is listed under the
/// photo and gets placed by selecting it and then tapping — invisible nests
/// would make the photo look like the whole picture when it is not.
class AreaEditorScreen extends ConsumerWidget {
  const AreaEditorScreen({required this.areaId, super.key});

  final String areaId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final area = ref.watch(areaProvider(areaId));

    return Scaffold(
      appBar: AppBar(title: Text(area.value?.name ?? l10n.areasTitle)),
      body: AsyncValueView(
        value: area,
        onRetry: () => ref.invalidate(areaProvider(areaId)),
        data: (loaded) => _Editor(area: loaded),
      ),
    );
  }
}

class _Editor extends ConsumerStatefulWidget {
  const _Editor({required this.area});

  final Area area;

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  /// The nest waiting to be placed by the next tap, if any.
  ///
  /// Selecting first and tapping second, rather than dragging off the strip: a
  /// drag from a list into a photo needs both visible at once, which a phone in
  /// a stairwell cannot promise.
  String? _placing;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final area = widget.area;

    if (!area.hasPhoto) {
      // Nothing to pin ON. The way out of this state is the photo, so that is
      // what this offers — not a disabled pin tool.
      // Scrollable, not a centred Column: the photo box is 16:10 of the whole
      // width, and on a short window that plus the sentence under it does not
      // fit — measured as a 10px overflow in a test window.
      return ListView(
        padding: const EdgeInsets.all(ZugvogelSpacing.lg),
        children: [
          AreaPhoto(area: area),
          const SizedBox(height: ZugvogelSpacing.md),
          Text(l10n.areaPhotoMissingHint, textAlign: TextAlign.center),
        ],
      );
    }

    // Read only once there is a photo: with nothing to pin on there is nothing
    // to draw, and a request whose answer cannot be shown is a request nobody
    // asked for.
    final nests = ref.watch(nestsForAreaProvider(area.id));

    return AsyncValueView(
      value: nests,
      onRetry: () => ref.invalidate(nestsForAreaProvider(area.id)),
      data: (rows) {
        final unpinned = rows.where((nest) => !nest.hasPin).toList();
        return ListView(
          padding: const EdgeInsets.all(ZugvogelSpacing.md),
          children: [
            Text(
              _placing == null
                  ? l10n.areaEditorHint
                  : l10n.areaEditorPlacingHint(
                      rows.firstWhere((nest) => nest.id == _placing).label,
                    ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            PinCanvas(
              // The photo is passed IN rather than built here, which is what
              // makes the coordinate maths testable: a widget test can hand
              // this a box of a known size, where a network image never
              // resolves and the canvas would have no height to divide by.
              photo: AreaPhoto(area: area, showAsCanvas: true),
              nests: rows,
              onTap: _onTap,
              onMoved: _onMoved,
              onOpen: (nest) =>
                  showNestSheet(context, areaId: area.id, nest: nest),
            ),
            if (unpinned.isNotEmpty) ...[
              const SizedBox(height: ZugvogelSpacing.md),
              Text(
                l10n.areaEditorUnpinned(unpinned.length),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: ZugvogelSpacing.sm),
              Wrap(
                spacing: ZugvogelSpacing.sm,
                runSpacing: ZugvogelSpacing.sm,
                children: [
                  for (final nest in unpinned)
                    ChoiceChip(
                      selected: _placing == nest.id,
                      avatar: Icon(
                        nestSpeciesIcon(nest.species),
                        size: 18,
                        color: nestSpeciesColor(context, nest.species),
                      ),
                      label: Text(nest.label),
                      onSelected: (selected) => setState(
                        () => _placing = selected ? nest.id : null,
                      ),
                    ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }

  /// A tap on the photo: place the selected nest, or make a new one there.
  Future<void> _onTap(({double x, double y}) at) async {
    final placing = _placing;
    if (placing != null) {
      setState(() => _placing = null);
      await _persist(placing, at);
      return;
    }
    final rows = ref.read(nestsForAreaProvider(widget.area.id)).value ?? [];
    if (!mounted) return;
    // The pin travels INTO the sheet rather than being written first: a row
    // created before the sheet is confirmed would leave an unnamed nest behind
    // when somebody backs out.
    await showNestSheet(
      context,
      areaId: widget.area.id,
      pin: at,
      suggestedLabel: suggestNestLabel(rows),
    );
  }

  Future<void> _onMoved(Nest nest, ({double x, double y}) to) =>
      _persist(nest.id, to);

  Future<void> _persist(String nestId, ({double x, double y}) at) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final repo = await ref.read(nestsRepositoryProvider.future);
      await repo.movePin(nestId, x: at.x, y: at.y);
    } on Object catch (error, stackTrace) {
      if (error is! RepositoryException) {
        reportCaughtError(error, stackTrace, context: 'move pin $nestId');
      }
      messenger.showSnackBar(
        SnackBar(content: Text(errorMessage(EiermannStrings(l10n), error))),
      );
    }
    // Re-read either way: on success to pick up the stored (clamped) value, and
    // on failure to drop the local position the drag was showing — a pin left
    // where the finger was would claim a move the server refused.
    invalidateNestViews(ref);
  }
}

/// The photo with its pins, and the gestures that place them.
///
/// The image sizes itself from its own aspect ratio — width from the parent,
/// height from the picture — so the box IS the image rect. That is what makes
/// the coordinate maths exact: with `BoxFit.contain` inside a box of some other
/// shape, the letterbox bars would be part of the box and every pin would sit
/// slightly off.
class PinCanvas extends StatefulWidget {
  const PinCanvas({
    required this.photo,
    required this.nests,
    required this.onTap,
    required this.onMoved,
    required this.onOpen,
    super.key,
  });

  /// The picture the pins sit on. It sizes the canvas: width from the parent,
  /// height from the image.
  final Widget photo;

  final List<Nest> nests;
  final void Function(({double x, double y}) at) onTap;
  final void Function(Nest nest, ({double x, double y}) to) onMoved;
  final void Function(Nest nest) onOpen;

  @override
  State<PinCanvas> createState() => _PinCanvasState();
}

class _PinCanvasState extends State<PinCanvas> {
  /// Measured at gesture time rather than passed in: the height comes from the
  /// image's own aspect ratio, so nothing above this widget knows it.
  final GlobalKey _canvas = GlobalKey();

  /// Where a pin currently being dragged sits, so it follows the finger before
  /// anything is written.
  final Map<String, ({double x, double y})> _dragging = {};

  /// How far the pin sat from the finger when the drag began, in normalised
  /// units. Kept so grabbing a pin by its edge does not snap it under the
  /// fingertip — the pin moves WITH the hand rather than jumping to it.
  final Map<String, ({double dx, double dy})> _grab = {};

  RenderBox? get _box {
    final box = _canvas.currentContext?.findRenderObject();
    return box is RenderBox && box.hasSize && !box.size.isEmpty ? box : null;
  }

  /// A global position as a fraction of the canvas, unclamped.
  ///
  /// Absolute rather than accumulated from drag deltas, and that is the whole
  /// reason it takes a global position: a pan recogniser swallows the movement
  /// it needed to recognise the gesture (the touch slop), so a pin built out of
  /// deltas arrives up to ~18 logical pixels behind the finger and stays there.
  /// Measured — the first test of this dragged 60px and the pin moved 30.
  ({double x, double y})? _fraction(Offset global) {
    final box = _box;
    if (box == null) return null;
    final local = box.globalToLocal(global);
    return (x: local.dx / box.size.width, y: local.dy / box.size.height);
  }

  /// The same, clamped into the range a pin may be written at.
  ({double x, double y})? _normalise(Offset global) {
    final at = _fraction(global);
    if (at == null) return null;
    return (x: normalisePin(at.x), y: normalisePin(at.y));
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        key: _canvas,
        children: [
          // Sizes the Stack: width from the parent, height from the image.
          widget.photo,
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) {
                final at = _normalise(details.globalPosition);
                if (at != null) widget.onTap(at);
              },
            ),
          ),
          for (final nest in widget.nests)
            if (_dragging[nest.id] ?? nest.pin case final at?)
              // `Positioned.fill` around the alignment, and it is load-bearing:
              // a bare `Align` is a NON-positioned child, so it would size the
              // Stack — expanding it to the whole available height and leaving
              // every pin measured against a box taller than the photo. Found
              // by a test that dragged 20px down and watched the pin move 10.
              // Positioned children do not size a Stack; the photo stays the
              // only thing that does.
              Positioned.fill(
                child: Align(
                  alignment: Alignment(at.x * 2 - 1, at.y * 2 - 1),
                  child: _Pin(
                    nest: nest,
                    onTap: () => widget.onOpen(nest),
                    onDragStart: (global) {
                      final finger = _fraction(global);
                      if (finger == null) return;
                      _grab[nest.id] = (
                        dx: at.x - finger.x,
                        dy: at.y - finger.y,
                      );
                    },
                    onDragTo: (global) {
                      final finger = _fraction(global);
                      final grab = _grab[nest.id];
                      if (finger == null || grab == null) return;
                      setState(
                        () => _dragging[nest.id] = (
                          x: normalisePin(finger.x + grab.dx),
                          y: normalisePin(finger.y + grab.dy),
                        ),
                      );
                    },
                    onDrop: () {
                      _grab.remove(nest.id);
                      final moved = _dragging.remove(nest.id);
                      if (moved != null) widget.onMoved(nest, moved);
                    },
                  ),
                ),
              ),
        ],
      ),
    );
  }
}

/// One pin: the nest's label, in its species' colour, with the species' icon.
///
/// The label is on the pin rather than in a legend, because the whole point of
/// the photo is standing in an attic and matching what you see to what the app
/// says. A legend means looking away.
class _Pin extends StatelessWidget {
  const _Pin({
    required this.nest,
    required this.onTap,
    required this.onDragStart,
    required this.onDragTo,
    required this.onDrop,
  });

  final Nest nest;
  final VoidCallback onTap;

  /// Both carry a GLOBAL position, because the canvas is the only thing that
  /// can turn one into a coordinate on the photo. [onDragStart] fires on
  /// touch-DOWN — see the gesture detector below for why that matters.
  final ValueChanged<Offset> onDragStart;
  final ValueChanged<Offset> onDragTo;

  final VoidCallback onDrop;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final colour = nestSpeciesColor(context, nest.species);
    // The contrast colour follows the theme, exactly as the map's pins do — a
    // literal white would be a hole in the palette in dark mode, and a sweep
    // test catches those.
    final onColour = Theme.of(context).colorScheme.surface;

    return GestureDetector(
      onTap: onTap,
      // `onPanDown`, not `onPanStart`: a pan is only RECOGNISED once the touch
      // has travelled the slop distance, so a grab measured at that moment has
      // already absorbed those ~18 logical pixels and the pin trails the finger
      // by them for the rest of the drag. Measured: a 60px drag moved the pin
      // 30px. Touch-down is the only moment the finger and the pin are where
      // the user thinks they are.
      onPanDown: (details) => onDragStart(details.globalPosition),
      // `onPanStart` moves the pin too, not just `onPanUpdate`: the movement
      // that RECOGNISED the pan arrives as the start and produces no update of
      // its own, so a fast flick — one move event, then the finger up — would
      // otherwise end with the pin never having moved at all.
      onPanStart: (details) => onDragTo(details.globalPosition),
      onPanUpdate: (details) => onDragTo(details.globalPosition),
      onPanEnd: (_) => onDrop(),
      child: Semantics(
        button: true,
        label: '${nest.label} · ${nestSpeciesLabel(l10n, nest.species)}',
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: ZugvogelSpacing.sm,
            vertical: ZugvogelSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: colour,
            borderRadius: BorderRadius.circular(999),
            // A photo of an attic is a field of browns and greys with no
            // guaranteed contrast anywhere, so the pin brings its own edge
            // rather than relying on what it happens to sit on.
            border: Border.all(color: onColour, width: 2),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(nestSpeciesIcon(nest.species), size: 14, color: onColour),
              const SizedBox(width: ZugvogelSpacing.xs),
              Text(
                nest.label,
                style: TextStyle(
                  color: onColour,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
