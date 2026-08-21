import 'package:eiermann/core/auth/session.dart';
import 'package:eiermann/features/home/sign_out_action.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// What an account sees that is signed in and not let in.
///
/// Reachable one way: signing in through an identity provider where no group
/// mapped the person onto a role, so `oauth2_provisioning.pb.js` provisioned
/// them as a `guest`. Every access rule in the database refuses that role by
/// name, so there is no app behind this screen — showing the dashboard would be
/// a wall of empty lists and an invitation to create a Spot the server then
/// refuses with a 403.
///
/// Three things it has to do, and nothing else:
///
/// * say that this is a decision somebody has to make, not an error to retry —
///   a reader who thinks the app is broken will reload it all afternoon;
/// * name the address the account carries, because the most common cause is
///   signing in under a different one than the group knows;
/// * offer the way out that exists: sign out, and come back with the invited
///   address.
class PendingScreen extends ConsumerWidget {
  const PendingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    // Read for the ADDRESS only, and tolerate its absence: the gate has already
    // decided this screen is the right one, so a profile that is still loading
    // must not turn it into a spinner.
    final email = ref.watch(currentUserProvider).value?.email;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.pendingTitle),
        actions: const [SignOutAction()],
      ),
      body: Center(
        child: ContentBounds(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(ZugvogelSpacing.lg),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.hourglass_top_outlined,
                  size: 56,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: ZugvogelSpacing.md),
                Text(
                  l10n.pendingHeadline,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: ZugvogelSpacing.sm),
                Text(
                  l10n.pendingMessage,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                if (email != null) ...[
                  const SizedBox(height: ZugvogelSpacing.md),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(ZugvogelSpacing.md),
                      child: Column(
                        children: [
                          Text(
                            l10n.pendingSignedInAs,
                            style: theme.textTheme.labelLarge?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                          const SizedBox(height: ZugvogelSpacing.xs),
                          Text(email, style: theme.textTheme.bodyLarge),
                          const SizedBox(height: ZugvogelSpacing.xs),
                          Text(
                            l10n.pendingWrongAddressHint,
                            style: theme.textTheme.bodySmall,
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
