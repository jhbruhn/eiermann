import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Asks which building to add, and returns it — or null if the sheet was
/// dismissed.
///
/// [exclude] are the ids already on the list. They are hidden rather than shown
/// as disabled rows: on a route of twelve stops, greyed-out entries would be
/// most of what the picker shows, and the reader is looking for the one that is
/// missing.
Future<SpotOverview?> showTourSpotPicker(
  BuildContext context, {
  required Set<String> exclude,
  String? title,
}) {
  return showAppSheet<SpotOverview>(
    context,
    builder: (_) => TourSpotPicker(exclude: exclude, title: title),
  );
}

/// Pick one building.
///
/// Reads `spot_overview` through [spotsMatchingProvider], which is the same
/// query the list and the map use — so "matches" means one thing in this app,
/// and it is the server's definition. A Dart reimplementation over the loaded
/// rows would drift from the columns a search term is actually tried against.
///
/// The empty query is free: it delegates to the unpaged read the map and the
/// dashboard already hold.
class TourSpotPicker extends ConsumerStatefulWidget {
  const TourSpotPicker({required this.exclude, this.title, super.key});

  final Set<String> exclude;
  final String? title;

  @override
  ConsumerState<TourSpotPicker> createState() => _TourSpotPickerState();
}

class _TourSpotPickerState extends ConsumerState<TourSpotPicker> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final rows = ref.watch(spotsMatchingProvider(_query));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          ZugvogelSpacing.lg,
          0,
          ZugvogelSpacing.lg,
          ZugvogelSpacing.lg,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title ?? l10n.tourStopAddTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: ZugvogelSpacing.md),
            // No save button: choosing a row IS the action, and a confirm step
            // would add a tap to something already unambiguous. Which is also
            // why this is not a `SheetScaffold` — that one is built around a
            // form with a save.
            AppTextField(
              controller: _search,
              label: l10n.tourStopSearchLabel,
              prefixIcon: Icons.search,
              autofocus: true,
              onChanged: _onSearchChanged,
            ),
            const SizedBox(height: ZugvogelSpacing.md),
            // A fixed height, because a sheet whose body grows with the result
            // set jumps under the reader's thumb between keystrokes.
            SizedBox(
              height: 320,
              child: AsyncValueView(
                value: rows,
                onRetry: () => ref.invalidate(spotsMatchingProvider(_query)),
                data: (all) {
                  final offer = all
                      .where((spot) => !widget.exclude.contains(spot.id))
                      .toList();
                  if (offer.isEmpty) {
                    return EmptyView(
                      icon: Icons.home_work_outlined,
                      message: l10n.tourStopAddNothingLeft,
                    );
                  }
                  return ListView.builder(
                    itemCount: offer.length,
                    itemBuilder: (_, index) {
                      final spot = offer[index];
                      final level = spot.level;
                      return ListTile(
                        leading: Icon(
                          level == null
                              ? Icons.home_work_outlined
                              : spotUrgencyIcon(level),
                        ),
                        title: Text(spot.name),
                        subtitle: spot.addressLine == null
                            ? null
                            : Text(spot.addressLine!),
                        onTap: () => Navigator.of(context).pop(spot),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Debounced with the constant both other searching screens use, so "has the
  /// reader stopped typing" has ONE answer in this app. The guard compares the
  /// field's text rather than counting timers: a keystroke during the wait
  /// leaves the earlier callback to fire and do nothing.
  void _onSearchChanged(String value) {
    Future<void>.delayed(kSpotSearchDebounce, () {
      if (!mounted || _search.text != value) return;
      setState(() => _query = value);
    });
  }
}
