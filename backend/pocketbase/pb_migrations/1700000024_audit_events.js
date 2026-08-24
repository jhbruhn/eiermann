/// <reference path="../pb_data/types.d.ts" />

// eiermann-30w.2 — audit_events: the log federfall already writes, in the shape
// zugvogel's emitter writes it.
//
// ── Why a second table rather than a wider first one ────────────────────────
//
// `audit_entries` (1700000019) is this app's own implementation of an idea
// zugvogel already owns. It records ten actions across four collections, each
// hand-wired at a call site, and everything else in the app — a Besuch, a
// finding, an area, a tour, an export, a sign-in — happens unobserved. The fix
// is not more call sites: it is `zv_audit.js`, which federfall drives its whole
// log from and which gets every ordinary collection write from one generic hook
// per verb. `app_audit_log.js` binds it to this app's vocabulary.
//
// That emitter writes a fixed set of columns, and they are not 1700000019's.
// The disagreement is structural rather than cosmetic — one row per CHANGED
// FIELD there, one row per EVENT carrying a bag of changes here — so there is
// no widening of the old table that produces the new one. Hence a new
// collection, and `audit_entries` retired once nothing reads or writes it any
// more (eiermann-30w.9). Its rows are not carried across: regrouping a
// per-field log back into events means guessing which rows came from one save,
// and a guess in an audit trail is worth less than an honest gap.
//
// ── The correlation columns are `spot_id` / `spot_label` ────────────────────
//
// Every audit row is far more useful filed under the one record everything else
// hangs off. federfall's is a case; this app's is a Spot. Until zugvogel
// 6f5ef44 the emitter resolved that record from the app's registry and then
// wrote it to `case_id` regardless — so this table would have carried
// federfall's vocabulary permanently, in the one place that cannot be renamed
// afterwards. `registry.correlation.column` is what makes these two names this
// app's to choose; see eiermann-30w.1.
//
// ── Three JSON fields, and the sweep that has to be told about them ─────────
//
// `refs`, `changes` and `detail` are JSON, which the "one settings JSON field,
// one reader" sweep in the rule suite fails on by design — 1700000019 avoided
// them for exactly that reason and said so. The sweep's own text names the
// escape and demands it be argued: a JSON field is admissible when it is an
// OPAQUE PAYLOAD, stored whole and handed back whole, never property-accessed
// in JS. These three are that, and it is checkable rather than hoped for —
// nothing in any hook reads them back. The emitter builds each one as a plain
// JS array or object and sets it; the only hook that ever queries this table is
// zv_audit.js's failed-login bucketing, which counts rows by `action` and
// `created`. Everything else that reads a row is the Flutter client, over the
// API, where PocketBase serialises JSON correctly and no `types.JSONRaw` ever
// reaches a `.property`.
//
// The trap the sweep exists for is real and cost federfall two dead features.
// It is a trap about READING, and this table is not read in a hook.
//
// ── The actor is TEXT, and that is a repair ─────────────────────────────────
//
// 1700000019 made `actor` a relation to `users`, guarded by a delete-effect
// registry entry saying a cascade there would erase the record of what an
// account did. The shared shape needs no such guard: `actor_id` is a plain text
// id beside an `actor_label` snapshot, so the row cannot be reached by any
// cascade at all. Same reasoning as `target`/`subject` — an id is there so a
// reader can navigate while the target lives, the label so the row still means
// something when it does not. This leaves `org` as the table's only relation.
//
// ── ip and user_agent exist and stay empty ──────────────────────────────────
//
// They are personal data about a volunteer, in a table with no delete rule.
// eiermann does not want them: the people using this app check attics for a
// pigeon group, and an unerasable record of their IP addresses is not something
// this product needs to hold. The columns are here anyway because the shared
// emitter writes them when `organisations.settings.audit_log_client_info` is
// set, and `emit()` never throws — a `row.set` against a column that does not
// exist would fail silently and could take the whole audit row with it. So the
// columns exist to keep that path safe, the flag is never set, and they stay
// empty. Deciding otherwise is a settings change, not a migration.

const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");

    const audit = new Collection({
      type: "base",
      name: "audit_events",
      // Read is the coordination's alone, and org-scoped. A member seeing who
      // demoted whom is a different product; the point of this table is
      // accountability upwards.
      listRule: `${COORDINATOR} && org = @request.auth.org`,
      viewRule: `${COORDINATOR} && org = @request.auth.org`,
      // All three null: superuser-only, the strongest statement PocketBase
      // offers. Nothing holding an API token can write here, edit a row or
      // remove one — including the coordination, whose own acts this records.
      // The hooks write through `app.save`, which does not consult the access
      // rules at all, so the ONLY way a row appears is a hook deciding it
      // should. Append-only is therefore the schema, not a convention.
      createRule: null,
      updateRule: null,
      deleteRule: null,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          maxSelect: 1,
          collectionId: organisations.id,
          // The table's only relation, and it does not cascade: an org is not
          // deleted in this app, and a log that an ordinary delete can erase is
          // not a log.
          cascadeDelete: false,
        },
        // `domain.verb`, e.g. "spot.phase_changed". TEXT rather than select:
        // the vocabulary lives in a hook registry and the client maps it, and a
        // select would mean a migration every time an action is added.
        { name: "action", type: "text", required: true, max: 64 },

        // ── actor: who did it, as snapshots ──────────────────────────────
        { name: "actor_id", type: "text", required: false, max: 32 },
        { name: "actor_label", type: "text", required: false, max: 200 },
        { name: "actor_role", type: "text", required: false, max: 32 },
        // user | system | cron | superuser. The cron path has no caller at all
        // — spot_auto_resume moves Spots out of a pause with no human near it,
        // and a row that said "system" without saying why would be a puzzle.
        { name: "actor_kind", type: "text", required: false, max: 16 },

        // ── subject: what was acted on, as snapshots ─────────────────────
        { name: "subject_collection", type: "text", required: false, max: 64 },
        { name: "subject_id", type: "text", required: false, max: 32 },
        { name: "subject_label", type: "text", required: false, max: 200 },

        // ── correlation: the Spot everything hangs off ───────────────────
        // An indexed column rather than a lookup into `refs`, because "what
        // happened at this building" is the one query this table gets asked
        // beyond the plain feed. `spot_label` matches spots.name's own max.
        { name: "spot_id", type: "text", required: false, max: 32 },
        { name: "spot_label", type: "text", required: false, max: 200 },

        // Other ids the row touched: {nest, visit, user, tour, …}. Opaque.
        { name: "refs", type: "json", required: false, maxSize: 5000 },
        // [{field, from, to}] — kept OUT of `detail` so one renderer in the
        // client handles every verb: a create reads "set to X", a delete
        // "cleared (was X)", an update "X → Y", with no new strings. A withheld
        // value is {field, redacted: true}, which keeps the FACT of the change
        // and drops the value. A relation-valued field carries from_label /
        // to_label beside the ids: what the target was CALLED when the row was
        // written, since it can be renamed or deleted afterwards.
        { name: "changes", type: "json", required: false, maxSize: 20000 },
        // The action-specific typed payload. Opaque.
        { name: "detail", type: "json", required: false, maxSize: 20000 },

        // info | notice | security. Lets the coordination filter role, access
        // and sign-in events out of the day-to-day noise.
        { name: "severity", type: "text", required: false, max: 16 },

        // Written only when organisations.settings.audit_log_client_info is
        // set, which this app never sets. See the header.
        { name: "ip", type: "text", required: false, max: 64 },
        { name: "user_agent", type: "text", required: false, max: 512 },

        // Correlates the rows of one request. A Besuch is one route, one
        // transaction and several records; they share this.
        { name: "request_id", type: "text", required: false, max: 64 },

        // The timestamp. Sort key is (created, id); no `updated`, by design —
        // there is no path that edits a row.
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
      ],
      indexes: [
        // The feed, and the three ways it is ever narrowed. Each leads with
        // `org`, because that is the scoping boundary and no query crosses it.
        // Paged by keyset: `?page=` over a table that grows while being read
        // skips and duplicates rows, and a log that silently omits an entry is
        // worse than no log.
        "CREATE INDEX idx_audit_events_org_created ON audit_events (org, created DESC)",
        "CREATE INDEX idx_audit_events_org_spot ON audit_events (org, spot_id, created DESC)",
        "CREATE INDEX idx_audit_events_org_actor ON audit_events (org, actor_id, created DESC)",
        "CREATE INDEX idx_audit_events_org_action ON audit_events (org, action, created DESC)",
      ],
    });
    app.save(audit);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("audit_events"));
  },
);
