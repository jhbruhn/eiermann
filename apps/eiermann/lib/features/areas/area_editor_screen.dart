import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_photo.dart';
import 'package:eiermann/features/areas/area_pin_review.dart';
import 'package:eiermann/features/areas/areas_providers.dart';
import 'package:eiermann/features/areas/pin_canvas.dart';
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

  /// The nests confirmed or moved so far in the review pass.
  ///
  /// Client-side, and it has to be: confirming a pin that already sits right
  /// writes nothing, so there is no server state to hold. An interrupted
  /// pass is therefore started over — which loses nothing, because the flag
  /// and the old photo both survive the interruption. The alternative was a
  /// per-nest "reviewed" column that exists only to record that somebody
  /// looked.
  final Set<String> _reviewed = {};

  /// The pins as they stood when the pass opened, for the outgoing photo.
  ///
  /// Snapshotted, because that picture's whole value is showing the position
  /// being corrected: read live, it would show each correction the moment it
  /// was made and there would be nothing left to compare against.
  List<PinnedNest>? _before;

  bool _finishing = false;

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
        final reviewing = area.pinsNeedReview;
        // Assigned in build rather than in a setState, because it IS the
        // build's input: the snapshot has to be the positions this frame drew
        // before any of them was dragged. It triggers no rebuild of its own.
        final before = reviewing
            ? _before ??= PinnedNest.fromNests(rows)
            : const <PinnedNest>[];

        final canvas = PinCanvas(
          // The photo is passed IN rather than built here, which is what
          // makes the coordinate maths testable: a widget test can hand
          // this a box of a known size, where a network image never
          // resolves and the canvas would have no height to divide by.
          photo: AreaPhoto(area: area, showAsCanvas: true),
          nests: PinnedNest.fromNests(rows),
          // No new nest during the pass. `null` also removes the gesture layer
          // entirely, so a tap cannot land anywhere it would be ignored — a
          // dead tap reads as a broken screen.
          onTap: reviewing ? null : _onTap,
          onMoved: (pin, to) => _persist(pin.id, to),
          onOpen: (pin) => showNestSheet(
            context,
            areaId: area.id,
            nest: rows.firstWhere((nest) => nest.id == pin.id),
          ),
        );

        if (reviewing) {
          return ListView(
            padding: const EdgeInsets.all(ZugvogelSpacing.md),
            children: [
              AreaPinReview(
                area: area,
                nests: rows,
                before: before,
                canvas: canvas,
                reviewed: _reviewed,
                isFinishing: _finishing,
                onConfirm: (id) => setState(() => _reviewed.add(id)),
                onFinish: _finish,
              ),
            ],
          );
        }

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
            canvas,
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
      suggestedLabel: suggestNestLabel(rows.map((nest) => nest.label)),
    );
  }

  /// Ends the review pass, and only then forgets it was running.
  ///
  /// The local ticks are dropped on success alone: cleared on a failed write,
  /// somebody would walk the whole pass again because a stairwell lost the
  /// connection.
  Future<void> _finish() async {
    setState(() => _finishing = true);
    final done = await finishPinReview(context, ref, area: widget.area);
    if (!mounted) return;
    setState(() {
      _finishing = false;
      if (done) {
        _reviewed.clear();
        _before = null;
      }
    });
  }

  Future<void> _persist(String nestId, ({double x, double y}) at) async {
    // A dragged pin IS a reviewed pin — it was just placed against the new
    // photo, which is the whole thing the pass asks for. Marked before the
    // write: the tick describes what the volunteer did, and a refused write
    // shows its own message.
    setState(() => _reviewed.add(nestId));
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
