/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.18 — provisioning a `users` record for somebody arriving through
// an identity provider.
//
// zv_oauth2_provisioning.js holds the mechanics and the reasoning: why the email
// is resolved from the provider's raw claims rather than trusted from one field,
// why the role is decided by the FIRST matching group so the most privileged
// entry has to come first, and why the very first account on an instance is a
// special case that two concurrent sign-ins could both believe they are.
//
// What stays here is eiermann's vocabulary — its roles, its group variables, its
// seeded org — plus the one thing this app had to build before any of it could
// work.
//
// ── The wall this depends on ───────────────────────────────────────────────
//
// A provisioned account lands in `guest`: authenticated, and behind every access
// rule. That role exists only since migration 014, and it could not simply be
// added — `guest` satisfies the `role != null` clause that every rule in this
// database used to open with, so storing it would have handed a stranger at the
// identity provider member-level read access to every Spot in the organisation.
// 014 rewrote every rule to NAME the roles that may pass. The rule suite sweeps
// for that shape and checks a real guest against a full database; if either ever
// fails, this hook is the reason it matters.
//
// ── Who becomes what ──────────────────────────────────────────────────────
//
// The group variables are optional and unset by default, which means: on an
// instance that configures OIDC and nothing else, everybody who signs in lands
// as a guest and a coordinator lets them in. Set them to map the provider's
// groups straight onto roles — the order below is the privilege order, and the
// first match wins.
//
// `EIERMANN_OIDC_ALLOWED_GROUPS` is the other half an operator may want: with it
// set, an account outside those groups is refused registration outright instead
// of landing as a guest. Worth it for an instance whose identity provider holds
// far more people than the pigeon group.

onRecordAuthWithOAuth2Request((e) =>
  require(`${__hooks}/zv_oauth2_provisioning.js`).provision(e, {
    envPrefix: "EIERMANN",
    // Written by this app's own seed migration, which is why the id is the
    // app's to state rather than the library's to know.
    defaultOrgId: "org00000default",
    roles: {
      // Authenticated and not yet let in. Every access rule refuses it by name.
      walledOff: "guest",
      // The first account on a fresh instance, where nobody exists to invite
      // anybody. Near-unreachable here in practice: this app bootstraps its
      // first coordinator from EIERMANN_COORDINATOR_EMAIL at boot, so by the
      // time an OAuth2 sign-in arrives a `users` record already exists — and
      // the library keys "first user" on that, deliberately, rather than on
      // "no active coordinator right now" (which a superuser could produce and
      // anybody at the IdP could then claim).
      bootstrap: "coordinator",
      // Privilege order: the first matching group wins.
      groupMap: [
        { env: "OIDC_COORDINATOR_GROUP", role: "coordinator" },
        { env: "OIDC_MEMBER_GROUP", role: "member" },
      ],
    },
    // English, and for the log rather than the reader: a hook does not know
    // which language the person in front of the screen speaks. The client turns
    // the 403 into its own sentence.
    forbiddenMessage: "This account is not permitted to register.",
    // No audit entry, and that is a gap rather than a decision: an account
    // appearing with a role chosen by configuration instead of by a person is
    // exactly a membership decision worth recording. eiermann has no audit
    // collection yet (Phase 08) — when it gains one, this call site is where
    // the `audit`/`auditAction` pair belongs. Tracked as eiermann-0oi.
  }),
);
