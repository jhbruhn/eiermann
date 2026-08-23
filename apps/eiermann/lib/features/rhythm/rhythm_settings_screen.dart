import 'dart:async';

import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/rhythm/rhythm_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The numbers every due date in this app comes out of.
///
/// **This screen is why the numbers live in `organisations.settings` and not in
/// the hook.** A group that finds seven days too often over winter changes a
/// field; nobody builds an image and nobody waits for a release. Without a
/// screen the JSON field would be a worse constant — one an operator has to
/// open a database to see.
///
/// It writes through `PATCH /api/eiermann/rhythm` and never touches the
/// `organisations` record: `updateRule` there is null, and putting the only
/// JSON field in this database behind a form as raw JSON is how a malformed
/// blob silently disables every configurable window. The route takes five typed
/// numbers and checks each one, so the worst this screen can produce is a
/// refusal with a code, and never a database in a state nobody chose.
///
/// A member may read it. The intervals explain the dates every member acts on,
/// and a number you are told to trust but never shown is a number people
/// override. Only the coordination may change them — the server's rule too.
class RhythmSettingsScreen extends ConsumerWidget {
  const RhythmSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final settings = ref.watch(rhythmSettingsProvider);
    final mayEdit =
        ref.watch(currentUserProvider).value?.role?.canAdminister ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.rhythmSettingsTitle)),
      body: AsyncValueView(
        value: settings,
        onRetry: () => ref.invalidate(rhythmSettingsProvider),
        // Keyed on the loaded values so that a re-read after a save rebuilds
        // the form state rather than leaving the controllers on what was typed
        // — which is how a normalised value goes unnoticed.
        data: (loaded) => _Form(
          key: ValueKey(loaded),
          settings: loaded,
          mayEdit: mayEdit,
        ),
      ),
    );
  }
}

class _Form extends ConsumerStatefulWidget {
  const _Form({required this.settings, required this.mayEdit, super.key});

  final RhythmSettings settings;
  final bool mayEdit;

  @override
  ConsumerState<_Form> createState() => _FormState();
}

class _FormState extends ConsumerState<_Form> {
  final _formKey = GlobalKey<FormState>();

  late final _base = TextEditingController(
    text: '${widget.settings.baseIntervalDays}',
  );
  late final _perStep = TextEditingController(
    text: '${widget.settings.emptyChecksPerStep}',
  );
  late final _halfClutch = TextEditingController(
    text: '${widget.settings.halfClutchReturnDays}',
  );

  /// The ladder, as a working list. Edited rung by rung rather than as a
  /// comma-separated string: a text field holding "7, 14, 28" is a second
  /// parser, and the one thing this screen must not do is invent a second way
  /// of reading these numbers.
  late List<int> _steps = List.of(widget.settings.intervalSteps);

  late bool _autoResume = widget.settings.pauseAutoResume;

  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _base.dispose();
    _perStep.dispose();
    _halfClutch.dispose();
    super.dispose();
  }

  int get _baseValue => int.tryParse(_base.text.trim()) ?? 0;

  Future<void> _save() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final repo = await ref.read(rhythmRepositoryProvider.future);
      await repo.save(
        RhythmSettings(
          baseIntervalDays: _baseValue,
          emptyChecksPerStep: int.tryParse(_perStep.text.trim()) ?? 0,
          intervalSteps: _steps,
          halfClutchReturnDays: int.tryParse(_halfClutch.text.trim()) ?? 0,
          pauseAutoResume: _autoResume,
        ),
      );
      // Invalidate rather than adopting the answer locally: everything else
      // that explains a due date reads the same provider, and a screen holding
      // a newer copy than the app around it is the drift this whole design is
      // arranged against.
      ref.invalidate(rhythmSettingsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.l10n.rhythmSaved)));
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'rhythm settings');
      if (!mounted) return;
      setState(
        () => _error = error is RepositoryException
            ? errorMessage(EiermannStrings(context.l10n), error)
            : context.l10n.errorGenericTitle,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final strings = EiermannStrings(l10n);
    final enabled = widget.mayEdit && !_busy;

    return Form(
      key: _formKey,
      child: ListView(
        padding: const EdgeInsets.all(ZugvogelSpacing.md),
        children: [
          // What the numbers DO, before what they are. A settings screen that
          // opens with four fields makes somebody guess at the model; this is
          // the one place the ladder gets explained in full.
          Card(
            child: Padding(
              padding: const EdgeInsets.all(ZugvogelSpacing.md),
              child: Text(
                l10n.rhythmExplainer,
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ),
          if (!widget.mayEdit) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            // Shown rather than hidden: the intervals explain the dates every
            // member acts on. A number you are told to trust but never shown is
            // a number people override.
            Text(
              l10n.rhythmReadOnlyHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: ZugvogelSpacing.lg),
          _DaysField(
            controller: _base,
            label: l10n.rhythmBaseLabel,
            helper: l10n.rhythmBaseHelp,
            enabled: enabled,
            strings: strings,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: ZugvogelSpacing.lg),
          _Ladder(
            steps: _steps,
            base: _baseValue,
            enabled: enabled,
            onChanged: (steps) => setState(() => _steps = steps),
          ),
          const SizedBox(height: ZugvogelSpacing.lg),
          _DaysField(
            controller: _perStep,
            label: l10n.rhythmPerStepLabel,
            helper: l10n.rhythmPerStepHelp,
            enabled: enabled,
            strings: strings,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: ZugvogelSpacing.lg),
          _DaysField(
            controller: _halfClutch,
            label: l10n.rhythmHalfClutchLabel,
            helper: l10n.rhythmHalfClutchHelp,
            enabled: enabled,
            strings: strings,
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: ZugvogelSpacing.lg),
          SwitchListTile(
            value: _autoResume,
            onChanged: enabled
                ? (value) => setState(() => _autoResume = value)
                : null,
            title: Text(l10n.rhythmAutoResumeLabel),
            subtitle: Text(l10n.rhythmAutoResumeHelp),
            contentPadding: EdgeInsets.zero,
          ),
          if (_error case final message?) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            Text(
              message,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
          if (widget.mayEdit) ...[
            const SizedBox(height: ZugvogelSpacing.lg),
            PrimaryButton(
              label: l10n.actionSave,
              icon: Icons.check,
              isLoading: _busy,
              onPressed: _busy ? null : () => unawaited(_save()),
            ),
          ],
        ],
      ),
    );
  }
}

/// A whole number of days.
class _DaysField extends StatelessWidget {
  const _DaysField({
    required this.controller,
    required this.label,
    required this.helper,
    required this.enabled,
    required this.strings,
    required this.onChanged,
  });

  final TextEditingController controller;
  final String label;
  final String helper;
  final bool enabled;
  final EiermannStrings strings;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      enabled: enabled,
      keyboardType: TextInputType.number,
      // Digits only at the keyboard, so the server's "that is not a number"
      // refusal is a race and not a normal outcome of typing.
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 4,
        suffixText: context.l10n.rhythmDaysSuffix,
      ),
      validator: Validators.compose([
        Validators.required(strings),
        Validators.intMin(strings, 1),
      ]),
      onChanged: onChanged,
    );
  }
}

/// The ladder: one rung per row, added and removed rather than typed as a list.
///
/// The alternative — one text field holding "7, 14, 28" — would put a second
/// parser for these numbers in the client, which is precisely the shape this
/// whole feature is arranged to avoid. It would also make "the last rung is the
/// cap" invisible, and that is the property somebody has to understand before
/// changing anything here.
class _Ladder extends StatelessWidget {
  const _Ladder({
    required this.steps,
    required this.base,
    required this.enabled,
    required this.onChanged,
  });

  final List<int> steps;

  /// The base interval as currently typed, for the warning below.
  final int base;

  final bool enabled;
  final ValueChanged<List<int>> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);

    // The two things the server refuses, said HERE instead of after a round
    // trip. Not a replacement for the server's check — that one is the rule —
    // but a refusal you can see coming is one nobody has to decode.
    final descending = [
      for (var i = 1; i < steps.length; i++)
        if (steps[i] < steps[i - 1]) i,
    ].isNotEmpty;
    final belowBase = steps.isNotEmpty && base > 0 && steps.first < base;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.rhythmLadderLabel, style: theme.textTheme.titleSmall),
        Text(
          l10n.rhythmLadderHelp,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: ZugvogelSpacing.sm),
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: ZugvogelSpacing.sm),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    // The last rung is the cap and is REACHED, not exceeded — a
                    // nest empty twenty times running still comes back round.
                    // That is the property somebody has to know before editing.
                    i == steps.length - 1 && steps.length > 1
                        ? l10n.rhythmLadderCapRung(i + 1, steps[i])
                        : l10n.rhythmLadderRung(i + 1, steps[i]),
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.remove),
                  tooltip: l10n.rhythmLadderShorten,
                  onPressed: !enabled || steps[i] <= 1
                      ? null
                      : () => onChanged([
                          for (var j = 0; j < steps.length; j++)
                            if (j == i) steps[j] - 1 else steps[j],
                        ]),
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: l10n.rhythmLadderLengthen,
                  onPressed: !enabled
                      ? null
                      : () => onChanged([
                          for (var j = 0; j < steps.length; j++)
                            if (j == i) steps[j] + 1 else steps[j],
                        ]),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: l10n.rhythmLadderRemoveRung,
                  // Never the last one: `intervalFor` indexes into this list,
                  // and an empty ladder is refused by the route.
                  onPressed: !enabled || steps.length <= 1
                      ? null
                      : () => onChanged([
                          for (var j = 0; j < steps.length; j++)
                            if (j != i) steps[j],
                        ]),
                ),
              ],
            ),
          ),
        if (enabled)
          TextButton.icon(
            onPressed: () => onChanged([...steps, steps.last * 2]),
            icon: const Icon(Icons.add),
            label: Text(l10n.rhythmLadderAddRung),
          ),
        if (descending)
          _Warning(text: l10n.rhythmLadderDescendingWarning)
        else if (belowBase)
          _Warning(text: l10n.rhythmLadderBelowBaseWarning(base)),
      ],
    );
  }
}

class _Warning extends StatelessWidget {
  const _Warning({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: ZugvogelSpacing.sm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.warning_amber_outlined,
            size: 18,
            color: theme.colorScheme.error,
          ),
          const SizedBox(width: ZugvogelSpacing.sm),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
