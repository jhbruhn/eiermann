import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/team/team_labels.dart';
import 'package:eiermann/features/team/team_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/ui/form_sheet.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart'
    show serverInfoProvider;
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Opens the invite sheet. Resolves to the [Invitation] that was created, or
/// null if the sheet was dismissed.
Future<Invitation?> showInviteSheet(BuildContext context) {
  return showAppSheet<Invitation>(
    context,
    builder: (_) => const InviteSheet(),
  );
}

/// Creates an account for somebody who is not in the app yet.
///
/// The only way an account comes into existence in this app. There is no
/// self-registration anywhere — `users.createRule` names the coordinator role
/// — because the group's whole security model rests on the roster being a list
/// somebody decided on, rather than a list of whoever found the URL.
///
/// **Name is required here although the schema allows it to be empty**, and
/// that is not a form being fussy. Every audit-shaped row in this database
/// stores a text SNAPSHOT of its author beside the id, so the history survives
/// a rename or a departure. An account with no name snapshots its email address
/// instead — and then a private address sits in the visit history of every Spot
/// that person ever touched, permanently, including in exported reports.
class InviteSheet extends ConsumerStatefulWidget {
  const InviteSheet({super.key});

  @override
  ConsumerState<InviteSheet> createState() => _InviteSheetState();
}

class _InviteSheetState extends ConsumerState<InviteSheet>
    with DiscardGuard, FormSheetState {
  final _email = TextEditingController();
  final _name = TextEditingController();
  final _phone = TextEditingController();

  /// Everybody starts as a member.
  ///
  /// The coordination is granted deliberately, on a row that already exists, by
  /// somebody who has looked at the roster. A dropdown that opened on
  /// "Koordination" would hand out the role that deletes Spots by inattention.
  UserRole _role = UserRole.member;

  @override
  void dispose() {
    _email.dispose();
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!(formKey.currentState?.validate() ?? false)) return;
    final navigator = Navigator.of(context);

    Invitation? created;
    final ok = await runSave(() async {
      final (_, org) = await requireUserOrg();
      final repo = await ref.read(usersRepositoryProvider.future);
      // The server says whether it has a mailer at all. Asking it to send one
      // anyway would be a round trip to a guaranteed failure — and the fallback
      // this app has (hand the password over) is the same either way, so there
      // is nothing to learn from trying.
      //
      // `.future` and not `.value`: nothing on this sheet WATCHES the server
      // info, so a plain read hands back an AsyncLoading whose value is null,
      // and every invite would quietly take the no-mailer path on a server that
      // has one. An unreachable /info lands on the same path, which is the one
      // that works without the server's help.
      var canMail = false;
      try {
        final info = await ref.read(serverInfoProvider.future);
        canMail = info?.auth.passwordReset ?? false;
      } on Object {
        canMail = false;
      }
      created = await repo.invite(
        email: _email.text,
        name: _name.text,
        role: _role,
        org: org,
        phone: trimToNull(_phone),
        sendResetEmail: canMail,
      );
      ref.invalidate(teamProvider);
    });
    if (ok && mounted) navigator.pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final strings = EiermannStrings(l10n);

    return guardUnsavedChanges(
      child: SheetScaffold(
        title: l10n.teamInviteTitle,
        formKey: formKey,
        onFormChanged: markDirty,
        isBusy: isBusy,
        error: saveError,
        onSave: _save,
        saveLabel: l10n.teamInviteAction,
        children: [
          AppTextField(
            controller: _email,
            label: l10n.teamFieldEmail,
            hintText: l10n.teamFieldEmailHint,
            prefixIcon: Icons.alternate_email,
            enabled: !isBusy,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            validator: Validators.compose([
              Validators.required(strings),
              Validators.email(strings),
            ]),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _name,
            label: l10n.teamFieldName,
            hintText: l10n.teamFieldNameHint,
            prefixIcon: Icons.badge_outlined,
            enabled: !isBusy,
            textInputAction: TextInputAction.next,
            // See the class doc: this is what keeps an email address out of
            // every visit history the person appears in.
            validator: Validators.required(strings),
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          AppTextField(
            controller: _phone,
            label: l10n.teamFieldPhone,
            prefixIcon: Icons.phone_outlined,
            enabled: !isBusy,
            keyboardType: TextInputType.phone,
            textInputAction: TextInputAction.done,
          ),
          const SizedBox(height: ZugvogelSpacing.md),
          DropdownButtonFormField<UserRole>(
            initialValue: _role,
            decoration: InputDecoration(
              labelText: l10n.teamFieldRole,
              prefixIcon: Icon(userRoleIcon(_role)),
              helperText: l10n.teamFieldRoleHint,
              helperMaxLines: 3,
            ),
            items: [
              // Not `guest`: it is a wall, not a tier, and inviting somebody
              // into it would be creating an account that can read nothing and
              // then asking a second question to fix it.
              for (final role in [UserRole.member, UserRole.coordinator])
                DropdownMenuItem(
                  value: role,
                  child: Text(userRoleLabel(l10n, role)),
                ),
            ],
            onChanged: isBusy
                ? null
                : (role) => setState(() => _role = role ?? UserRole.member),
          ),
        ],
      ),
    );
  }
}

/// Says which of the two ways in the new account got.
///
/// **Why there are two.** `users` is a PocketBase auth collection, so an
/// account cannot be created without a password — it has to be able to sign in
/// the moment it exists. The clean route is the one federfall takes: create it
/// with a throwaway password and mail the invitee a link to set their own, so
/// nobody ever transmits a password somebody else chose.
///
/// That route needs a mailer, and this app is self-hosted by volunteer groups
/// that frequently have none. federfall answers that by hiding its invite
/// action entirely; here it would mean a group that can never add anybody. So
/// when no mail went out, the throwaway password is not thrown away — it is
/// shown, once, to be passed on the way this group passes everything on.
///
/// The dialog says plainly that it will not come back. The server keeps only a
/// hash, so nothing — not this app, not the Admin UI — can produce it again.
Future<void> showInvitationResult(
  BuildContext context,
  Invitation invitation,
) {
  return showDialog<void>(
    context: context,
    // Not dismissible by tapping outside: on the no-mailer path the one thing
    // this dialog carries is unrecoverable, and a stray tap on a phone would
    // take it away.
    barrierDismissible: false,
    builder: (context) => _InvitationDialog(invitation: invitation),
  );
}

class _InvitationDialog extends StatelessWidget {
  const _InvitationDialog({required this.invitation});

  final Invitation invitation;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final name = userDisplayName(l10n, invitation.user);
    final email = invitation.user.email;

    return AlertDialog(
      icon: Icon(
        invitation.mailSent
            ? Icons.mark_email_read_outlined
            : Icons.key_outlined,
      ),
      title: Text(l10n.teamInvitedTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            invitation.mailSent
                ? l10n.teamInvitedByMail(name, email)
                : l10n.teamInvitedByPassword(name, email),
          ),
          // Only on the path where it is the way in. A password shown beside
          // "we have mailed them a link" is a second credential in circulation
          // for no reason — and the one the invitee will not be using.
          if (!invitation.mailSent) ...[
            const SizedBox(height: ZugvogelSpacing.md),
            Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(ZugvogelSpacing.md),
                child: Row(
                  children: [
                    Expanded(
                      child: SelectableText(
                        invitation.password,
                        // Monospace, because this string gets read out loud and
                        // retyped: a proportional font makes a lower-case l and
                        // an upper-case I the same glyph, which is the support
                        // call the generator's alphabet already avoids.
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.copy_outlined),
                      tooltip: l10n.teamCopyPasswordAction,
                      onPressed: () async {
                        await Clipboard.setData(
                          ClipboardData(text: invitation.password),
                        );
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text(l10n.teamPasswordCopied)),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: ZugvogelSpacing.sm),
            Text(
              l10n.teamInvitedOnceHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.teamInvitedDoneAction),
        ),
      ],
    );
  }
}
