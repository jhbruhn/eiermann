import 'package:eiermann/features/species/species_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// A free-text Artbezeichnung with suggestions from what has already been
/// recorded.
///
/// **The field is the answer; the suggestions are a shortcut.** The app does
/// not identify species — it asks the person standing in front of the nest — so
/// anything typed here is valid, including a word nobody has used before. That
/// is what makes the vocabulary grow: `species_labels` is a view over the
/// DISTINCT values actually recorded, per org, so today's new spelling is
/// tomorrow's suggestion. There is nothing to seed and nothing to maintain, and
/// nothing dead in the list.
///
/// The price is stated under the field rather than engineered away: two
/// spellings are two entries. A normaliser that folded "Turmfalke" into
/// "Turmfalken" would eventually fold two species together, and nobody would
/// notice — so nothing normalises behind the user's back.
///
/// The suggestions are drawn as CHIPS below the field rather than as a dropdown
/// overlay, for two reasons that both come from where this gets used: a chip is
/// a finger-sized target on a phone held one-handed in a stairwell, and a list
/// that is simply visible tells somebody what this group has recorded — itself
/// worth knowing before typing.
///
/// A read that is still loading or has FAILED renders no chips, and nothing
/// else. The field keeps working, because it must: somebody looking at a dead
/// jackdaw cannot be blocked from writing "Dohle" by a list that could not
/// load.
class SpeciesLabelField extends StatelessWidget {
  const SpeciesLabelField({
    required this.controller,
    required this.label,
    this.enabled = true,
    this.hint,
    this.onPicked,
    super.key,
  });

  final TextEditingController controller;
  final String label;
  final bool enabled;

  /// The sentence under the field. Null keeps the default, which names the
  /// price of a vocabulary that grows from use.
  final String? hint;

  /// Called when a SUGGESTION was tapped.
  ///
  /// Needed because a chip writes the controller directly, and a programmatic
  /// write does not reach the enclosing [Form] — so `Form.onChanged`, which is
  /// what marks a sheet dirty, never fires. Without this the discard guard
  /// would let somebody leave a sheet whose species they had just picked.
  final VoidCallback? onPicked;

  /// How many suggestions are offered at once.
  ///
  /// A cap and not a scroll: past a handful, scanning chips is slower than
  /// typing the next letter, and the next letter narrows the list. Six fits two
  /// rows on a phone.
  static const _maxSuggestions = 6;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppTextField(
          controller: controller,
          label: label,
          prefixIcon: Icons.pets_outlined,
          enabled: enabled,
          textCapitalization: TextCapitalization.sentences,
        ),
        // Rebuilt from the CONTROLLER, which is the only home the typed text
        // has: the caller owns it, prefills it and reads it back. Mirroring it
        // into state of its own would give one string two homes and a moment
        // where they disagree.
        ValueListenableBuilder(
          valueListenable: controller,
          builder: (_, value, _) => _Suggestions(
            typed: value.text,
            enabled: enabled,
            max: _maxSuggestions,
            onPick: (match) {
              controller.text = match;
              // The caret goes to the END, not to offset zero, which is where a
              // bare `text =` leaves it: the next keystroke would otherwise
              // type in front of the word somebody just picked.
              controller.selection = TextSelection.collapsed(
                offset: match.length,
              );
              onPicked?.call();
            },
          ),
        ),
        const SizedBox(height: ZugvogelSpacing.xs),
        Text(
          hint ?? l10n.speciesLabelHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// The matching suggestions, or nothing at all.
class _Suggestions extends ConsumerWidget {
  const _Suggestions({
    required this.typed,
    required this.enabled,
    required this.max,
    required this.onPick,
  });

  final String typed;
  final bool enabled;
  final int max;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // `.value`, so a loading or failed read renders nothing rather than an
    // error banner or a spinner. The field above it is the part that matters,
    // and it works either way.
    final rows = ref.watch(speciesLabelsProvider).value;
    if (rows == null) return const SizedBox.shrink();

    final needle = typed.trim().toLowerCase();
    final matches = [
      for (final row in rows)
        if (row.label.isNotEmpty &&
            row.label.toLowerCase().contains(needle) &&
            // The exact word already typed is not a suggestion — tapping it
            // would do nothing, and a chip that does nothing reads as broken.
            row.label.toLowerCase() != needle)
          row.label,
    ];
    if (matches.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: ZugvogelSpacing.sm),
      child: Wrap(
        spacing: ZugvogelSpacing.sm,
        runSpacing: ZugvogelSpacing.xs,
        children: [
          for (final match in matches.take(max))
            ActionChip(
              label: Text(match),
              onPressed: enabled ? () => onPick(match) : null,
            ),
        ],
      ),
    );
  }
}
