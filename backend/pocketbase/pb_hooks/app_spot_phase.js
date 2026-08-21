/// <reference path="../pb_data/types.d.ts" />

// The Spot lifecycle: which phase may follow which, what each transition must
// be accompanied by, and which fields the server owns.
//
// A MODULE, not a hook file. Handlers `require()` it inside themselves, which
// is why file-level bindings here are fine — a module is loaded into the
// handler's own context. In a `.pb.js` the same code would be out of scope at
// request time (see CLAUDE.md, and the sweep that enforces it).
//
// Why a hook at all, when this could be a select field with an access rule: a
// plain field reference in an UPDATE rule resolves against the STORED record,
// so a rule can see the phase a Spot is LEAVING but not the one it is entering.
// A transition is a statement about both. Rules stay the security boundary;
// this is an invariant, and invariants need a hook.

/**
 * Which phase may follow which.
 *
 * Three absences are deliberate:
 *
 *   * `prospect -> paused`. There is nothing to pause: an Erkundung either
 *     continues or ends. A pause would be a Spot that looks scheduled while
 *     nobody has agreed to anything.
 *   * anything `-> prospect`. Permission, once obtained, is not un-learned.
 *     Losing it is `closed` with `permission_withdrawn`, which keeps the
 *     history; going back to prospect would erase the fact that access existed.
 *   * `closed -> paused`. Reopening means somebody is going back, so it lands
 *     in `active` and can be paused from there. Two steps, because "closed,
 *     then paused" is a state nobody can act on.
 */
const ALLOWED = {
  prospect: ["active", "closed"],
  active: ["paused", "closed"],
  paused: ["active", "closed"],
  closed: ["active"],
};

/**
 * The phases, for the developer-facing log line only.
 *
 * These used to be German labels, back when the refusal carried a sentence. The
 * sentence is the client's now (eiermann-8ct) and these exist purely so a log
 * reader can see which transition was attempted.
 */
const PHASES = ["prospect", "active", "paused", "closed"];

/**
 * Rejects an illegal transition and normalises the fields the server owns.
 *
 * [record] is the incoming record with the submitted changes already applied;
 * [previous] is the phase it is leaving, or `null` on create.
 */
function apply(record, previous) {
  const { refuse, CODES } = require(`${__hooks}/app_refuse.js`);
  const next = String(record.get("phase") || "");
  if (PHASES.indexOf(next) === -1) {
    refuse(CODES.spotPhaseUnknown, `unknown phase: ${next}`);
  }

  if (previous !== null && previous !== next) {
    const allowed = ALLOWED[previous] || [];
    if (allowed.indexOf(next) === -1) {
      // One code for the whole condition, not one per pair. The client holds the
      // same transition graph — it draws the buttons from it — so it can name
      // the legal moves itself, in the reader's language, without the server
      // enumerating them.
      refuse(
        CODES.spotPhaseIllegalTransition,
        `illegal phase transition ${previous} -> ${next}`,
      );
    }
  }

  if (next === "active" && previous === "prospect") {
    // The one legal risk in the whole product is entering a building nobody
    // agreed to. So activation is gated on the Erkundung having actually
    // reached a yes — not on somebody remembering to check.
    const stage = String(record.get("prospect_stage") || "");
    if (stage !== "permitted") {
      // The stage is not sent back and neither is a sentence. `data` carries a
      // code as a KEY but never a value — every leaf is rewritten to
      // `{code, message}` at any depth — and the client is holding the record it
      // just tried to update, so it already knows the stage. What it does not
      // know is which rule refused, and that is exactly what the code says.
      refuse(
        CODES.spotPhaseNeedsPermitted,
        `activation requires prospect_stage=permitted, was ${stage || "unset"}`,
      );
    }
  }

  if (next === "paused") {
    // A Spot that went quiet without saying why is indistinguishable from a
    // forgotten one, which is the exact failure this app exists to remove.
    if (!String(record.get("pause_reason") || "").trim()) {
      refuse(CODES.spotPauseNeedsReason, "pause requires pause_reason");
    }
  } else {
    // Current state, not history: a resumed Spot showing "pausiert wegen
    // Gerüst" forever would be read as still paused. The transition itself
    // belongs in the audit trail, which is where history lives.
    record.set("pause_reason", "");
    record.set("paused_until", "");
  }

  if (next === "closed") {
    // Six months on, "closed" alone cannot answer the only question anybody
    // asks of a closed Spot: do we try again? Netted and refused are opposite
    // answers.
    const reason = String(record.get("closed_reason") || "");
    const refused = String(record.get("prospect_stage") || "") === "refused";
    // Only on the way IN. `previous !== next` is what makes this a rule about
    // the transition rather than about every later write, and leaving it out
    // was a trap: a Spot closed from a REFUSED Erkundung legitimately carries
    // no closed_reason, so re-checking on each update meant every subsequent
    // write to it was refused — a note, a corrected name, anything. Measured
    // against a live instance: 400 on a PATCH that only touched `note`.
    //
    // A create still needs one, because `previous` is null there and null is
    // never equal to "closed".
    if (!reason && previous !== next && !(previous === "prospect" && refused)) {
      refuse(
        CODES.spotCloseNeedsReason,
        "closing requires closed_reason unless a refused prospect",
      );
    }
    // Server-owned, like next_due_at: a client that can write the closing date
    // can backdate a decision nobody made.
    if (!String(record.get("closed_at") || "")) {
      record.set("closed_at", new DateTime().string());
    }
  } else {
    record.set("closed_reason", "");
    record.set("closed_at", "");
  }
}

/**
 * Puts the Spot's derived `next_due_at` on [record], ready for the write that is
 * about to happen.
 *
 * The phase decides whether a Spot has a due date at all — a paused, closed or
 * prospecting one has none, an active one has the minimum over its nests and
 * open follow-ups — so every transition has to re-derive it. This computes
 * nothing itself: it asks the rhythm library, which is what the visit endpoint
 * asks too. A second implementation of the same date is a bug even while it
 * agrees.
 *
 * Left out, both directions state something false. A paused Spot keeps the date
 * it had and its row in the list reads "Pausiert · fällig am 3. August" — two
 * statements that cannot both be true. A Spot activated out of an Erkundung has
 * no date at all, so it sits there as "Im Rhythmus" with nothing behind it and
 * never becomes due.
 *
 * Call BEFORE `e.next()`, so the field rides along on the one save. After it the
 * reply is already on the wire: a record mutated then, or saved a second time,
 * answers the client with the value it just replaced — measured, and it is what
 * this function used to do.
 */
function setDue(app, record) {
  record.set(
    "next_due_at",
    require(`${__hooks}/app_rhythm.js`).spotDueFor(app, record),
  );
}

module.exports = { apply, setDue, ALLOWED, PHASES };
