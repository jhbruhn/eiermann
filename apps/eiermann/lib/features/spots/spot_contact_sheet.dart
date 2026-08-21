import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/spots/spot_labels.dart';
import 'package:eiermann/features/spots/spots_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that adds a contact to [spotId], or edits [contact].
Future<void> showSpotContactSheet(
  BuildContext context, {
  required String spotId,
  SpotContact? contact,
}) {
  return showAppSheet<void>(
    context,
    builder: (_) => SpotContactSheet(spotId: spotId, contact: contact),
  );
}

/// Add or edit a contact person — the caretaker, the owner, the tenant.
///
/// Only the name is required. A contact with a name and nothing else is still
/// worth having: knowing WHO to ask about is most of the way there, and a form
/// that insisted on a phone number would push the name into a note instead.
class SpotContactSheet extends ConsumerStatefulWidget {
  const SpotContactSheet({required this.spotId, this.contact, super.key});

  /// The Spot the contact belongs to. Frozen on the edit path — the collection
  /// refuses a re-parenting write.
  final String spotId;

  final SpotContact? contact;

  @override
  ConsumerState<SpotContactSheet> createState() => _SpotContactSheetState();
}

class _SpotContactSheetState extends ConsumerState<SpotContactSheet>
    with DiscardGuard, FormSheetState {
  late final _name = TextEditingController(text: widget.contact?.name ?? '');
  late final _phone = TextEditingController(text: widget.contact?.phone ?? '');
  late final _email = TextEditingController(text: widget.contact?.email ?? '');
  late final _note = TextEditingController(text: widget.contact?.note ?? '');

  /// A caretaker by default: it is the role that gets somebody in, and by far
  /// the most common thing being recorded.
  late ContactRole? _role = widget.contact == null
      ? ContactRole.caretaker
      : widget.contact!.role;

  late bool _isPrimary = widget.contact?.isPrimary ?? false;

  bool _roleMissing = false;

  bool get _isEdit => widget.contact != null;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _email.dispose();
    _note.dispose();
    super.dispose();
  }

  /// Removes the contact, after asking.
  ///
  /// Not gated on `RolePermissions.canDelete`, which is about deleting a SPOT
  /// — that destroys a whole dossier, and the coordinator owns it for that
  /// reason. This is one row with one phone number on it, the server lets any
  /// member
  /// delete it, and the person who mistyped a number is the one holding the
  /// phone. A team that cannot remove a caretaker who moved out keeps ringing
  /// them.
  Future<void> _delete() async {
    final existing = widget.contact;
    if (existing == null) return;
    final l10n = context.l10n;
    final navigator = Navigator.of(context);

    await confirmAndDelete(
      context,
      title: l10n.spotContactDeleteTitle,
      // Names the number as well as the person: it is the thing that is
      // actually being lost, and it exists nowhere else in the app.
      message: l10n.spotContactDeleteMessage(existing.name),
      confirmLabel: l10n.spotContactDeleteAction,
      action: () async {
        final repo = await ref.read(spotContactsRepositoryProvider.future);
        await repo.delete(existing.id);
        ref.invalidate(spotContactsProvider(widget.spotId));
        invalidateSpotViews(ref);
        // Inside the action, so a failed delete leaves the sheet standing with
        // its snackbar instead of closing over the error.
        navigator.pop();
      },
    );
  }

  Future<void> _save() async {
    final role = _role;
    if (_roleMissing != (role == null)) {
      setState(() => _roleMissing = role == null);
    }
    if (!(formKey.currentState?.validate() ?? false) || role == null) return;
    final navigator = Navigator.of(context);
    final existing = widget.contact;

    final ok = await runSave(() async {
      final repo = await ref.read(spotContactsRepositoryProvider.future);
      final body = SpotContactsRepository.body(
        name: _name.text.trim(),
        role: role,
        phone: trimToNull(_phone),
        email: trimToNull(_email),
        note: trimToNull(_note),
        isPrimary: _isPrimary,
        // Both only on create: the collection freezes the parent and pins the
        // org, so an update carrying either is refused outright.
        spot: existing == null ? widget.spotId : null,
        org: existing == null ? (await requireUserOrg()).$2 : null,
      );
      if (existing == null) {
        await repo.create(body);
      } else {
        await repo.update(existing.id, body);
      }

      // The list row and the map callout both show the contact count, and it
      // comes from the view.
      ref.invalidate(spotContactsProvider(widget.spotId));
      invalidateSpotViews(ref);
    });
    if (ok && mounted) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: _isEdit
            ? l10n.spotContactSheetTitleEdit
            : l10n.spotContactSheetTitleNew,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        trailing: [
          if (_isEdit) ...[
            const SizedBox(height: ZugvogelSpacing.sm),
            // Under the save button and outlined, not beside it: a delete that
            // shares a row with Save is a delete somebody taps by aiming badly.
            OutlinedButton.icon(
              onPressed: isBusy ? null : _delete,
              icon: const Icon(Icons.delete_outline),
              label: Text(l10n.spotContactDeleteAction),
              style: OutlinedButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
        children: [
          DropdownButtonFormField<ContactRole>(
            initialValue: _role,
            decoration: InputDecoration(
              labelText: l10n.spotContactFieldRole,
              prefixIcon: const Icon(Icons.badge_outlined),
              errorText: _roleMissing ? l10n.fieldRequired : null,
            ),
            items: [
              for (final role in ContactRole.values)
                DropdownMenuItem(
                  value: role,
                  child: Text(contactRoleLabel(l10n, role)),
                ),
            ],
            onChanged: isBusy
                ? null
                : (role) => setState(() {
                    _role = role;
                    _roleMissing = false;
                    markDirty();
                  }),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _name,
            label: l10n.spotContactFieldName,
            prefixIcon: Icons.person_outline,
            enabled: !isBusy,
            autofocus: !_isEdit,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _phone,
            label: l10n.spotContactFieldPhone,
            prefixIcon: Icons.phone_outlined,
            enabled: !isBusy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _email,
            label: l10n.spotContactFieldEmail,
            prefixIcon: Icons.mail_outline,
            enabled: !isBusy,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            // Empty passes: the address is optional, and a plausibility check
            // only fires on something that was actually typed.
            validator: Validators.email(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _note,
            label: l10n.spotContactFieldNote,
            prefixIcon: Icons.notes_outlined,
            enabled: !isBusy,
            maxLines: 2,
          ),
          const SizedBox(height: ZugvogelSpacing.sm),
          SwitchListTile(
            value: _isPrimary,
            title: Text(l10n.spotContactFieldPrimary),
            // Says out loud that the flag is not exclusive. Two people can both
            // be worth calling, and a form that implied otherwise is how the
            // second number ends up in a note field.
            subtitle: Text(l10n.spotContactFieldPrimaryHint),
            contentPadding: EdgeInsets.zero,
            onChanged: isBusy
                ? null
                : (value) => setState(() {
                    _isPrimary = value;
                    markDirty();
                  }),
          ),
        ],
      ),
    );
  }
}
