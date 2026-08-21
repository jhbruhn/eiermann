import 'package:eiermann/features/nests/nest_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// One pin, as the canvas needs it: a position, a caption and a species.
///
/// Its own small type rather than either model, because both feed it — the
/// editor draws `nests` rows, the dossier draws `nest_state` rows — and a
/// canvas that knew one of them would have to know both. Callers map back to
/// their own row by [id].
@immutable
class PinnedNest {
  const PinnedNest({
    required this.id,
    required this.label,
    required this.at,
    this.species,
  });

  /// The pinned nests among [nests], mapped through the shared pin rule.
  ///
  /// An unpinned nest is left OUT rather than drawn at (0, 0): that corner is
  /// what the wire cannot tell from "no pin", and putting a marker there would
  /// claim a position nobody chose.
  static List<PinnedNest> fromNests(List<Nest> nests) => [
    for (final nest in nests)
      if (nest.pin case final at?)
        PinnedNest(
          id: nest.id,
          label: nest.label,
          at: at,
          species: nest.species,
        ),
  ];

  /// The same, from the view the dossier reads.
  static List<PinnedNest> fromStates(List<NestState> nests) => [
    for (final nest in nests)
      if (nest.pin case final at?)
        PinnedNest(
          id: nest.id,
          label: nest.label,
          at: at,
          species: nest.species,
        ),
  ];

  final String id;
  final String label;
  final ({double x, double y}) at;
  final NestSpecies? species;
}

/// The photo with its pins — read-only on the dossier, interactive in the
/// editor.
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
    this.onTap,
    this.onMoved,
    this.onOpen,
    this.dense = false,
    super.key,
  });

  /// The picture the pins sit on. It sizes the canvas: width from the parent,
  /// height from the image.
  final Widget photo;

  final List<PinnedNest> nests;

  /// Where an empty spot was tapped. Null makes the canvas read-only: no
  /// gesture layer is installed at all, so a tap falls through to whatever the
  /// caller wrapped this in — on the dossier, the card's own way into the
  /// editor.
  final void Function(({double x, double y}) at)? onTap;

  /// A pin was dragged somewhere. Null leaves the pins fixed.
  final void Function(PinnedNest nest, ({double x, double y}) to)? onMoved;

  /// A pin was tapped. Null makes the pins non-interactive — which is what the
  /// dossier wants: the lines under the photo are the tappable version, and a
  /// pin that swallowed the tap would break the way into the editor.
  final void Function(PinnedNest nest)? onOpen;

  /// Smaller pins, for a preview rather than a working surface.
  final bool dense;

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
    final placing = widget.onTap;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        key: _canvas,
        children: [
          // Sizes the Stack: width from the parent, height from the image.
          widget.photo,
          if (placing != null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (details) {
                  final at = _normalise(details.globalPosition);
                  if (at != null) placing(at);
                },
              ),
            ),
          for (final nest in widget.nests)
            if (_dragging[nest.id] ?? nest.at case final at)
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
                    dense: widget.dense,
                    // A pin nobody may move or open takes no part in hit
                    // testing at all, so the tap reaches what is behind it.
                    interactive:
                        widget.onOpen != null || widget.onMoved != null,
                    onTap: () => widget.onOpen?.call(nest),
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
                      if (moved != null) widget.onMoved?.call(nest, moved);
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
    required this.interactive,
    required this.dense,
    required this.onTap,
    required this.onDragStart,
    required this.onDragTo,
    required this.onDrop,
  });

  final PinnedNest nest;

  /// Whether this pin answers gestures. A read-only pin is wrapped in an
  /// [IgnorePointer]: it is a picture of where the nest is, and the tap belongs
  /// to whatever the canvas sits in.
  final bool interactive;

  /// Smaller type and tighter padding, for a preview.
  final bool dense;
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

    final pin = GestureDetector(
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
          padding: EdgeInsets.symmetric(
            horizontal: dense ? ZugvogelSpacing.xs : ZugvogelSpacing.sm,
            vertical: dense ? 1 : ZugvogelSpacing.xs,
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
              Icon(
                nestSpeciesIcon(nest.species),
                size: dense ? 11 : 14,
                color: onColour,
              ),
              const SizedBox(width: ZugvogelSpacing.xs),
              Text(
                nest.label,
                style: TextStyle(
                  color: onColour,
                  fontWeight: FontWeight.bold,
                  fontSize: dense ? 10 : 12,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return interactive ? pin : IgnorePointer(child: pin);
  }
}
