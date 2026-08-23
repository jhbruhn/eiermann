import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the sheet that edits your own name and phone number. Resolves to true
/// when something was saved.
Future<bool?> showEditProfileSheet(BuildContext context, AppUser user) {
  return showAppSheet<bool>(
    context,
    builder: (_) => EditProfileSheet(user: user),
  );
}

/// The two fields of your own account you may change: name and phone number.
///
/// **Not the email address, the role or the access flag**, and the sheet is
/// short for that reason rather than by omission. `users.updateRule` lets a
/// member write their own row only while `role`, `org`, `is_active` and
/// `verified` are absent from the body — and `main.pb.js` puts the stored
/// value back if one shows up anyway. The address is the sign-in identity:
/// changing it is a coordinator's act on the roster, so it is not offered
/// here.
///
/// **The name is required**, exactly as in the invite sheet, and for the same
/// reason: every audit-shaped row in this database stores a text SNAPSHOT of
/// its author. Emptying your name would put your email address into the visit
/// history of every Spot you touch afterwards.
class EditProfileSheet extends ConsumerStatefulWidget {
  const EditProfileSheet({required this.user, super.key});

  final AppUser user;

  @override
  ConsumerState<EditProfileSheet> createState() => _EditProfileSheetState();
}

class _EditProfileSheetState extends ConsumerState<EditProfileSheet>
    with DiscardGuard, FormSheetState {
  late final TextEditingController _name;
  late final TextEditingController _phone;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.user.name ?? '');
    _phone = TextEditingController(text: widget.user.phone ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);

    final ok = await runSave(() async {
      final repo = await ref.read(authRepositoryProvider.future);
      // Both fields always, never only the changed one: the empty string is how
      // a phone number gets cleared, and a body that omitted it would make
      // deleting a number impossible.
      await repo.updateProfile(name: _name.text, phone: _phone.text);
      // No invalidate: the SDK saves the updated record back into the auth
      // store, and `currentUserProvider` listens to that.
    });
    if (ok && mounted) navigator.pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.profileEditTitle,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        children: [
          AppTextField(
            controller: _name,
            label: l10n.profileNameLabel,
            prefixIcon: Icons.badge_outlined,
            enabled: !isBusy,
            autofocus: true,
            textInputAction: TextInputAction.next,
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _phone,
            label: l10n.profilePhoneLabel,
            prefixIcon: Icons.phone_outlined,
            enabled: !isBusy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
          ),
        ],
      ),
    );
  }
}
