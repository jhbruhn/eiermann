import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/tours/tours_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that creates a route template, or renames [tour].
Future<void> showTourSheet(BuildContext context, {Tour? tour}) {
  return showAppSheet<void>(
    context,
    builder: (_) => TourSheet(tour: tour),
  );
}

/// Name a route.
///
/// A name and a note, and nothing else — the stops are the editor's, for the
/// same reason a Bereich's photo is not in its sheet: the route has to exist
/// before anything can be hung on it, and asking for both at once means either
/// a two-step save that can half-fail or a Spot picker opening out of a form
/// somebody is still typing in.
///
/// **The name is the identity.** It is unique per organisation and
/// case-insensitively so, because "Tour 1 fortsetzen" has to mean one thing —
/// two routes with that name make every sentence the app says about a tour
/// ambiguous. The collision comes back from the server as a validation failure;
/// the sheet says what happened rather than showing the generic copy, because
/// this is the one refusal here a user can act on immediately.
class TourSheet extends ConsumerStatefulWidget {
  const TourSheet({this.tour, super.key});

  final Tour? tour;

  @override
  ConsumerState<TourSheet> createState() => _TourSheetState();
}

class _TourSheetState extends ConsumerState<TourSheet>
    with DiscardGuard, FormSheetState {
  late final _name = TextEditingController(text: widget.tour?.name ?? '');
  late final _note = TextEditingController(text: widget.tour?.note ?? '');

  bool get _isEdit => widget.tour != null;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);
    final l10n = context.l10n;
    final existing = widget.tour;

    final ok = await runSave(() async {
      final repo = await ref.read(toursRepositoryProvider.future);
      final body = ToursRepository.body(
        name: _name.text.trim(),
        note: trimToNull(_note),
        // Retiring and reactivating are their own actions on the list, so this
        // form never changes the flag — it would let a rename silently bring a
        // retired route back.
        isActive: existing?.isActive ?? true,
        // Only on create: the update rule refuses `org`, which is what makes a
        // template un-re-tenantable.
        org: existing == null ? (await requireUserOrg()).$2 : null,
      );
      try {
        if (existing == null) {
          await repo.create(body);
        } else {
          await repo.update(existing.id, body);
        }
      } on RepositoryException catch (e) {
        // The unique index, in the only shape the client can recognise it: a
        // validation failure naming `name`. Not a refusal code — this one comes
        // from the database's own constraint, not from a hook, so there is
        // nothing in `data` for `serverErrorFor` to translate.
        if (e.kind == RepositoryErrorKind.validation) {
          throw RepositoryException(
            l10n.tourNameTaken,
            kind: e.kind,
            cause: e,
          );
        }
        rethrow;
      }
      invalidateTourViews(ref);
    });
    if (ok && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _isEdit ? l10n.tourSheetTitleEdit : l10n.tourSheetTitleNew,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          AppTextField(
            controller: _name,
            label: l10n.tourFieldName,
            hintText: l10n.tourFieldNameHint,
            prefixIcon: Icons.route_outlined,
            enabled: !isBusy,
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.tourFieldNote,
            // What the stop list cannot say: which day this is walked, where to
            // park, which key to bring.
            hintText: l10n.tourFieldNoteHint,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 3,
          ),
        ],
      ),
    );
  }
}
