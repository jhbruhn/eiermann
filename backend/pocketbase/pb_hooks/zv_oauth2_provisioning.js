/// <reference path="../pb_data/types.d.ts" />

// federfall-49l.3 — provision self-registered OAuth2 users.
//
// Usage — the app's `oauth2_provisioning.pb.js` states its own roles:
//
//   onRecordAuthWithOAuth2Request((e) =>
//     require(`${__hooks}/zv_oauth2_provisioning.js`).provision(e, {
//       envPrefix: "EIERMANN",
//       defaultOrgId: "org00000default",
//       roles: {
//         walledOff: "guest",
//         bootstrap: "supervisor",
//         groupMap: [
//           { env: "OIDC_SUPERVISOR_GROUP", role: "supervisor" },
//           { env: "OIDC_CARER_GROUP", role: "carer" },
//         ],
//       },
//       audit: require(`${__hooks}/zv_audit.js`).withRegistry(
//         require(`${__hooks}/app_audit_registry.js`),
//       ),
//     }),
//   );
//
// When someone signs in via OAuth2 and no users record matches yet, PocketBase
// creates the auth record itself (e.record is null until then). This lets it do
// that — and crucially does NOT build the record by hand, so PB still links the
// external identity (_externalAuths / recordRef) correctly. It only injects the
// app fields the collection requires through `e.createData`, the official
// channel for seeding a new record.
//
// Role (hybrid model):
//   - the FIRST user of the instance (no `users` record exists at all yet) gets
//     `roles.bootstrap` — that is what brings an instance up with no invite and
//     no env seed; OR
//   - if the IdP sends groups, `roles.groupMap` applies, first match wins; else
//   - the user lands on `roles.walledOff` — able to log in but kept away from
//     all data by the access rules until a supervisor promotes them.
//
// federfall-emkj — "first user" is keyed on "no users exist at all", NOT "no
// ACTIVE supervisor right now": the latter is reachable via legitimate admin
// actions (a superuser deactivating or deleting every supervisor), and
// auto-granting the bootstrap role to whoever happens to sign in next via
// OAuth2 would let anyone at the IdP claim it. Once that state is reached the
// intended recovery path is the operator-only env bootstrap, not OAuth2
// self-registration. Concurrent first sign-ins are resolved after the fact (see
// below the `e.next()` call) rather than locked up front, since the JSVM has no
// cross-request mutex — this still converges to exactly one.
//
// Optional gating: if `<P>_OIDC_ALLOWED_GROUPS` is set, only users in one of
// those groups may register — INCLUDING the first user. An operator who
// configured it wants only vetted IdP accounts, even for the very first login;
// bootstrapping without any IdP group set up still works via the env path.
//
// `<P>_OIDC_TRUST_EMAIL=true` treats the IdP's email claim as verified even when
// the provider did not send email_verified (for trusted private IdPs).
//
// Existing users (linking OAuth2 to an already-provisioned account) pass through
// untouched. PocketBase isolates each handler's JSVM context, which is why the
// app's wrapper builds its config INSIDE the handler.

/**
 * Seeds and role-assigns a newly self-registered OAuth2 user.
 *
 * @param config {envPrefix, defaultOrgId, roles:{walledOff, bootstrap,
 *               groupMap:[{env, role}]}, audit, auditAction}
 *               `audit` is an optional bound zv_audit API; without it the
 *               provisioning is not logged, which is a choice an app makes.
 */
function provision(e, config) {
  if (!e.isNewRecord) {
    e.next();
    return;
  }

  const prefix = String((config && config.envPrefix) || "");
  const logPrefix = prefix.toLowerCase() + ": ";
  const env = (k) => {
    const v = $os.getenv(prefix + "_" + k);
    return v && v !== "" ? v : "";
  };
  const list = (k) =>
    env(k)
      .split(",")
      .map((s) => s.trim())
      .filter((s) => s !== "");

  // Groups from the IdP claims (OIDC providers send them; plain social do not).
  const ou = e.oAuth2User;
  let groups = [];
  try {
    const raw = ou ? ou.rawUser : null;
    const claim = env("OIDC_GROUPS_CLAIM") || "groups";
    const g = raw ? raw[claim] : null;
    if (Array.isArray(g)) groups = g.map((x) => String(x));
    else if (typeof g === "string" && g !== "") groups = [g];
  } catch (_) {
    groups = [];
  }
  const inAny = (names) => names.some((n) => groups.includes(n));

  // True first boot: no `users` record exists yet at all (see header).
  let firstUser = false;
  try {
    e.app.findFirstRecordByFilter("users", "id != ''");
  } catch (_) {
    firstUser = true;
  }

  // Gate registration to allowed groups, if configured — applies even to the
  // bootstrap user (see header).
  const allowed = list("OIDC_ALLOWED_GROUPS");
  if (allowed.length > 0 && !inAny(allowed)) {
    // The message reaches a client, so an app that shows it verbatim can supply
    // its own wording. The app's UI normally renders the 403 in its own words
    // and never reads this string, which is why a default is acceptable here
    // where it would not be in a widget.
    throw new ForbiddenError(
      String(
        (config && config.forbiddenMessage) ||
          "This account is not permitted to register.",
      ),
      null,
    );
  }

  // Decide the role. WHICH roles exist and which env variable maps to which is
  // the app's — `config.roles` states it. Order matters: the first matching
  // entry wins, so the most privileged group belongs first.
  const roles = (config && config.roles) || {};
  const walledOffRole = String(roles.walledOff || "guest");
  const bootstrapRole = String(roles.bootstrap || walledOffRole);
  const groupMap = roles.groupMap || [];
  let role = walledOffRole;
  if (firstUser) {
    role = bootstrapRole;
  } else {
    for (let i = 0; i < groupMap.length; i++) {
      if (inAny(list(groupMap[i].env))) {
        role = String(groupMap[i].role);
        break;
      }
    }
  }

  // Seeded launch organisation (single-org instance), with a fallback. The
  // seeded id is the app's, because its own migration wrote it.
  const seededOrgId = String((config && config.defaultOrgId) || "");
  let orgId = "";
  try {
    orgId = e.app.findRecordById("organisations", seededOrgId).id;
  } catch (_) {
    try {
      orgId = e.app.findFirstRecordByFilter("organisations", "id != ''").id;
    } catch (_) {
      orgId = "";
    }
  }

  // Resolve the email. PocketBase only populates `ou.email` when the provider
  // reported it as verified; the fallback to the raw `email` claim (for IdPs/
  // mocks that omit email_verified) is UNVERIFIED — with an IdP that lets
  // users type any address, trusting it would plant an attacker-chosen email
  // in the roster as verified (federfall-bsv). Track the distinction and only
  // mark the account verified below when the claim actually was.
  let email = ou ? ou.email || "" : "";
  let emailVerified = email !== "";
  if (!email && ou && ou.rawUser) {
    try {
      email = ou.rawUser.email ? String(ou.rawUser.email) : "";
    } catch (_) {
      email = "";
    }
  }
  // Operator override for a trusted private IdP that never sends
  // email_verified (self-hosted Authentik/Keycloak holding vetted accounts).
  if (env("OIDC_TRUST_EMAIL").toLowerCase() === "true") {
    emailVerified = email !== "";
  }

  // Seed the to-be-created record. Let PocketBase build + persist it (and link
  // the external identity) — we only add the fields it can't infer from OAuth2.
  // createData may be undefined here, so assign a fresh object (merging anything
  // the client already supplied). `verified` is NOT set here — it's a protected
  // system field PocketBase rejects via createData — it's set after creation
  // below instead.
  const data = { role: role, is_active: true };
  if (orgId) data.org = orgId;
  // Expose the email to fellow org members so the team roster shows it.
  if (email) {
    data.email = email;
    data.emailVisibility = true;
  }
  e.createData = Object.assign({}, e.createData, data);

  e.app
    .logger()
    .info(logPrefix + "provisioning oauth2 user", "role", role, "firstUser", firstUser);

  e.next(); // PocketBase creates + links the record here

  // federfall-emkj — two concurrent first sign-ins can both observe
  // firstUser=true before either commits, and both get the bootstrap role.
  // There is no cross-request mutex available in the JSVM, so resolve it
  // deterministically after the fact instead: if another active holder of the
  // bootstrap role with an earlier `created` (ties broken by id) now exists,
  // this record lost the race and steps down. Whichever record is NOT the
  // earliest always finds an earlier one once both have committed, so exactly
  // one survives.
  if (firstUser && role === bootstrapRole && e.record) {
    try {
      const earlier = e.app.findFirstRecordByFilter(
        "users",
        "role = {:role} && is_active = true && id != {:id} && " +
          "(created < {:created} || (created = {:created} && id < {:id}))",
        {
          role: bootstrapRole,
          id: e.record.id,
          created: e.record.getString("created"),
        },
      );
      if (earlier) {
        e.record.set("role", walledOffRole);
        e.app.save(e.record);
        e.app
          .logger()
          .warn(
            logPrefix +
              "lost the concurrent bootstrap race, demoted to " +
              walledOffRole,
            "id",
            e.record.id,
          );
      }
    } catch (_) {
      // No earlier active holder found — this record keeps the role.
    }
  }

  // Mark the new account verified — but ONLY when the IdP actually verified
  // the email (or the operator opted into trusting it, see above). An account
  // left unverified still works: the guest wall keys off `role`, and
  // `verified` only shows an "invite pending" badge in the team roster until
  // a supervisor confirms the person. It cannot go through createData
  // (protected there); a programmatic save from a hook is allowed and does not
  // trip an app's API-only field guard.
  try {
    if (e.record && emailVerified && !e.record.getBool("verified")) {
      e.record.set("verified", true);
      e.app.save(e.record);
    }
  } catch (err) {
    e.app
      .logger()
      .warn(logPrefix + "could not mark oauth user verified", "err", String(err));
  }

  // federfall-qt96.6 — an account appeared without anybody inviting it, with a
  // role this hook chose from the IdP's groups. That is a membership decision
  // made by configuration rather than by a person, so it is logged as one (the
  // sign-in itself is logged elsewhere; this is the provisioning).
  // Emitted last, so the role it reports is the one that survived the
  // concurrent-bootstrap resolution above.
  const audit = config && config.audit;
  const auditAction = (config && config.auditAction) || "oauth2.user_provisioned";
  if (e.record && audit) {
    audit.emit(e, auditAction, {
      actorKind: "system",
      org: e.record.getString("org"),
      subject: {
        collection: "users",
        id: e.record.id,
        label: e.record.getString("name") || e.record.getString("email"),
      },
      detail: {
        role: e.record.getString("role"),
        first_user: !!firstUser,
        email_verified: !!emailVerified,
      },
    });
  }
}

module.exports = { provision: provision };
