import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/data/repository_providers.dart';
import 'package:eiermann/features/profile/edit_profile_sheet.dart';
import 'package:eiermann/features/team/team_labels.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann/routing/back_or_home.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_pb_client/zugvogel_pb_client.dart'
    show appVersionProvider, serverInfoProvider;
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// Your own account: what the app knows about you, and the way out.
///
/// **Why the sign-out lives here and no longer in every app bar.** It used to
/// be an icon on all four shell destinations, next to a statistics icon and an
/// administration menu — three permanent icons for things somebody does once a
/// season or once a day. The account menu leads to all of them now, and
/// leaving is the last row of this screen, which is where somebody looks for
/// it.
///
/// The screen is a top-level route over the shell, so its back stack can be
/// empty — a cold open, a web reload, or an arrival by `go` from a branch.
/// Hence [BackOrHomeButton] for the app bar and [BackOrHomeScope] for the
/// system back gesture: neither strands a reader with no way back.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final user = ref.watch(currentUserProvider);

    return BackOrHomeScope(
      child: Scaffold(
        appBar: AppBar(
          leading: const BackOrHomeButton(),
          title: Text(l10n.profileTitle),
          actions: [
            if (user.value case final me?)
              IconButton(
                icon: const Icon(Icons.edit_outlined),
                tooltip: l10n.profileEditTitle,
                onPressed: () => showEditProfileSheet(context, me),
              ),
          ],
        ),
        body: AsyncValueView<AppUser?>(
          value: user,
          onRetry: () => ref.invalidate(currentUserProvider),
          data: (me) => me == null
              ? EmptyView(
                  icon: Icons.lock_outline,
                  message: l10n.errorUnauthorized,
                )
              : _ProfileBody(me),
        ),
      ),
    );
  }
}

class _ProfileBody extends StatelessWidget {
  const _ProfileBody(this.user);

  final AppUser user;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;

    return ContentBounds(
      child: ListView(
        padding: const EdgeInsets.all(ZugvogelSpacing.sm),
        children: [
          ListTile(
            leading: const Icon(Icons.badge_outlined),
            title: Text(l10n.profileNameLabel),
            // An account with no name is possible in the schema and worth
            // saying so plainly: the visit history snapshots the author's name
            // when it is written, so this is the row to fix before the next
            // visit rather than after it.
            subtitle: Text(
              user.name?.isNotEmpty ?? false
                  ? user.name!
                  : l10n.profileNameMissing,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.alternate_email),
            title: Text(l10n.profileEmailLabel),
            subtitle: Text(user.email),
          ),
          ListTile(
            leading: Icon(userRoleIcon(user.role)),
            title: Text(l10n.profileRoleLabel),
            // The same label the roster uses, so "Koordination" means the same
            // word in both places.
            subtitle: Text(userRoleLabel(l10n, user.role)),
          ),
          if (user.phone?.isNotEmpty ?? false)
            ListTile(
              leading: const Icon(Icons.phone_outlined),
              title: Text(l10n.profilePhoneLabel),
              subtitle: Text(user.phone!),
            ),
          const Divider(height: ZugvogelSpacing.lg),
          const _VersionInfo(),
          const SizedBox(height: ZugvogelSpacing.lg),
          const _SignOutButton(),
        ],
      ),
    );
  }
}

/// App and server version, for a bug report.
///
/// Two numbers rather than one because they can disagree, and when they do it
/// is the whole answer: this app checks its major against the server's `/info`
/// at runtime, and "which build against which instance" is the first question
/// anybody asks about a self-hosted deployment.
///
/// The server row stays blank until `serverInfoProvider` resolves — and stays
/// blank if it cannot be reached — rather than showing a spinner. It is a
/// footnote, not a value the screen is waiting for.
class _VersionInfo extends ConsumerWidget {
  const _VersionInfo();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final appVersion = ref.watch(appVersionProvider).value;
    final serverVersion = ref.watch(serverInfoProvider).value?.version;

    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.info_outline),
          title: Text(l10n.profileAppVersionLabel),
          subtitle: Text(appVersion ?? '—'),
        ),
        ListTile(
          leading: const Icon(Icons.dns_outlined),
          title: Text(l10n.profileServerVersionLabel),
          subtitle: Text(
            (serverVersion?.isNotEmpty ?? false) ? serverVersion! : '—',
          ),
        ),
      ],
    );
  }
}

/// Leaving, as the last row.
///
/// Outlined and in the error colour, not filled: leaving is not what this
/// screen is for, and a full-width filled button would make it the most
/// prominent thing on it. Signing out is reversible — the next sign-in restores
/// everything, because nothing in this app lives only on the device — so it
/// gets no confirmation dialog either.
class _SignOutButton extends ConsumerWidget {
  const _SignOutButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: ZugvogelSpacing.md),
      child: OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: Theme.of(context).colorScheme.error,
        ),
        icon: const Icon(Icons.logout),
        label: Text(l10n.authSignOutAction),
        // The router's gate does the navigating: clearing the session notifies
        // it and the redirect lands on the login screen. Nothing to pop here.
        onPressed: () async {
          final repo = await ref.read(authRepositoryProvider.future);
          repo.signOut();
        },
      ),
    );
  }
}
