/// <reference path="../pb_data/types.d.ts" />

// How a hook refuses a write: with a CODE, never with a sentence.
//
// ── Why not a sentence ─────────────────────────────────────────────────────
//
// The server does not know which language the reader speaks. A German string in
// a hook is untranslatable by construction, and this app is localised — so the
// hook says WHICH invariant it refused and the client says what that means. It
// is the same rule the rhythm explanation follows (built in the client) and the
// audit trail follows (wire values, translated on display).
//
// ── Why the code goes in `data` and not in `message` ───────────────────────
//
// Measured against PocketBase 0.39.8, not assumed:
//
//   * `data` VALUES never survive. Every leaf is rewritten to
//     `{code: "validation_invalid_value", message: "Invalid value."}` at any
//     depth — an already correctly-shaped `{code, message}` is re-coerced and
//     nested one level deeper.
//   * The `data` KEY survives verbatim. That is the whole channel.
//   * `message` is rewritten too: throwing "plain" produces "Plain."
//     Capitalised, full-stopped. So it cannot carry an exact token either, and
//     is left as an English developer line for the log.
//
// ── The codes are wire values ──────────────────────────────────────────────
//
// Exactly like the enums: renaming one is a wire change, because the client maps
// it to an ARB key. They are named for the CONDITION rather than for the
// sentence, so several call sites can share one where the client would say the
// same thing.

/**
 * Refuses the request with [code], and [devMessage] for the log.
 *
 * [devMessage] is addressed to whoever reads server logs, never to a user —
 * nothing in the client reads it. So it says what a developer needs, and
 * PocketBase rewrites it anyway (capitalising it and appending a full stop).
 *
 * [status] defaults to 400. It exists so that EVERY refusal in this app can go
 * through this function: the idempotency-key clash is a 409, and if that had to
 * throw its own `ApiError` then the rule "no hook throws directly" would need an
 * exception, and a sweep with an exception is a sweep somebody widens.
 */
function refuse(code, devMessage, status) {
  throw new ApiError(status || 400, devMessage, { [code]: 1 });
}

/**
 * Every code this app can refuse with.
 *
 * Listed rather than passed as bare strings so a typo is a `ReferenceError`
 * against this object at request time instead of a code the client silently
 * fails to translate — which would look exactly like a generic failure. The
 * rule-test suite asserts each one appears in a real refusal.
 */
const CODES = {
  // ── Accounts ──
  userFieldNotWritable: "user_field_not_writable",

  // ── Spot lifecycle ──
  spotPhaseUnknown: "spot_phase_unknown",
  spotPhaseIllegalTransition: "spot_phase_illegal_transition",
  spotPhaseNeedsPermitted: "spot_phase_needs_permitted",
  spotPauseNeedsReason: "spot_pause_needs_reason",
  spotCloseNeedsReason: "spot_close_needs_reason",

  // ── Bereiche: the photo-replacement review pass ──
  areaReviewFieldNotWritable: "area_review_field_not_writable",

  // ── Nests ──
  nestNeedsArea: "nest_needs_area",
  nestAreaNotFound: "nest_area_not_found",
  nestPinNotNumeric: "nest_pin_not_numeric",
  nestProtectedNeedsCoordinator: "nest_protected_needs_coordinator",
  nestProtectedNoEggChanges: "nest_protected_no_egg_changes",

  // ── The visit transaction ──
  visitNeedsSpot: "visit_needs_spot",
  visitSpotNotFound: "visit_spot_not_found",
  visitOutcomeInvalid: "visit_outcome_invalid",
  visitSkipNeedsReason: "visit_skip_needs_reason",
  visitSkipHasChecks: "visit_skip_has_checks",
  visitCheckNeedsNest: "visit_check_needs_nest",
  visitNestNotFound: "visit_nest_not_found",
  visitNestDuplicate: "visit_nest_duplicate",
  visitNestForeignSpot: "visit_nest_foreign_spot",
  visitEggsRemovedExceedPresent: "visit_eggs_removed_exceed_present",
  visitEggsDoNotBalance: "visit_eggs_do_not_balance",
  visitIdempotencyKeyReused: "visit_idempotency_key_reused",
};

module.exports = { refuse, CODES };
