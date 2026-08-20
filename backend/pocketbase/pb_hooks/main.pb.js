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
    if (allowed) continue;

    // Put the stored value back. Silently: a well-behaved client never sends
    // these, so anything arriving here is either an echo (a no-op) or an
    // attempt, and neither deserves a message that helps refine the attempt.
    try {
      e.record.set(field, e.record.original().get(field));
    } catch (_) {
      // The stored record does not carry the field at all, so there is nothing
      // to restore — and leaving the client's value would be the one outcome
      // this hook exists to prevent. Refuse the write instead.
      throw new BadRequestError("This field cannot be set here.");
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
  if (!isCoordinator) {
    e.record.set("role", null);
    e.record.set("is_active", true);
  }
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
// boot. This is the documented recovery path for the state above: no
// coordinator, and nobody able to make one. Idempotent — an existing account is
// reactivated and re-granted rather than duplicated.
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
// The fix is not in this file: the container runs `pocketbase migrate up` as its
// own step before `serve`, so by the time anything here executes the schema is
// already there. See docker-compose.override.yml and the Dockerfile CMD.
// Relying on automigrate ordering instead is what made this silently work on
// the second boot only.
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
      created = true;
    }
    user.set("role", "coordinator");
    user.set("is_active", true);
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
