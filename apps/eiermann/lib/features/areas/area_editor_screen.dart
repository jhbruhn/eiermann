import 'dart:async';

import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/areas/area_photo.dart';
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
              nests: PinnedNest.fromNests(rows),
              onTap: _onTap,
              onMoved: (pin, to) => _persist(pin.id, to),
              onOpen: (pin) => showNestSheet(
                context,
                areaId: area.id,
                nest: rows.firstWhere((nest) => nest.id == pin.id),
              ),
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
      suggestedLabel: suggestNestLabel(rows.map((nest) => nest.label)),
    );
  }

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
