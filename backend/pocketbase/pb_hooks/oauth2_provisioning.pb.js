/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.18 — what happens when somebody signs in through an identity
// provider.
//
// An OAuth2 sign-in arrives in one of two shapes. Either an account with that
// address already exists, and PocketBase links the external identity to it —
// that is the whole point of the feature, and it passes straight through. Or no
// account matches, and PocketBase would create one. THAT is what this hook
// refuses.
//
// ── Why eiermann does not self-register, though federfall does ─────────────
//
// This file is deliberately NOT a copy of federfall's
// `oauth2_provisioning.pb.js`, and the difference is not a preference. The
// shared library (`zv_oauth2_provisioning.js`) provisions a new account into a
// WALLED-OFF ROLE: a role value the collection can store that every access rule
// then refuses. federfall has one — `guest`. eiermann has no such role and must
// not gain one:
//
//   * every access rule here opens with `role != null`, so the wall is the
//     ABSENCE of a role, not a particular one;
//   * adding a `guest` value to `users.role` would therefore satisfy that
//     clause and hand a self-registered stranger member-level read access to
//     every Spot in the org. The rules would have to be rewritten one by one to
//     name allowed roles, and a sweep cannot catch the one that was missed.
//
// The library cannot express "no role" either, because it needs a value to
// write, and `users.org` is a required relation — so a record with neither
// cannot be created at all. Which leaves two honest options: teach the shared
// library a role-less wall (a zugvogel change, tracked as eiermann-vx4), or
// refuse the creation here. Until the first lands, this is the second.
//
// Refusing is not a placeholder, though. It matches how membership works in
// this app: the first coordinator comes from the environment, everybody else is
// invited, and `users.invited_by` records who by. An identity provider says WHO
// somebody is; it does not say that a pigeon group wants them in its data.
//
// ── The refusal is a 403 with no German in it ─────────────────────────────
//
// `ForbiddenError` rather than app_refuse.js's coded refusal, and the rule-suite
// sweep exempts exactly these two error types for the reason that applies here:
// the STATUS is the whole message. Every client already maps 401 and 403 to its
// own copy, and there is no app invariant to name — "you have no account here"
// needs no code. The string below is an English developer line for the log.

onRecordAuthWithOAuth2Request((e) => {
  // An existing account: PocketBase has matched it and is linking the identity.
  // Nothing to decide.
  if (!e.isNewRecord) {
    e.next();
    return;
  }

  // No account for this address. Logged with the provider and the address,
  // because the person on the other end sees only a 403 and will ask somebody —
  // and that somebody needs to be able to tell "not invited yet" from "invited
  // under a different address", which is the mistake this refusal produces most.
  const provider = e.providerName ? String(e.providerName) : "unknown";
  const address = e.oAuth2User && e.oAuth2User.email
    ? String(e.oAuth2User.email)
    : "";
  e.app
    .logger()
    .warn(
      "eiermann: refused an oauth2 sign-in with no account",
      "provider",
      provider,
      "email",
      address,
    );

  throw new ForbiddenError(
    "no eiermann account for this identity; membership is by invitation",
    null,
  );
});
