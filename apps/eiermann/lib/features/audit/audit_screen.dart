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
/// (`audit_events.listRule`). There is no write side anywhere: the collection
/// has no create, update or delete rule at all, so the only way a row appears
/// is a hook deciding it should.
class AuditScreen extends ConsumerWidget {
  const AuditScreen({this.spotId, this.title, super.key});

  /// Narrow the log to everything that happened at one building. Null shows
  /// the whole org's.
  final String? spotId;

  /// What that building is called, for the app bar. Passed in rather than
  /// looked up: it may not exist any more, which is precisely the case where
  /// this screen is most worth opening.
  final String? title;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = context.l10n;
    final log = ref.watch(auditLogProvider(spotId));

    return Scaffold(
      appBar: AppBar(title: Text(title ?? l10n.auditTitle)),
      body: AsyncValueView<AuditLogState>(
        value: log,
        onRetry: () => ref.invalidate(auditLogProvider(spotId)),
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
                              .read(auditLogProvider(spotId).notifier)
                              .loadMore(),
                        ),
                        onRetry: () => unawaited(
                          ref
                              .read(auditLogProvider(spotId).notifier)
                              .retryPage(),
                        ),
                      );
                    }
                    return _EntryTile(event: state.entries[index]);
                  },
                ),
              ),
      ),
    );
  }
}

/// One recorded act.
class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.event});

  final AuditEvent event;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final materialL10n = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final subtle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );

    // WHICH building, when that is not already what the row is about. A Besuch
    // names its Spot; a Spot's own row would otherwise print its name twice.
    final spot = event.spotLabel ?? '';
    final subject = event.subjectLabel ?? '';
    final showSpot = spot.isNotEmpty && spot != subject;

    final detail = _detailLine(l10n, event);

    return ListTile(
      leading: Icon(auditSubjectIcon(event.subjectCollection)),
      title: Text(auditActionLabel(l10n, event.action)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // WHAT it was about, by the name it had then. Never resolved live —
          // see the screen's doc.
          if (subject.isNotEmpty)
            Text(subject, style: theme.textTheme.bodyMedium),
          if (showSpot) Text(spot, style: subtle),
          // One line per field that moved. The same renderer serves a
          // create, a delete and an update, which is what the shared
          // `changes` shape buys.
          for (final change in event.changes)
            Text(_changeLine(l10n, change), style: theme.textTheme.bodySmall),
          if (detail != null) Text(detail, style: subtle),
          Text(
            _byLine(l10n, materialL10n, event),
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

/// One changed field, as a sentence.
///
/// Four shapes, and the distinctions are all load-bearing:
///
///   * REDACTED is not an empty value. The log kept the fact of the change and
///     dropped the value on purpose — a caretaker's phone number, a password,
///     prose somebody can still correct. Rendering it as blank would tell the
///     reader nothing happened.
///   * No previous value is not an empty one. An invitation has no `from`: the
///     account did not exist a moment ago, and an empty side of an arrow reads
///     as a value that was blanked.
///   * Cleared IS the empty one, and says what it used to be.
///   * Everything else is a move from one value to another.
String _changeLine(AppLocalizations l10n, AuditChange change) {
  final field = auditFieldLabel(l10n, change.field);
  if (change.redacted) return l10n.auditRedacted(field);

  // The label the target had when the row was written, in preference to its
  // id. An id in an audit row with no label beside it is a bug.
  final from = change.fromLabel ?? change.from ?? '';
  final to = change.toLabel ?? change.to ?? '';

  final line = switch ((from.isEmpty, to.isEmpty)) {
    (true, false) => l10n.auditChangeInitial(
      field,
      auditValueLabel(l10n, change.field, to),
    ),
    (false, true) => l10n.auditChangeCleared(
      field,
      auditValueLabel(l10n, change.field, from),
    ),
    _ => l10n.auditChange(
      field,
      auditValueLabel(l10n, change.field, from),
      auditValueLabel(l10n, change.field, to),
    ),
  };
  // Said out loud rather than left as a silently shortened quote in a document
  // people cite.
  return change.truncated ? '$line${l10n.auditTruncatedSuffix}' : line;
}

/// The action-specific payload, as one line, or null when it says nothing.
///
/// Only SCALAR entries whose key this app has a word for. The rest of a detail
/// is either a nested count map — a Besuch's states and finding kinds, which
/// belong in the Besuch itself rather than in a log line — or a `from`/`to`
/// pair that the change lines above have already said better.
String? _detailLine(AppLocalizations l10n, AuditEvent event) {
  final parts = <String>[];
  for (final entry in event.detail.entries) {
    final value = entry.value;
    if (value == null || value is Map || value is List) continue;
    if (entry.key == 'from' || entry.key == 'to') continue;
    final text = value is bool
        ? (value ? l10n.auditValueYes : l10n.auditValueNo)
        : value.toString();
    if (text.isEmpty) continue;
    parts.add('${auditFieldLabel(l10n, entry.key)}: $text');
  }
  return parts.isEmpty ? null : parts.join(' · ');
}

/// Who did it and when.
///
/// The actor KIND is named only when it is not a person: a Spot that left a
/// pause was decided by a schedule, and a row that could only say "System"
/// would leave the reader guessing which of them did it.
String _byLine(
  AppLocalizations l10n,
  MaterialLocalizations materialL10n,
  AuditEvent event,
) {
  final kind = auditActorKindLabel(l10n, event.actorKind);
  final who = event.actorLabel.isNotEmpty
      ? event.actorLabel
      : (kind ?? l10n.auditActorSystem);
  final named = kind != null && kind != who ? '$who ($kind)' : who;
  return l10n.auditByOn(
    named,
    // Every DateTime→text conversion in this app goes through
    // `formatLocalDate`: PocketBase stores UTC, and in CET everything after
    // 22:00 UTC would otherwise show the previous day. Invisible on a UTC CI
    // machine, and it reaches readers one screen at a time.
    event.createdAt == null
        ? ''
        : formatLocalDate(materialL10n, event.createdAt, withTime: true),
  );
}
