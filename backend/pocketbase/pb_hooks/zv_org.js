/// <reference path="../pb_data/types.d.ts" />

// federfall-jumi — the org's `settings` JSON, read in ONE place.
//
// Usage — `require()` INSIDE the handler/callback, never at file level, and
// always with the `${__hooks}` absolute form (see zv_audit.js):
//
//   const orgs = require(`${__hooks}/zv_org.js`);
//   const days = orgs.positiveNumber(
//     orgs.settingsOf(e.app, orgId), "quarantineDefaultDays", 14);
//
// ── Why this is a module and not four copies ────────────────────────────────
// `record.get(<json field>)` hands JS a `types.JSONRaw` — a BYTE ARRAY, not a
// decoded object (verified on PocketBase 0.39.8). So `settings.someKey` is
// ALWAYS `undefined` and the caller silently falls through to its default,
// with no error anywhere. `getString()` returns the raw JSON text, which
// parses.
//
// That trap had been written five times in federfall: correctly in three
// places, and wrongly in exactly the two that were written without copying
// from a correct one. Two shipped, documented features (an org-configurable
// GDPR retention window and a quarantine default) were silently inert for
// every org because of it. One reader means one place left to get it wrong —
// which is also why this module is shared rather than copied per app.
//
// (Passing `get()`'s value straight back to Go — `e.json(200, rec.get("x"))` —
// is fine; JSONRaw marshals correctly. Only property access in JS is broken,
// which is why a route that only forwards a JSON field is deliberately not a
// caller here.)
//
// STATELESS, like every zv_ module: PocketBase pools JSVMs and each pooled VM
// holds its own instance, so nothing may be cached between calls — an org's
// settings are re-read per use.
//
// `organisations` is a shared convention, not a coincidence: both apps'
// migrations create a collection of that name with a `settings` JSON field,
// because this module and zv_org_scope.js both depend on it.

/**
 * The decoded `organisations.settings` object for [orgId].
 *
 * Returns `{}` for a missing org, empty settings or unparseable JSON: every
 * caller's answer to "no settings" is its own documented default, and a
 * throwing reader would turn a blank field into a failed write or a dead cron.
 */
function settingsOf(app, orgId) {
  if (!orgId) return {};
  try {
    const org = app.findRecordById("organisations", String(orgId));
    const parsed = JSON.parse(org.getString("settings") || "{}");
    return parsed && typeof parsed === "object" ? parsed : {};
  } catch (_) {
    return {};
  }
}

/**
 * A strictly positive number setting, else [fallback].
 *
 * Zero is refused on purpose: these values are windows (retention years,
 * quarantine days), and a zero window means "expire everything now" — not
 * something a blank or fat-fingered field should be able to say. A setting
 * where zero is a legitimate instruction passes `{ allowZero: true }` and has
 * to handle it explicitly (federfall's audit retention reads 0 as "disabled").
 */
function positiveNumber(settings, key, fallback, opts) {
  const allowZero = !!(opts && opts.allowZero);
  if (!settings || settings[key] === undefined || settings[key] === null) {
    return fallback;
  }
  const n = parseFloat(settings[key]);
  if (isNaN(n)) return fallback;
  return n > 0 || (allowZero && n === 0) ? n : fallback;
}

/**
 * An ascending list of positive numbers, else [fallback].
 *
 * For settings that are LADDERS — eiermann's `interval_steps` ([7, 14, 28]:
 * base, stretched, cap). Three properties are checked rather than assumed,
 * because each failure is silent and lands somewhere far away:
 *
 *   * not an array, or empty → the whole ladder is missing, and a caller
 *     indexing into it gets `undefined`, which becomes `NaN` in a date
 *     computation and a nest that is never due again;
 *   * a non-number or a non-positive entry → same, one rung in;
 *   * not ascending → the "cap" is not the largest value, so a nest that has
 *     been empty longest gets checked most often. Nothing errors; the rhythm
 *     just quietly inverts.
 *
 * A rejected ladder falls back WHOLE. Repairing it entry by entry would produce
 * a third ladder that neither the admin nor this code intended.
 */
function positiveNumberList(settings, key, fallback) {
  const raw = settings ? settings[key] : null;
  if (!Array.isArray(raw) || raw.length === 0) return fallback;
  const out = [];
  for (const entry of raw) {
    const n = parseFloat(entry);
    if (isNaN(n) || n <= 0) return fallback;
    if (out.length && n < out[out.length - 1]) return fallback;
    out.push(n);
  }
  return out;
}

/** True only when the org explicitly opted in — anything else is off. */
function flag(settings, key) {
  return !!settings && settings[key] === true;
}

module.exports = {
  settingsOf: settingsOf,
  positiveNumber: positiveNumber,
  positiveNumberList: positiveNumberList,
  flag: flag,
};
