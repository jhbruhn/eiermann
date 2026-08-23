import 'dart:async';

import 'package:eiermann/core/auth/roles.dart';
import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/team/invite_sheet.dart';
import 'package:eiermann/features/team/team_labels.dart';
import 'package:eiermann/features/team/team_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_data/eiermann_data.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_core/zugvogel_core.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart'
    show serverInfoProvider;
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The roster: who is on the team, what each may decide, and who has left.
///
/// **Nobody is deleted here, ever.** `users.deleteRule` is null and this screen
/// offers no delete, because a departed member's name still has to appear on
/// every visit they recorded — removing the row would either cascade that
/// history away or leave it pointing at nothing. Ending somebody's access is
/// `is_active = false`, which takes effect on a live token rather than at the
/// next sign-in: `users.authRule` is re-evaluated on every request.
///
/// Former members therefore stay in the list rather than being filtered out.
/// "Who was Meike?" is exactly the question this screen gets asked, months
/// later, by somebody reading an old visit.
///
/// **You cannot change your own role or your own access**, and the row for the
/// signed-in account says so rather than offering controls that come back
/// refused. The rule is the server's (`main.pb.js` puts the stored value back
/// for a self-edit of a privilege field) and it exists twice over: otherwise
/// the last coordinator locks the whole group out with one tap, and a stolen
/// coordinator session becomes a permanent one.
class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final team = ref.watch(teamProvider);
    final me = ref.watch(currentUserProvider).value;
    // The whole team may READ the roster — a visit that names an author nobody
    // can resolve is worse than no name. Only the coordination may change it.
    final mayAdminister = me?.role?.canAdminister ?? false;
    // Whether an invited account could EVER sign in.
    //
    // On a server with password sign-in switched off — an OIDC-only instance —
    // creating a password account makes something nobody can use, so the action
    // is hidden rather than left to produce a dead account. That much is
    // federfall's rule, and its reason.
    //
    // What is NOT required here is a mailer. federfall also hides the invite
    // when the server cannot send a reset mail; this app hands the coordinator
    // the start password instead, because a volunteer group's self-hosted
    // instance frequently has no SMTP and "you can never add anybody" is not an
    // acceptable resting state. Defaulting to true keeps an older server, or
    // one whose /info has not arrived yet, working rather than silently
    // control-less.
    final auth = ref.watch(serverInfoProvider).value?.auth;
    final canInvite = mayAdminister && (auth?.password ?? true);
    final canMail = auth?.passwordReset ?? false;

    return Scaffold(
      appBar: AppBar(title: Text(l10n.teamTitle)),
      body: AsyncValueView(
        value: team,
        onRetry: () => ref.invalidate(teamProvider),
        data: (users) => _Roster(
          users: users,
          me: me,
          mayAdminister: mayAdminister,
          canMail: canMail,
        ),
      ),
      floatingActionButton: canInvite
          ? FloatingActionButton.extended(
              onPressed: () => unawaited(_invite(context, ref)),
              icon: const Icon(Icons.person_add_alt),
              label: Text(l10n.teamInviteAction),
            )
          : null,
    );
  }

  /// Runs the invite, then shows the start password.
  ///
  /// The dialog is opened from HERE rather than from inside the sheet, after
  /// the sheet has closed. A dialog stacked on a sheet that is dismissing takes
  /// the password down with it on some routes — and this is the one string in
  /// the app that cannot be fetched again.
  Future<void> _invite(BuildContext context, WidgetRef ref) async {
    final created = await showInviteSheet(context);
    if (created == null || !context.mounted) return;
    await showInvitationResult(context, created);
  }
}

class _Roster extends StatelessWidget {
  const _Roster({
    required this.users,
    required this.me,
    required this.mayAdminister,
    required this.canMail,
  });

  final List<AppUser> users;
  final AppUser? me;
  final bool mayAdminister;
  final bool canMail;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    if (users.isEmpty) {
      // Practically unreachable — the reader of this screen is in the list —
      // but a blank body would read as a broken load rather than an empty one.
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(ZugvogelSpacing.lg),
          child: Text(l10n.teamEmpty, textAlign: TextAlign.center),
        ),
      );
    }

    // Waiting accounts first, then the active team, then whoever has left.
    //
    // The order is the point. Somebody signed in and walled off is the only
    // entry on this screen that is WAITING on the reader — every other row is a
    // state of affairs. Sorting them in among the rest by name is how an
    // account provisioned by an identity provider sits unnoticed for a week.
    final waiting = users.where((u) => !_isLetIn(u)).toList();
    final active = users.where((u) => _isLetIn(u) && u.isActive).toList();
    final former = users.where((u) => _isLetIn(u) && !u.isActive).toList();

    return ListView(
      padding: const EdgeInsets.only(bottom: 88),
      children: [
        if (waiting.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.teamSectionWaiting,
            subtitle: l10n.teamSectionWaitingHint,
          ),
          for (final user in waiting) _row(user),
        ],
        if (active.isNotEmpty) ...[
          _SectionHeader(title: l10n.teamSectionActive),
          for (final user in active) _row(user),
        ],
        if (former.isNotEmpty) ...[
          _SectionHeader(
            title: l10n.teamSectionFormer,
            subtitle: l10n.teamSectionFormerHint,
          ),
          for (final user in former) _row(user),
        ],
      ],
    );
  }

  /// Whether somebody has been given a role that can actually read anything.
  ///
  /// `guest` and null are both "not yet": every access rule in the database
  /// names the roles that may pass, and neither is one of them.
  static bool _isLetIn(AppUser user) =>
      user.role == UserRole.member || user.role == UserRole.coordinator;

  Widget _row(AppUser user) => _MemberTile(
    user: user,
    isSelf: user.id == me?.id,
    mayAdminister: mayAdminister,
    canMail: canMail,
  );
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        ZugvogelSpacing.md,
        ZugvogelSpacing.lg,
        ZugvogelSpacing.md,
        ZugvogelSpacing.xs,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: theme.textTheme.titleSmall?.copyWith(
              color: theme.colorScheme.primary,
            ),
          ),
          if (subtitle case final hint?)
            Text(
              hint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
    );
  }
}

/// One person: what they are called, what they may do, and how to change it.
class _MemberTile extends ConsumerStatefulWidget {
  const _MemberTile({
    required this.user,
    required this.isSelf,
    required this.mayAdminister,
    required this.canMail,
  });

  final AppUser user;
  final bool isSelf;
  final bool mayAdminister;

  /// Whether the server can send the credential-setting link again.
  final bool canMail;

  @override
  ConsumerState<_MemberTile> createState() => _MemberTileState();
}

class _MemberTileState extends ConsumerState<_MemberTile> {
  bool _busy = false;

  /// Whether this row offers any control at all.
  ///
  /// Both halves matter. A member reading the roster gets a list, not a set of
  /// buttons that come back 403. And the coordinator's OWN row is read-only for
  /// everybody including themselves — see the screen's doc.
  bool get _editable => widget.mayAdminister && !widget.isSelf;

  /// Whether this row is an invitation that was never taken up.
  ///
  /// Only for an account that HAS been let in and is active — a waiting
  /// account already sits under its own heading saying the same thing, and a
  /// deactivated one is not waiting on anybody.
  bool get _showsPending =>
      !widget.user.verified &&
      widget.user.isActive &&
      (widget.user.role == UserRole.member ||
          widget.user.role == UserRole.coordinator);

  Future<void> _run(Future<void> Function(UsersRepository repo) action) async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _busy = true);
    try {
      final repo = await ref.read(usersRepositoryProvider.future);
      await action(repo);
      ref.invalidate(teamProvider);
    } on Object catch (error, stackTrace) {
      reportCaughtError(error, stackTrace, context: 'team write');
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            error is RepositoryException
                ? errorMessage(EiermannStrings(l10n), error)
                : l10n.errorGenericTitle,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _setRole(UserRole role) =>
      _run((repo) => repo.setRole(widget.user.id, role));

  /// Sends the credential-setting link again.
  ///
  /// The one action here that reports SUCCESS out loud. Everything else on this
  /// screen changes something visible in the row itself; a mail leaves no trace
  /// in the app at all, so without the confirmation a coordinator cannot tell a
  /// sent mail from a tap that did nothing.
  Future<void> _resend() async {
    final l10n = context.l10n;
    final messenger = ScaffoldMessenger.of(context);
    final email = widget.user.email;
    await _run((repo) async {
      await repo.resendInvitation(email);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.teamInviteResent(email))),
      );
    });
  }

  Future<void> _setActive({required bool active}) async {
    final l10n = context.l10n;
    if (!active) {
      // Confirmed, because it ends a live session mid-request rather than at
      // the next sign-in — somebody standing in a stairwell recording a visit
      // loses the screen they are on.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(l10n.teamDeactivateTitle),
          content: Text(
            l10n.teamDeactivateMessage(userDisplayName(l10n, widget.user)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: Text(l10n.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: Text(l10n.teamDeactivateConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }
    await _run((repo) => repo.setActive(widget.user.id, active: active));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final user = widget.user;
    final subtitle = [
      user.email,
      if (user.phone?.trim().isNotEmpty ?? false) user.phone!.trim(),
    ].where((line) => line.isNotEmpty).join(' · ');

    return ListTile(
      leading: Icon(userRoleIcon(user.role)),
      title: Row(
        children: [
          Flexible(child: Text(userDisplayName(l10n, user))),
          if (widget.isSelf) ...[
            const SizedBox(width: ZugvogelSpacing.sm),
            // Named rather than merely disabled: a row whose controls are
            // greyed out with no reason reads as a bug in the app.
            Chip(
              label: Text(l10n.teamYou),
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (subtitle.isNotEmpty) Text(subtitle),
          Row(
            children: [
              Text(
                userRoleLabel(l10n, user.role),
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              // An invitation nobody picked up. `verified` is set when somebody
              // completes a password reset, which for an invited account is the
              // moment they choose their own password — so an unverified,
              // active member is one who has never actually arrived. Without
              // this they are indistinguishable from a member who is simply
              // quiet, and the invitation that went to a mistyped address looks
              // exactly like one that worked.
              if (_showsPending) ...[
                const SizedBox(width: ZugvogelSpacing.sm),
                Text(
                  l10n.teamInvitePending,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.tertiary,
                  ),
                ),
              ],
            ],
          ),
          if (widget.isSelf && widget.mayAdminister)
            Text(
              l10n.teamSelfLockedHint,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
        ],
      ),
      isThreeLine: true,
      trailing: _busy
          ? const SizedBox.square(
              dimension: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : _editable
          ? _RowMenu(
              user: user,
              // Offered only where it can do anything: the link needs a mailer,
              // and somebody who already set their own password does not need
              // one sent.
              onResend: widget.canMail && _showsPending
                  ? () => unawaited(_resend())
                  : null,
              onRole: (role) => unawaited(_setRole(role)),
              onActive: ({required active}) =>
                  unawaited(_setActive(active: active)),
            )
          : null,
    );
  }
}

/// The three things a coordinator can do to somebody else's row.
class _RowMenu extends StatelessWidget {
  const _RowMenu({
    required this.user,
    required this.onRole,
    required this.onActive,
    this.onResend,
  });

  final AppUser user;

  /// Sends the credential-setting link again, when there is one to send.
  final VoidCallback? onResend;

  final ValueChanged<UserRole> onRole;
  final void Function({required bool active}) onActive;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return PopupMenuButton<VoidCallback>(
      tooltip: l10n.teamRowMenuTooltip,
      onSelected: (action) => action(),
      itemBuilder: (context) => [
        if (onResend case final resend?)
          PopupMenuItem(
            value: resend,
            child: Text(l10n.teamResendInviteAction),
          ),
        if (user.role != UserRole.member)
          PopupMenuItem(
            value: () => onRole(UserRole.member),
            child: Text(
              // "Freischalten" for a waiting account and "zurückstufen" for a
              // coordinator: the same write, but a reader deciding between them
              // is answering two different questions.
              user.role == UserRole.coordinator
                  ? l10n.teamMakeMemberAction
                  : l10n.teamAdmitAsMemberAction,
            ),
          ),
        if (user.role != UserRole.coordinator)
          PopupMenuItem(
            value: () => onRole(UserRole.coordinator),
            child: Text(l10n.teamMakeCoordinatorAction),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: () => onActive(active: !user.isActive),
          child: Text(
            user.isActive
                ? l10n.teamDeactivateAction
                : l10n.teamReactivateAction,
          ),
        ),
      ],
      icon: const Icon(Icons.more_vert),
    );
  }
}
