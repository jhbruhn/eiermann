/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.5 — who got in, who failed to, and who changed a password.
//
// The auth flows are not record writes, so Tier A (`audit_domain.pb.js`) cannot
// see them at all. The rest of the account story needs no code here: `users` is
// an ordinary collection, so an invitation, a role change and a deactivation
// ride the generic hooks and are refined into their own actions by
// `app_audit_log.js`.
//
// ── Why not onRecordAuthRequest ─────────────────────────────────────────────
//
// That one fires for every successful authentication INCLUDING token refresh,
// which every running client does on a timer. The log would be mostly refresh
// noise. Hooking the specific methods records the thing a person actually did.
//
// ── During a login there is no e.auth ───────────────────────────────────────
//
// The caller is not authenticated yet — that is the point of the request — so
// the acting user is passed to `emit` explicitly as `actor`. Without it every
// one of these rows would be attributed to "system".
//
// ── This file loads before oauth2_provisioning.pb.js ────────────────────────
//
// Alphabetically, which makes its OAuth2 handler the outer one: `e.next()`
// descends into the provisioning hook and returns with the account created and
// its role decided. So the row below reads the role that survived, rather than
// the absence of one a moment earlier. Ordering that matters and is decided by
// a filename is worth writing down.

onRecordAuthWithPasswordRequest((e) => {
  const audit = require(`${__hooks}/app_audit_log.js`);

  // Checked BEFORE e.next(), because it is the only way to tell this request's
  // two failure modes apart:
  //   - wrong password                      → a real failed login
  //   - right password, deactivated account → `users.authRule` is
  //     `is_active = true`, so this is refused too. It is not somebody
  //     guessing, and filing it as one would put a departed member's every
  //     stale client retry in the security feed.
  // Only the first is worth a row. (federfall has a third case here, an MFA
  // challenge answering 401 mid-login; this app has no MFA field at all.)
  let passwordOk = false;
  try {
    passwordOk = !!(
      e.record && e.record.validatePassword(String(e.password || ""))
    );
  } catch (_) {
    passwordOk = false;
  }

  try {
    e.next();
  } catch (err) {
    if (!passwordOk) {
      // Bucketed into five-minute windows per account by zv_audit.js, so a
      // brute-force fills the log with one row rather than ten thousand.
      require(`${__hooks}/app_audit_log.js`).emitLoginFailed(e, e.record, {
        method: "password",
      });
    }
    throw err;
  }

  if (e.record) {
    audit.emit(e, audit.ACTIONS.AUTH_LOGIN, {
      actor: e.record,
      org: e.record.getString("org"),
      subject: {
        collection: "users",
        id: e.record.id,
        label: audit.subjectLabel(e.record),
      },
      detail: { method: "password" },
    });
  }
}, "users");

// The sign-in itself. A FIRST OAuth2 sign-in also provisions the account, and
// that is a separate row written by oauth2_provisioning.pb.js — a membership
// decision is not the same event as a login, even when one request does both.
onRecordAuthWithOAuth2Request((e) => {
  const audit = require(`${__hooks}/app_audit_log.js`);
  e.next();
  if (e.record) {
    audit.emit(e, audit.ACTIONS.AUTH_OAUTH2_LOGIN, {
      actor: e.record,
      org: e.record.getString("org"),
      subject: {
        collection: "users",
        id: e.record.id,
        label: audit.subjectLabel(e.record),
      },
      detail: {
        method: "oauth2",
        provider: String(e.providerName || ""),
        // Whether this sign-in created the account. `isNewRecord` is the only
        // place that distinction is visible from here.
        new_account: !!e.isNewRecord,
      },
    });
  }
}, "users");

// The CONFIRM, not the request: anyone can ask for a reset mail, but only
// somebody holding the token can change a password with it. That is the event
// with security meaning — and the account's password is now different from
// whatever its owner last set, which is worth a row even when the owner is the
// one who did it.
onRecordConfirmPasswordResetRequest((e) => {
  const audit = require(`${__hooks}/app_audit_log.js`);
  e.next();
  if (e.record) {
    audit.emit(e, audit.ACTIONS.AUTH_PASSWORD_RESET, {
      actor: e.record,
      org: e.record.getString("org"),
      subject: {
        collection: "users",
        id: e.record.id,
        label: audit.subjectLabel(e.record),
      },
    });
  }
}, "users");
