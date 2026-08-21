import 'package:eiermann/l10n/l10n.dart';
import 'package:eiermann_models/eiermann_models.dart';

/// The sentence that stands next to a due date — **built in the client**.
///
/// Not delivered by the server, and that is a rule rather than a convenience:
/// the server does not know which language the reader speaks, so a German
/// sentence in a hook would be untranslatable by construction. The same reason
/// refusals travel as codes and audit rows store wire values.
///
/// It is built from the fields the rhythm actually wrote — `empty_streak`,
/// `interval_days`, the nest's status and species, and the follow-up's reason.
/// A date without its reason is a date people override; with the reason it
/// becomes a decision somebody can agree or disagree with.
///
/// What it deliberately does NOT say is "stretched to 14 days". The base
/// interval and the ladder live in `organisations.settings`, whose only reader
/// is the server's `zv_org.js` — mapping that JSON field a second time is the
/// trap that silently disabled federfall's org-configurable windows. So the
/// client states the two facts it holds and their order, and leaves the
/// comparison to whoever knows the ladder.
String? nestDueExplanation(AppLocalizations l10n, NestState nest) {
  // The two states that leave the due lists come first: for them the ABSENCE
  // of a date is the fact, and a rhythm sentence would suggest one is coming.
  if (nest.isGone) return l10n.dueExplainGone;
  if (nest.isProtected) return l10n.dueExplainProtected;

  final interval = nest.intervalDays;
  // No interval at all: a nest nobody has been to yet. Nothing is said here,
  // and that is not an omission — the nest line's own age column already reads
  // "noch nie geprüft", and a rhythm sentence repeating it would be the same
  // words twice on one line. The rhythm has nothing to explain until a check
  // has moved it.
  if (interval == null) return null;

  final streak = nest.emptyStreak ?? 0;
  return streak > 0
      ? l10n.dueExplainAfterEmpties(streak, interval)
      : l10n.dueExplainBase(interval);
}

/// The sentence for a whole building's due date.
///
/// A Spot's date is the MINIMUM over its nests and its open Nachkontrollen, so
/// the useful sentence is the one about whichever of those won. A half-clutch
/// follow-up usually does — that is the point of it — and then the sentence
/// names the nest, because "Nachkontrolle Halbgelege, N3" is what somebody
/// needs before they climb into an attic with four nests in it.
///
/// [followUps] are the OPEN ones; [nestLabelOf] resolves a follow-up's nest to
/// its label, because an id with no label next to it is a bug in this app.
String? spotDueExplanation(
  AppLocalizations l10n,
  Spot spot, {
  List<FollowUp> followUps = const [],
  List<NestState> nests = const [],
  String? Function(String nestId)? nestLabelOf,
}) {
  // The phases with no date at all. Said out loud rather than left blank: a
  // building with no due date and no explanation reads as an oversight.
  switch (spot.phase) {
    case SpotPhase.paused:
      return l10n.dueExplainPaused;
    case SpotPhase.closed:
      return l10n.dueExplainClosed;
    case SpotPhase.prospect:
      return l10n.dueExplainProspect;
    case SpotPhase.active:
    case null:
      break;
  }

  final due = spot.nextDueAt;
  final earliest = _earliestFollowUp(followUps);
  if (due != null && earliest != null && !_laterThan(earliest.dueAt, due)) {
    // The follow-up is what makes the Spot due, so it owns the sentence.
    if (earliest.reason == FollowUpReason.manual) {
      return l10n.dueExplainFollowUpManual;
    }
    final nestId = earliest.nest;
    final label = nestId == null ? null : nestLabelOf?.call(nestId);
    // No label rather than an id: an id with no label next to it is a bug in
    // this app, and "Nachkontrolle Halbgelege, hf83kd0" helps nobody.
    return label == null || label.isEmpty
        ? l10n.dueExplainFollowUpNoNest
        : l10n.dueExplainFollowUp(label);
  }

  // No nests recorded at all: the server's fallback puts the Spot one base
  // period out, and "empty does not mean done" is exactly the thing a reader
  // must not have to guess at.
  if (nests.isEmpty) return l10n.dueExplainNoNests;

  // Otherwise the nest lines carry their own explanations, and repeating the
  // loudest one at Spot level would say it twice on one screen.
  return null;
}

FollowUp? _earliestFollowUp(List<FollowUp> followUps) {
  FollowUp? best;
  for (final followUp in followUps) {
    if (!followUp.isOpen || followUp.dueAt == null) continue;
    if (best == null || followUp.dueAt!.isBefore(best.dueAt!)) best = followUp;
  }
  return best;
}

/// Whether [a] is later than [b] by more than a calendar day, on LOCAL days.
///
/// Local and truncated, like every date comparison here: the Spot's stored date
/// and the follow-up's are both timestamps, and comparing them raw would decide
/// "the follow-up is what makes this due" on a difference of hours.
bool _laterThan(DateTime? a, DateTime b) {
  if (a == null) return true;
  final left = a.toLocal();
  final right = b.toLocal();
  return DateTime(left.year, left.month, left.day).isAfter(
    DateTime(right.year, right.month, right.day),
  );
}
