import 'dart:async';

import 'package:eiermann/features/audit/audit_labels.dart';
import 'package:eiermann/features/audit/audit_providers.dart';
import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zugvogel_ui/zugvogel_ui.dart';

/// The log: who changed what, and what it used to say.
///
/// **What this screen is for.** A handful of acts in this app are hard to undo
/// and easy to do quietly — releasing a protected nest, closing a building,
/// granting the coordination, stretching the interval every due date comes out
/// of. None of them leaves a trace in the record it changed: a Spot holds its
/// CURRENT phase, a user their CURRENT role. Only these rows say "since when,
/// and who decided".
///
/// **Everything here is text captured when the act happened**, never a live
/// lookup. That is what makes the log honest about the past: a building that
/// has since been renamed still shows the name it was closed under, and one
/// that has been DELETED still shows anything at all. The ids are stored as
/// plain text for the same reason — a relation would have had to choose between
/// cascading (a deletion erasing the record of itself) and dangling.
///
/// The coordination's alone to read, which the server enforces
/// (`audit_entries.listRule`). There is no write side anywhere: the collection
/// has no create, update or delete rule at all, so the only way a row appears
/// is a hook deciding it should.
class AuditScreen extends ConsumerWidget {
  const AuditScreen({this.targetId, this.title, super.key});

  /// Narrow the log to one Spot, nest or account. Null shows the whole org's.
  final String? targetId;

  /// What that target is called, for the app bar. Passed in rather than looked
  /// up: the target may not exist any more, which is precisely the case where
  /// this screen is most worth opening.
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final log = ref.watch(auditLogProvider(targetId));

    return Scaffold(
      appBar: AppBar(title: Text(title ?? l10n.auditTitle)),
      body: AsyncValueView<AuditLogState>(
        value: log,
        onRetry: () => ref.invalidate(auditLogProvider(targetId)),
        data: (state) => state.entries.isEmpty
            ? EmptyView(
                icon: Icons.history,
                title: l10n.auditEmptyTitle,
                message: l10n.auditEmptyMessage,
              )
            : ContentBounds(
                child: ListView.separated(
                  padding: const EdgeInsets.symmetric(
                    vertical: ZugvogelSpacing.sm,
                  ),
                  itemCount: state.entries.length + (state.hasMore ? 1 : 0),
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    if (index >= state.entries.length) {
                      return PagedListTail(
                        error: state.pageError,
                        onLoad: () => unawaited(
                          ref
                              .read(auditLogProvider(targetId).notifier)
                              .loadMore(),
                        ),
                        onRetry: () => unawaited(
                          ref
                              .read(auditLogProvider(targetId).notifier)
                              .retryPage(),
                        ),
                      );
                    }
                    return _EntryTile(entry: state.entries[index]);
                  },
                ),
              ),
      ),
    );
  }
}

/// One recorded act.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry});

  final AuditEntry entry;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final materialL10n = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final field = entry.field ?? '';

    return ListTile(
      leading: Icon(auditTargetIcon(entry.targetType)),
      title: Text(auditActionLabel(l10n, entry.action)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // WHAT it was about, by the name it had then. Never resolved live —
          // see the screen's doc.
          if ((entry.targetLabel ?? '').isNotEmpty)
            Text(entry.targetLabel!, style: theme.textTheme.bodyMedium),
          if (entry.isChange)
            Text(
              entry.hasNoPrevious
                  // An invite has no previous value: the account did not exist
                  // a moment ago. Saying so beats rendering an empty side of an
                  // arrow, which reads as a value that was blanked.
                  ? l10n.auditChangeInitial(
                      auditFieldLabel(l10n, field),
                      auditValueLabel(l10n, field, entry.toValue ?? ''),
                    )
                  : l10n.auditChange(
                      auditFieldLabel(l10n, field),
                      auditValueLabel(l10n, field, entry.fromValue ?? ''),
                      auditValueLabel(l10n, field, entry.toValue ?? ''),
                    ),
              style: theme.textTheme.bodySmall,
            ),
          if ((entry.detail ?? '').isNotEmpty)
            Text(
              entry.detail!,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          Text(
            // Every DateTime→text conversion in this app goes through
            // `formatLocalDate`: PocketBase stores UTC, and in CET everything
            // after 22:00 UTC would otherwise show the previous day. Invisible
            // on a UTC CI machine, and it reaches readers one screen at a time.
            l10n.auditByOn(
              entry.actorLabel.isEmpty
                  ? l10n.auditActorSystem
                  : entry.actorLabel,
              entry.createdAt == null
                  ? ''
                  : formatLocalDate(
                      materialL10n,
                      entry.createdAt,
                      withTime: true,
                    ),
            ),
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
