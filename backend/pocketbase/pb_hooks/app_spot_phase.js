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

/** German labels, because the message goes to a user, not a log. */
const LABEL = {
  prospect: "Erkundung",
  active: "aktiv",
  paused: "pausiert",
  closed: "abgeschlossen",
};

/**
 * Rejects an illegal transition and normalises the fields the server owns.
 *
 * [record] is the incoming record with the submitted changes already applied;
 * [previous] is the phase it is leaving, or `null` on create.
 */
function apply(record, previous) {
  const next = String(record.get("phase") || "");
  if (!LABEL[next]) {
    throw new BadRequestError(`Unbekannte Phase: ${next}.`);
  }

  if (previous !== null && previous !== next) {
    const allowed = ALLOWED[previous] || [];
    if (allowed.indexOf(next) === -1) {
      // Naming the legal moves matters: the client can only offer the right
      // buttons if it knows them, and a bare "invalid transition" turns into a
      // support question.
      const options = allowed.map((phase) => LABEL[phase]).join(", ") || "keine";
      throw new BadRequestError(
        `Ein Spot kann nicht von "${LABEL[previous]}" nach "${LABEL[next]}" ` +
          `wechseln. Möglich ist: ${options}.`,
      );
    }
  }

  if (next === "active" && previous === "prospect") {
    // The one legal risk in the whole product is entering a building nobody
    // agreed to. So activation is gated on the Erkundung having actually
    // reached a yes — not on somebody remembering to check.
    const stage = String(record.get("prospect_stage") || "");
    if (stage !== "permitted") {
      // No wire value in the message. `prospect_stage` holds strings like
      // "tenant_spoken", and interpolating one into German prose yields a
      // sentence half in each language — the thing keeping vocabulary in the
      // client is meant to prevent.
      //
      // The obvious alternative was to pass it as the error's `data` so the
      // client could translate it. That does not work: PocketBase coerces
      // EVERY leaf of an ApiError's data into `{code, message}`, at any depth.
      // `{stageWire: "untouched"}` arrives as
      // `{stageWire: {code: "validation_invalid_value", message: "Invalid
      // value."}}`. The channel is structurally a field-name → validation-error
      // map and cannot carry a value. Verified against a live instance.
      //
      // Which is fine here: the client is holding the record it just tried to
      // update, so it already knows the stage. The message only has to stand
      // alone for whoever reads the raw error.
      // „Erlaubt" is the word the client puts on that stage
      // (`prospectStagePermitted`). This message is now user-visible copy, so
      // naming the stage anything else sends somebody looking through the
      // Erkundung for a word that is not there.
      throw new BadRequestError(
        'Ein Spot wird erst aktiv, wenn die Erkundung bei „Erlaubt" steht.',
      );
    }
  }

  if (next === "paused") {
    // A Spot that went quiet without saying why is indistinguishable from a
    // forgotten one, which is the exact failure this app exists to remove.
    if (!String(record.get("pause_reason") || "").trim()) {
      throw new BadRequestError("Eine Pause braucht einen Grund.");
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
    if (!reason && !(previous === "prospect" && refused)) {
      throw new BadRequestError(
        "Ein Abschluss braucht einen Grund — sonst ist später nicht mehr " +
          "erkennbar, ob es sich lohnt, erneut zu fragen.",
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

module.exports = { apply, setDue, ALLOWED, LABEL };
