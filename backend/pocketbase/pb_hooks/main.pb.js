/// <reference path="../pb_data/types.d.ts" />

// eiermann-h7q.14 — the guards the access rules cannot express.
//
// Everything here exists because a collection rule is not enough. A rule decides
// WHETHER a request may write a row; it cannot reliably decide which FIELDS of
// that row a particular caller may set. `@request.body.x:isset = false` gets
// close, but it is a denylist by name — and a denylist by name is a list
// somebody forgets to extend the day a fifth privilege field is added.
//
// federfall's rules had exactly this hole: `users.updateRule` let you PATCH your
// own row, and `role` sits on that row. The escalation was closed by a hook,
// not by a rule. This is that hook, written first rather than after the finding.

// ── Privilege fields: the server owns them, always ─────────────────────────
//
// Not "the client should not send these" — the client CANNOT set them. On an
// update the previous value is put back; on a create only the coordination's own
// value stands. Silently, not as an error: a well-behaved client never sends
// them, so anything arriving here is either an echo (a no-op) or an attempt, and
// neither deserves a message that helps refine the attempt.
//
// ── The list is repeated inside each handler, and that is not an oversight ──
// A pb_hooks handler runs in an ISOLATED JSVM context: a file-level `const` up
// here is NOT in scope inside the callbacks below. It does not fail at load
// time either — it fails at request time, as
// `ReferenceError: PRIVILEGE_FIELDS is not defined`, which surfaces to the
// client as a generic 400 on an ordinary name change. Anything two handlers must
// share has to be a `require()`d module (see the zv_* libraries) or repeated;
// for a four-element list, repeated with this note is the cheaper of the two.

onRecordUpdateRequest((e) => {
  // A superuser acting through the dashboard is the operator, and the operator
  // is who grants roles in the first place. Nothing to protect them from.
  if (e.hasSuperuserAuth()) {
    e.next();
    return;
  }

  // Read what the CLIENT SENT, not what the record now holds.
  //
  // Comparing `record.get(field)` against `record.original().get(field)` is the
  // obvious implementation and it is wrong twice over: `get()` THROWS
  // ("invalid key path - missing key") for a field the record's data map does
  // not carry, which turned every ordinary name change into a 400; and a
  // field's value being unchanged does not mean the client did not try to set
  // it. The request body is the thing this hook has an opinion about.
  let body = {};
  try {
    body = e.requestInfo().body || {};
  } catch (_) {
    body = {};
  }

  // See the header: a file-level binding is out of scope in here.
  const PRIVILEGE_FIELDS = ["role", "org", "is_active", "verified"];

  let isCoordinator = false;
  try {
    isCoordinator =
      !!e.auth && String(e.auth.getString("role")) === "coordinator";
  } catch (_) {
    isCoordinator = false;
  }
  const isSelf = !!e.auth && String(e.auth.id) === String(e.record.id);

  for (const field of PRIVILEGE_FIELDS) {
    if (!(field in body)) continue;

    // A coordinator may change somebody else's role and may deactivate them —
    // that is the job. What NOBODY may change is `org`: moving a user between
    // organisations is not an edit, it is a re-tenanting, and it has no
    // legitimate in-app trigger.
    //
    // Nor may anybody edit their OWN privilege fields, coordinator included.
    // Otherwise the last coordinator can quietly lock the team out by
    // deactivating themselves, and a compromised coordinator session becomes a
    // permanent one.
    const allowed = isCoordinator && !isSelf && field !== "org";
    if (allowed) {
      // The legitimate ones are exactly the ones worth recording, and
      // `audit_domain.pb.js` records them: a `role` change is refined into
      // `user.role_changed` and an `is_active` change into
      // `user.activated`/`user.deactivated`, off the same diff every other
      // collection gets (eiermann-30w.9 moved that out of this handler).
      //
      // A user record holds its CURRENT role and nothing else, so "who granted
      // the coordination, and when" has no answer anywhere else — and granting
      // it, or ending somebody's access mid-request, is among the handful of
      // acts in this app that are hard to undo and easy to do quietly.
      continue;
    }

    // Put the stored value back. Silently: a well-behaved client never sends
    // these, so anything arriving here is either an echo (a no-op) or an
    // attempt, and neither deserves a message that helps refine the attempt.
    try {
      e.record.set(field, e.record.original().get(field));
    } catch (_) {
      // The stored record does not carry the field at all, so there is nothing
      // to restore — and leaving the client's value would be the one outcome
      // this hook exists to prevent. Refuse the write instead.
      //
      // Through refuse() like every other refusal, so the client gets a code
      // rather than a sentence and the sweep stays absolute. This one has no
      // dialog behind it: a well-behaved client never sends these fields, so the
      // code exists to be logged and recognised, not to be rendered.
      const refuser = require(`${__hooks}/app_refuse.js`);
      refuser.refuse(
        refuser.CODES.userFieldNotWritable,
        `field ${field} cannot be set by a client`,
      );
    }
  }

  e.next();
}, "users");

// ── A new account is walled off until somebody lets it in ──────────────────
//
// `role` is nullable in the schema precisely so this state can exist, and the
// access rules refuse everything to a role-less account. The one thing that
// must not happen is a self-provisioned account arriving WITH a role, so the
// value is cleared on any create that is not the coordination's.
//
// ── ...except the one create where the role is the SERVER's own answer ─────
//
// A sign-in through an identity provider creates its record with no
// authenticated caller at all, so it lands in the branch below and had its role
// blanked. Which made `EIERMANN_OIDC_COORDINATOR_GROUP` and `_MEMBER_GROUP` a
// no-op: `zv_oauth2_provisioning.js` read the groups claim, chose a role, put
// it in `createData` — and this handler threw it away a moment later. Measured
// against the mock provider: the hook logged `role=coordinator` and the stored
// row came back with `role=""`.
//
// The distinction that makes trusting it safe is WHERE the value came from. In
// every other create the role is a field of a body somebody sent, which is why
// it cannot be believed. In this one the caller never supplies it: the hook
// derives it from the provider's claims and the operator's own environment, and
// `@request.context` is set by PocketBase for the duration of that flow and
// cannot be forged from an ordinary API call — 1700000020 leans on the same
// property to let the record be created at all, and the rule suite asserts an
// anonymous POST claiming that context is still refused.
//
// So the wall stays exactly where it was for everybody else, and for an
// arrival the operator did not map it stays too: no matching group means the
// library's walled-off role, which every access rule refuses by name.
onRecordCreateRequest((e) => {
  if (e.hasSuperuserAuth()) {
    e.next();
    return;
  }
  let isCoordinator = false;
  try {
    isCoordinator =
      !!e.auth && String(e.auth.getString("role")) === "coordinator";
  } catch (_) {
    isCoordinator = false;
  }
  let isOAuth2 = false;
  try {
    isOAuth2 = String(e.requestInfo().context) === "oauth2";
  } catch (_) {
    isOAuth2 = false;
  }
  if (isOAuth2) {
    // Provisioned: role, org and is_active are already on the record, decided
    // by the hook rather than by the caller.
    e.next();
    return;
  }
  if (!isCoordinator) {
    e.record.set("role", null);
    e.record.set("is_active", true);
    e.next();
    return;
  }

  // An invited account is visible to the team that invited it.
  //
  // `emailVisibility` defaults to false, and PocketBase then omits `email` from
  // every response except the record's own owner and a superuser. So a roster
  // built on `users.listRule` — which deliberately shows the whole team to the
  // whole team — would render a column of blanks, and `pending_screen.dart`'s
  // "you signed in under a different address than the one you were invited
  // under" would have no address to compare against.
  //
  // Set here rather than trusted from the body: it is the one property of an
  // invite that the invited person did not choose and the coordinator should
  // not have to remember. The bootstrap coordinator in this same file sets it
  // for the identical reason.
  e.record.set("emailVisibility", true);

  // The invitation itself is recorded by `audit_domain.pb.js` as
  // `user.invited` — `users` is an ordinary collection, so its create rides the
  // generic hook (eiermann-30w.9 moved that out of this handler).
  //
  // Who let this person in is therefore recorded twice over: `users.invited_by`
  // carries it on the account itself, and the audit row carries it in a table
  // nothing with a token can edit. The first can be changed and the second
  // cannot, which is the whole difference between a field and an audit trail.
  e.next();
}, "users");

// ── Bootstrap the first coordinator ────────────────────────────────────────
//
// An instance with no users cannot be administered: the access rules need a
// coordinator to create one, and there is no coordinator yet. So the FIRST user
// to exist becomes one.
//
// Keyed on "no users exist at all", NOT on "no active coordinator right now".
// The latter is reachable by ordinary admin action — a coordinator deactivating
// the only other one — and would then hand the role to whoever signed up next.
// Once no coordinator remains, the recovery path is the operator's env-based
// bootstrap below, not a race.
onRecordAfterCreateSuccess((e) => {
  try {
    const app = e.app;
    const others = app.findRecordsByFilter(
      "users",
      "id != {:id}",
      "",
      1,
      0,
      { id: e.record.id },
    );
    if (others.length > 0) {
      e.next();
      return;
    }
    e.record.set("role", "coordinator");
    e.record.set("is_active", true);
    app.save(e.record);
    app
      .logger()
      .info("eiermann: first user promoted to coordinator", "id", e.record.id);
  } catch (err) {
    // Never fail the create over this: an account that exists without a role is
    // recoverable (the operator grants one); a failed sign-up is not.
    $app
      .logger()
      .warn("eiermann: first-user promotion failed", "err", String(err));
  }
  e.next();
}, "users");

// ── The operator's way in ──────────────────────────────────────────────────
//
// EIERMANN_COORDINATOR_EMAIL + _PASSWORD create or repair a coordinator on
// boot, with EIERMANN_COORDINATOR_NAME as the optional display name. This is
// the documented recovery path for the state above: no coordinator, and nobody
// able to make one. Idempotent — an existing account is reactivated and
// re-granted rather than duplicated.
//
// It is also THE way in on a brand-new instance. A PocketBase superuser (the
// Admin UI account) is not an app-level coordinator: it is a `_superusers`
// record with no org and no role, so it cannot own a Spot, invite anybody, or
// appear in a visit history. Creating the first real account has to happen out
// of band, and this is that band.
//
// The password is only ever set on CREATION. Re-setting it every boot would mean
// an operator who once used this variable can never be locked out of an account
// whose password the team has since changed.
//
// ── This runs AFTER `migrate up`, and that is a requirement ────────────────
// Learned the hard way. `onBootstrap` + `e.next()` does NOT guarantee the
// migrations have been applied: on a fresh data directory with `--automigrate`,
// this handler found no `organisations` collection at all and logged a failure —
// so the very first boot of a new instance, the only boot where this matters,
// was the one where it did not work. (And there is no `onServe` in the JSVM to
// move it later; the global hooks are onBootstrap, onSettingsReload, onTerminate
// and the request/model ones.)
//
// The fix is not in this file: the image's ENTRYPOINT runs `pocketbase migrate
// up` as its own step before handing off to `serve`, so by the time anything
// here executes the schema is already there. See backend/pocketbase/entrypoint.sh.
//
// That fix was in the DEV OVERRIDE only for a while, which meant the shipped
// image was the broken one and local development could never see it. Measured on
// the real image: first boot login 400 with no log line, second boot 200.
onBootstrap((e) => {
  e.next();

  const email = $os.getenv("EIERMANN_COORDINATOR_EMAIL");
  const password = $os.getenv("EIERMANN_COORDINATOR_PASSWORD");
  if (!email || !password) return;
  if (password.length < 8) {
    e.app
      .logger()
      .warn("eiermann: coordinator bootstrap skipped, password too short");
    return;
  }

  try {
    const users = e.app.findCollectionByNameOrId("users");
    const orgs = e.app.findRecordsByFilter(
      "organisations",
      "id != ''",
      "",
      1,
      0,
    );
    if (orgs.length === 0) {
      e.app.logger().warn("eiermann: coordinator bootstrap: no organisation");
      return;
    }

    let user;
    let created = false;
    try {
      user = e.app.findFirstRecordByFilter("users", "email = {:email}", {
        email: email,
      });
    } catch (_) {
      user = new Record(users);
      user.set("email", email);
      // setPassword(), NOT set("password", ...). The plain setter writes a field
      // that is not the password hash, so the account is created and then
      // cannot be signed in to — which looks exactly like a wrong authRule and
      // is not.
      user.setPassword(password);
      user.set("verified", true);
      // Visible to fellow members: the team roster shows who to ask, and an
      // address nobody can see is a coordinator nobody can reach.
      user.set("emailVisibility", true);
      created = true;
    }
    user.set("role", "coordinator");
    user.set("is_active", true);
    // A display name, because every audit-shaped row stores a text SNAPSHOT of
    // its author next to the id — the account may be renamed or deleted, and
    // then an id alone describes the past wrongly. Without a name the snapshot
    // falls back to the email address, which then sits in the visit history of
    // every Spot this account ever touched.
    if (!user.getString("name")) {
      user.set("name", $os.getenv("EIERMANN_COORDINATOR_NAME") || "Koordination");
    }
    if (!user.getString("org")) user.set("org", orgs[0].id);
    e.app.save(user);
    e.app
      .logger()
      .info(
        created
          ? "eiermann: coordinator created"
          : "eiermann: coordinator re-granted",
        "email",
        email,
      );
  } catch (err) {
    e.app
      .logger()
      .warn("eiermann: coordinator bootstrap failed", "err", String(err));
  }
});
