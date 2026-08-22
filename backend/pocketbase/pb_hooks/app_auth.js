/// <reference path="../pb_data/types.d.ts" />

// eiermann-fi2.3 — the gate every custom route opens with, in ONE place.
//
// ── Why this exists ────────────────────────────────────────────────────────
//
// A custom route does not inherit an access rule. Whatever the collections say,
// a `routerAdd` handler sees a raw authenticated caller and has to state the
// clause itself — and each of the three routes here restated it by hand:
//
//     if (!auth.getBool("is_active") || !auth.getString("role")) …
//
// That is the PRE-014 clause, and it is wrong for exactly the reason migration
// 014 rewrote every rule in the database: `guest` — where a self-registered
// OAuth2 account lands, behind the wall — IS a non-null role. Measured, not
// reasoned: a guest account got a 200 and a complete PDF of every address the
// organisation holds out of `/api/eiermann/reports/period`, and the same clause
// in visit.pb.js let it write a Besuch.
//
// So the check names the roles that may pass, like the access rules do:
//
//     (role = "member" || role = "coordinator")
//
// An allowlist and not `role != "guest"`, and the difference only shows up on
// the day somebody adds the NEXT role: a denylist lets it through by default,
// which is the failure this whole shape exists to undo, one role later.
//
// It lives in a module because a module is the one thing isolated JSVM handlers
// can share — and because the alternative is what happened: four copies, three
// of them the old clause. The rule suite sweeps every `routerAdd` in this
// directory for a call to it.

/**
 * The caller, refused unless they are an active member or coordinator of an
 * organisation.
 *
 * Returns `{auth, org, role}` — `org` because every route needs it immediately
 * afterwards and reading it separately is how a route ends up scoped to nothing.
 *
 * Throws `UnauthorizedError` / `ForbiddenError` rather than an app refusal code,
 * and that is deliberate: their STATUS is the whole message. 401 and 403 map to
 * localized copy in every client already, and there is no app invariant to name
 * — "you are not signed in" needs no code.
 */
function requireMember(e) {
  const auth = e.auth;
  if (!auth) throw new UnauthorizedError("authentication required");
  if (!auth.getBool("is_active")) {
    // Repeated here for the same reason it is repeated in every access rule: if
    // `is_active` only gated sign-in, a deactivated member would keep working
    // until their token expired — up to five days.
    throw new ForbiddenError("account is not active");
  }
  const role = auth.getString("role");
  if (role !== "member" && role !== "coordinator") {
    throw new ForbiddenError("account has no role that may pass");
  }
  const org = auth.getString("org");
  if (!org) throw new ForbiddenError("account has no organisation");
  return { auth: auth, org: org, role: role };
}

module.exports = { requireMember: requireMember };
