/// <reference path="../pb_data/types.d.ts" />

// federfall-qt96.2 — the audit log's emitter. Every row in `audit_events` is
// written from here.
//
// Usage — `require()` INSIDE the handler, never at file level, and always with
// the `${__hooks}` absolute form (a relative path fails with "Invalid module"):
//
//   onRecordUpdateRequest((e) => {
//     const audit = require(`${__hooks}/zv_audit.js`)
//       .withRegistry(require(`${__hooks}/app_audit_registry.js`));
//     const before = e.record.original().fieldsData();
//     e.next();                       // throws ⇒ nothing is logged
//     audit.emit(e, "weight.updated", {
//       record: e.record,
//       changes: audit.diff("weights", before, e.record.fieldsData(), e.app),
//     });
//   }, "weights");
//
// This file is NOT named *.pb.js, so PocketBase does not load it as a hook — it
// is only ever reachable through that require(). Unlike a hook file, a required
// module keeps its own file-level scope, which is why the helpers below can live
// out here (verified on 0.39.8).
//
// ── What is shared and what is the app's ────────────────────────────────────
// The MACHINERY is here: redaction, the diff, label snapshotting, the actor and
// org resolution, the request id, the never-throw wrapper, the failed-login
// bucketing. The REGISTRIES are the app's — which action strings exist, which
// collections are audited, which fields are sensitive, which field labels a
// record. Those are its vocabulary, and no two products share it.
//
// `withRegistry(registry)` binds the two together. Its shape:
//
//   {
//     defaultSeverity:   {action: SEVERITY.*}   coarse filter per action
//     sensitive:         {collection: [field]}  values dropped, fact kept
//     freeText:          [field]                prose, by field name
//     ignoredFields:     [field]                extra no-signal fields
//     neverLabelled:     [collection]           a member of the public
//     labelFields:       {collection: [field]}  first non-empty wins
//     labelQuantities:   {collection: {field, suffix}}
//     labelRelations:    {collection: {field: target}}
//     relationTargets:   {field: collection}    by field name
//     relationFields:    {collection: {field: collection}}  per-collection
//     refFields:         [field]                copied into `refs`
//     correlation:       {collection, field, labelField, via:{c:{field,collection}}}
//     loginFailedAction: "auth.login_failed"
//   }
//
// Every key is optional; the defaults below are the ones that are NOT domain.
//
// ── Three properties this module must keep ─────────────────────────────────
//
// 1. STATELESS. PocketBase pools JSVMs and each pooled VM holds its own
//    instance of this module, so a module-level counter/dedup/cache diverges
//    under concurrency — measured on 0.39.8, not assumed. Anything that must be
//    consistent has to come from the database.
// 2. EMIT NEVER THROWS. A failed audit write must not turn a successful domain
//    write into a 500; the whole body is wrapped and failures go to the logger.
//    (Consequence, accepted: emit-after-`e.next()` cannot roll a write back. A
//    log that can break the app it observes is the worse failure mode.)
// 3. NO PII OF THE PUBLIC, EVER. A finder, a sponsor, a donor is a member of
//    the public whose contact details a retention job scrubs on a schedule; a
//    copy of them sitting in an append-only table nothing can delete would
//    defeat that scrub with the app's own audit trail. Such subjects carry an
//    empty label and their identity/contact fields are redacted to the FACT of
//    a change. `registry.neverLabelled` is how an app names them, and it is
//    enforced HERE rather than trusted to every call site.

const SEVERITY = { INFO: "info", NOTICE: "notice", SECURITY: "security" };
const ACTOR = {
  USER: "user",
  SYSTEM: "system",
  CRON: "cron",
  SUPERUSER: "superuser",
};

// Credentials. Not domain: every PocketBase auth collection has these, and
// leaving one out is a credential in a table with no delete path.
const CREDENTIAL_FIELDS = [
  "password",
  "passwordConfirm",
  "oldPassword",
  "tokenKey",
];

// Fields that change on every write and say nothing about intent. Credentials
// are deliberately NOT here: "this account's password changed" is exactly the
// kind of thing a supervisor needs to see. `sensitive` strips the values;
// leaving the fields out entirely would strip the signal too.
// PocketBase's own auth bookkeeping stamps (a reset mail was sent, a login
// alert went out) are internal side effects, not something a person did.
const IGNORED_FIELDS = [
  "updated",
  "created",
  "lastResetSentAt",
  "lastVerificationSentAt",
  "lastLoginAlertSentAt",
];

// Long free text (a 2000-char notes field) would bloat a row that can never be
// deleted, and `changes` has a maxSize. What matters is THAT the text changed.
const MAX_VALUE_CHARS = 500;

// How many ids of a multi-relation are named. The cap is only there so a
// pathological row cannot turn one change entry into 99 indexed reads and a
// label longer than the values it describes. The ids all stay in `from`/`to`.
const MAX_LABELLED_IDS = 20;

const LABEL_CHARS = 200;

function normalize(v) {
  if (v === null || v === undefined) return "";
  if (typeof v !== "object") return v;

  let json;
  try {
    json = JSON.stringify(v);
  } catch (_) {
    return String(v);
  }
  if (json === undefined) return String(v);
  // A Go value that marshals to a JSON SCALAR reaches JS as an object —
  // types.DateTime is the everyday case, and record.get() hands one back for
  // every date field. Stringifying it keeps the quotes, so the row would store
  // '"2026-06-20 07:30:00.000Z"' (unparseable as a date on the way out) and an
  // unset date would store '""' rather than being recognised as empty. Unwrap
  // it back to the plain value. Note fieldsData() does NOT do this — it yields
  // plain JS — which is why only the create/delete path hits it.
  if (json.length >= 2 && json[0] === '"' && json[json.length - 1] === '"') {
    try {
      return JSON.parse(json);
    } catch (_) {
      return json;
    }
  }
  // An EMPTY list is an empty value, not the two characters "[]". Every multi
  // field lands here — a multi-relation, a file field with no upload — and
  // storing "[]" made the renderer read a first value being chosen as a change
  // FROM something ("[] → Kollision") instead of as one being set.
  if (json === "[]") return "";
  return json;
}

function clamp(v) {
  if (typeof v === "string" && v.length > MAX_VALUE_CHARS) {
    return { value: v.slice(0, MAX_VALUE_CHARS), truncated: true };
  }
  return { value: v, truncated: false };
}

/** The audit API bound to one app's [registry]. See the header for its shape. */
function withRegistry(registry) {
  const r = registry || {};
  const sensitive = r.sensitive || {};
  const freeText = r.freeText || [];
  const ignored = IGNORED_FIELDS.concat(r.ignoredFields || []);
  const neverLabelled = r.neverLabelled || [];
  const labelFields = r.labelFields || {};
  const labelQuantities = r.labelQuantities || {};
  const labelRelations = r.labelRelations || {};
  const relationTargets = r.relationTargets || {};
  const relationFields = r.relationFields || {};
  const refFields = r.refFields || [];
  const defaultSeverity = r.defaultSeverity || {};
  const correlation = r.correlation || null;

  const isAuthCollection = (name) =>
    name === "users" || name === "_superusers";

  /**
   * Whether [field] of [collection] keeps only the FACT of a change.
   *
   * Two reasons a field is withheld, and they are different: `sensitive` is
   * credentials and a member of the public's contact details — data that must
   * not exist in this table at all. `freeText` is prose a person wrote in their
   * own words and can still correct; leaving it in an append-only table would
   * preserve the version they edited away, which is the same hole a PII scrub
   * exists to close. Keyed by FIELD NAME for prose, because a field called
   * `notes` is somebody's prose wherever it appears.
   */
  function isWithheld(collection, field) {
    if (isAuthCollection(collection) &&
        CREDENTIAL_FIELDS.indexOf(field) !== -1) {
      return true;
    }
    const list = sensitive[collection];
    if (list && list.indexOf(field) !== -1) return true;
    return freeText.indexOf(field) !== -1;
  }

  /** The collection [field] of [collection] relates to, or "". */
  function relationTarget(collection, field) {
    const per = relationFields[collection];
    if (per && per[field]) return per[field];
    return relationTargets[field] || "";
  }

  /**
   * What the record [id] of [collection] is called.
   *
   * Snapshotted at emit time like every other label here: the target can be
   * renamed or deleted afterwards, and a row has to keep saying what it said
   * when it was written. Returns "" when the target is gone, unreadable, has no
   * label of its own, or is one of `neverLabelled` — the id stays in the change
   * either way, so a missing label loses nothing that was there before.
   */
  function labelOf(app, collection, id) {
    if (!app || !collection || !id) return "";
    if (neverLabelled.indexOf(collection) !== -1) return "";
    try {
      const target = app.findRecordById(collection, id);
      for (const f of labelFields[collection] || []) {
        const v = String(target.get(f) || "").trim();
        if (v) return v.slice(0, LABEL_CHARS);
      }
    } catch (_) {
      // Gone or unreadable — the id still identifies it.
    }
    return "";
  }

  /**
   * What [value] is called — a single id, or a whole multi-relation.
   *
   * `normalize()` renders a multi-relation as its JSON id array, so without
   * this a multi-relation change logged '["fx1…","9aq…"] → […]' and nothing
   * else: unreadable at the time, and unreadable forever after, since the
   * targets are usually a code list a supervisor can rename or deactivate.
   */
  function labelsOf(app, collection, value) {
    const raw = String(value === null || value === undefined ? "" : value);
    if (!raw) return "";
    if (raw[0] !== "[") return labelOf(app, collection, raw);

    let ids;
    try {
      ids = JSON.parse(raw);
    } catch (_) {
      return ""; // clamped mid-array, or not an array after all
    }
    if (!Array.isArray(ids)) return "";

    const labels = [];
    for (const id of ids.slice(0, MAX_LABELLED_IDS)) {
      const label = labelOf(app, collection, String(id || ""));
      if (label) labels.push(label);
    }
    return labels.join(", ").slice(0, MAX_VALUE_CHARS);
  }

  /**
   * [{field, from, to}] for a plain-object before/after pair — typically
   * `record.original().fieldsData()` and `record.fieldsData()`. Withheld
   * fields collapse to {field, redacted: true}.
   *
   * @param app optional; resolves relation values to a snapshotted label
   *            (`from_label` / `to_label`). Omit it and a relation change
   *            carries its ids alone.
   */
  function diff(collection, before, after, app) {
    const out = [];
    const b = before || {};
    const a = after || {};
    const names = {};
    for (const k in b) names[k] = true;
    for (const k in a) names[k] = true;

    for (const field in names) {
      if (ignored.indexOf(field) !== -1) continue;
      const from = normalize(b[field]);
      const to = normalize(a[field]);
      if (String(from) === String(to)) continue;

      if (isWithheld(collection, field)) {
        out.push({ field: field, redacted: true });
        continue;
      }
      const cf = clamp(from);
      const ct = clamp(to);
      const entry = { field: field, from: cf.value, to: ct.value };
      if (cf.truncated || ct.truncated) entry.truncated = true;
      // A relation's value is an id. Record what it pointed at on BOTH sides —
      // "Aviary: Quarantine 1 → Free flight" rather than two opaque ids.
      // Resolved from the UNCLAMPED value: a multi-relation's id array can
      // exceed MAX_VALUE_CHARS, and half a JSON array parses as nothing.
      const target = relationTarget(collection, field);
      if (target && app) {
        const fromLabel = labelsOf(app, target, from);
        const toLabel = labelsOf(app, target, to);
        if (fromLabel) entry.from_label = fromLabel;
        if (toLabel) entry.to_label = toLabel;
      }
      out.push(entry);
    }
    return out;
  }

  /** What one record is called, for a subject label. */
  function subjectLabel(record, app) {
    try {
      const name = String(record.collection().name);
      if (neverLabelled.indexOf(name) !== -1) return "";

      for (const f of labelFields[name] || []) {
        const v = String(record.get(f) || "").trim();
        if (v) return v.slice(0, LABEL_CHARS);
      }

      const quantity = labelQuantities[name];
      if (quantity) {
        const v = record.get(quantity.field);
        if (
          v !== null &&
          v !== undefined &&
          String(v) !== "" &&
          Number(v) !== 0
        ) {
          return String(v) + quantity.suffix;
        }
      }

      const relations = labelRelations[name];
      if (relations && app) {
        for (const field in relations) {
          const id = String(record.get(field) || "").trim();
          if (!id) continue;
          try {
            const target = app.findRecordById(relations[field], id);
            // One level only: the target's own label fields, never its
            // relations.
            for (const f of labelFields[relations[field]] || []) {
              const v = String(target.get(f) || "").trim();
              if (v) return v.slice(0, LABEL_CHARS);
            }
          } catch (_) {
            // Target gone or unreadable — try the next relation.
          }
        }
      }
    } catch (_) {
      // Unknown shape — no label.
    }
    return "";
  }

  /** The `refs` object for a record, or null when it names nothing. */
  function refsFor(record) {
    const refs = {};
    let any = false;
    for (const f of refFields) {
      try {
        const v = String(record.get(f) || "");
        if (v) {
          refs[f] = v;
          any = true;
        }
      } catch (_) {
        // Field not on this collection.
      }
    }
    return any ? refs : null;
  }

  /**
   * One id per request, so the rows written by one human action correlate.
   *
   * Stored on the event when it has a store, so several emitters in one request
   * agree; a cron/model event gets a fresh one.
   */
  function requestId(e) {
    try {
      if (e && typeof e.get === "function") {
        const existing = e.get("auditRequestId");
        if (existing) return String(existing);
        const fresh = $security.randomString(15);
        e.set("auditRequestId", fresh);
        return fresh;
      }
    } catch (_) {
      // No store on this event kind — fall through.
    }
    try {
      return $security.randomString(15);
    } catch (_) {
      return "";
    }
  }

  // Whether this org opted into storing client IP / user agent. Personal data
  // about staff, so it is off unless asked for. Re-read per emit: caching it
  // would be module state, which is per-VM and therefore a lie (see header).
  function wantsClientInfo(app, orgId) {
    const orgs = require(`${__hooks}/zv_org.js`);
    return orgs.flag(orgs.settingsOf(app, orgId), "audit_log_client_info");
  }

  /**
   * Append one event to the audit log. Never throws.
   *
   * @param e     the hook event (RequestEvent-ish) the action happened in, or
   *              null for a cron/system path. `e.auth` is what makes an actor
   *              resolvable — model-only RecordEvents have none, which is why
   *              the emitters hang off the *Request hooks.
   * @param action the action string, from the app's own registry.
   * @param opts  {app, org, subject:{collection,id,label}, record, caseId,
   *               caseLabel, refs, changes, detail, severity, actorKind, actor}
   *              `app` must be the transaction app when emitting from inside a
   *              route's runInTransaction, so the event commits with the writes
   *              it describes. `record` is a shorthand for `subject` and also
   *              supplies org and the correlation id when not given explicitly.
   */
  function emit(e, action, opts) {
    const o = opts || {};
    try {
      const app = o.app || (e && e.app) || $app;

      // ── actor ──────────────────────────────────────────────────────────────
      let actorId = "";
      let actorLabel = "";
      let actorRole = "";
      let actorKind = o.actorKind || "";
      let authOrg = "";

      let auth = null;
      if (!actorKind) {
        try {
          // opts.actor is for the auth hooks: during a login the caller is not
          // authenticated yet, so e.auth is empty and the acting user has to be
          // handed in explicitly.
          auth = o.actor || (e ? e.auth : null);
        } catch (_) {
          auth = o.actor || null;
        }
      }
      if (auth) {
        actorId = String(auth.id || "");
        let collName = "";
        try {
          collName = String(auth.collection().name);
        } catch (_) {
          collName = "";
        }
        if (collName === "_superusers") {
          // The dashboard operator. No org of their own — the subject supplies
          // it.
          actorKind = ACTOR.SUPERUSER;
          actorLabel = auth.getString("email");
        } else {
          actorKind = ACTOR.USER;
          actorLabel = auth.getString("name") || auth.getString("email");
          actorRole = auth.getString("role");
          authOrg = auth.getString("org");
        }
      } else if (!actorKind) {
        actorKind = ACTOR.SYSTEM;
      }

      // ── subject ────────────────────────────────────────────────────────────
      const rec = o.record || null;
      const subject = o.subject || {};
      let subjectCollection = String(subject.collection || "");
      let subjectId = String(subject.id || "");
      let subjectLabelValue =
        subject.label === undefined ? "" : String(subject.label);
      if (rec) {
        if (!subjectId) subjectId = String(rec.id || "");
        if (!subjectCollection) {
          try {
            subjectCollection = String(rec.collection().name);
          } catch (_) {
            subjectCollection = "";
          }
        }
      }
      // Hard rule, enforced here rather than trusted to every call site: a
      // member of the public is never named in the log. See property 3.
      if (neverLabelled.indexOf(subjectCollection) !== -1) {
        subjectLabelValue = "";
      }

      // ── org: the scoping boundary, and the one field with no fallback ──────
      let org = String(o.org || "") || authOrg;
      if (!org && rec) {
        try {
          org = rec.getString("org");
        } catch (_) {
          org = "";
        }
      }
      // An organisation has no `org` field — it IS one. Without this, a
      // superuser editing org settings from the dashboard would fall through to
      // the "no org" branch below and go unlogged, which is the opposite of who
      // most needs logging.
      if (!org && subjectCollection === "organisations") org = subjectId;
      if (!org) {
        // Refusing to guess: a row in the wrong org is visible to the wrong
        // supervisors. A superuser acting outside any org, or a failed login
        // for an unknown email, legitimately lands here.
        $app
          .logger()
          .warn("audit: no org, event not recorded", "action", String(action));
        return;
      }

      // ── correlation ────────────────────────────────────────────────────────
      // Both apps have one central record everything else hangs off — a case, a
      // clutch — and an audit row is far more useful filed under it. Which one
      // that is, and which children reach it through a parent, is the app's;
      // `registry.correlation` says so.
      let caseId = String(o.caseId || "");
      let caseLabel = String(o.caseLabel || "");
      if (correlation) {
        if (!caseId && subjectCollection === correlation.collection) {
          caseId = subjectId;
        }
        if (!caseId && rec) {
          try {
            caseId = rec.getString(correlation.field);
          } catch (_) {
            caseId = "";
          }
        }
        // A record that belongs to the centre only through its PARENT. Without
        // this, such a row edited directly through the collection API filed
        // under nothing at all and never appeared in the activity of the record
        // it was about.
        if (!caseId && rec) {
          const via = (correlation.via || {})[subjectCollection];
          if (via) {
            try {
              const parentId = rec.getString(via.field);
              if (parentId) {
                caseId = app
                  .findRecordById(via.collection, parentId)
                  .getString(correlation.field);
              }
            } catch (_) {
              // Parent gone (a cascading delete) — the row still stands alone.
            }
          }
        }
        // The centre's human-readable number, snapshotted like every other
        // label here. Free when the subject IS the centre; otherwise one
        // indexed read, and only for rows that belong to one at all.
        if (!caseLabel && caseId && correlation.labelField) {
          if (subjectCollection === correlation.collection && subjectLabelValue) {
            caseLabel = subjectLabelValue;
          } else {
            try {
              caseLabel = app
                .findRecordById(correlation.collection, caseId)
                .getString(correlation.labelField);
            } catch (_) {
              // Already gone — the id still correlates the rows.
            }
          }
        }
      }

      const row = new Record(app.findCollectionByNameOrId("audit_events"));
      row.set("org", org);
      row.set("action", String(action));
      row.set("actor_id", actorId);
      row.set("actor_label", actorLabel);
      row.set("actor_role", actorRole);
      row.set("actor_kind", actorKind);
      row.set("subject_collection", subjectCollection);
      row.set("subject_id", subjectId);
      row.set("subject_label", subjectLabelValue);
      row.set("case_id", caseId);
      row.set("case_label", caseLabel);
      if (o.refs) row.set("refs", o.refs);
      if (o.changes && o.changes.length) row.set("changes", o.changes);
      if (o.detail) row.set("detail", o.detail);
      row.set(
        "severity",
        o.severity || defaultSeverity[String(action)] || SEVERITY.INFO,
      );
      row.set("request_id", requestId(e));

      if (e && wantsClientInfo(app, org)) {
        try {
          row.set("ip", String(e.realIP() || ""));
        } catch (_) {
          // Not a request event.
        }
        try {
          const headers = e.requestInfo().headers || {};
          row.set("user_agent", String(headers.user_agent || "").slice(0, 512));
        } catch (_) {
          // Not a request event.
        }
      }

      app.save(row);
    } catch (err) {
      // Property 2 in the header: the log never breaks the thing it observes.
      $app
        .logger()
        .warn("audit: emit failed", "action", String(action), "err", String(err));
    }
  }

  /**
   * A failed password login, collapsed to AT MOST ONE ROW per user per
   * five-minute wall-clock bucket. Never throws.
   *
   * Someone hammering a login form must not be able to fill a table that has no
   * delete path — but the honest alternative, a counter on one row, would need
   * an UPDATE, which the append-only guard forbids absolutely, and module state
   * cannot hold the count either (per-JSVM, divergent under concurrency). So the
   * row means "at least one failure in this window", which is what a supervisor
   * acts on anyway; `detail.window_minutes` says so explicitly rather than
   * letting anyone read it as an exact count.
   *
   * The bucket is a floored wall-clock slot, not "the last five minutes", so two
   * concurrent requests agree on which window they are in without coordinating.
   *
   * @param record the user the identity resolved to. An unknown email has no
   *               user and therefore no org — it goes to the logger only, since
   *               an unauthenticated caller must never be able to write a row
   *               into some organisation's table by guessing addresses.
   */
  function emitLoginFailed(e, record, detail) {
    try {
      if (!record) {
        $app.logger().info("audit: failed login for an unknown identity");
        return;
      }
      // Every index on audit_events leads with `org`, so a filter without it
      // cannot use one — and this read runs on EVERY failed attempt, not just
      // the one that writes a row, against a table that only grows. A user with
      // no org cannot be filed under one anyway (emit() refuses to guess), so
      // there is nothing to dedup and nothing to write.
      const org = record.getString("org");
      if (!org) {
        $app.logger().info("audit: failed login for a user with no org");
        return;
      }

      const action = r.loginFailedAction || "auth.login_failed";
      const BUCKET_MINUTES = 5;
      const slotMs = BUCKET_MINUTES * 60 * 1000;
      const start = new Date(
        Math.floor(new Date().getTime() / slotMs) * slotMs,
      );
      // PocketBase compares datetimes as "YYYY-MM-DD HH:MM:SS.sssZ" strings.
      const since = start.toISOString().replace("T", " ");

      const existing = $app.findRecordsByFilter(
        "audit_events",
        "org = {:org} && actor_id = {:a}" +
          " && action = {:action} && created >= {:since}",
        "",
        1,
        0,
        { org: org, a: record.id, since: since, action: action },
      );
      if (existing.length > 0) return; // already one row for this window

      const d = detail || {};
      d.window_minutes = BUCKET_MINUTES;
      emit(e, action, {
        actor: record,
        org: org,
        subject: {
          collection: "users",
          id: record.id,
          label: subjectLabel(record),
        },
        detail: d,
      });
    } catch (err) {
      $app.logger().warn("audit: failed login not recorded", "err", String(err));
    }
  }

  return {
    SEVERITY: SEVERITY,
    ACTOR: ACTOR,
    isWithheld: isWithheld,
    relationTarget: relationTarget,
    labelOf: labelOf,
    labelsOf: labelsOf,
    diff: diff,
    subjectLabel: subjectLabel,
    refsFor: refsFor,
    requestId: requestId,
    emit: emit,
    emitLoginFailed: emitLoginFailed,
  };
}

module.exports = {
  SEVERITY: SEVERITY,
  ACTOR: ACTOR,
  CREDENTIAL_FIELDS: CREDENTIAL_FIELDS,
  IGNORED_FIELDS: IGNORED_FIELDS,
  MAX_VALUE_CHARS: MAX_VALUE_CHARS,
  MAX_LABELLED_IDS: MAX_LABELLED_IDS,
  normalize: normalize,
  clamp: clamp,
  withRegistry: withRegistry,
};
