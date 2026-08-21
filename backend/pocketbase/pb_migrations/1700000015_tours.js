/// <reference path="../pb_data/types.d.ts" />

// eiermann-avq.1 — tours, tour_spots, tour_runs: the route, and the walking of
// it.
//
// A Tour is two different things that a single collection would confuse:
//
//   * `tours` + `tour_spots` — the TEMPLATE. "Tour 1" as a shared name and an
//     ordered list of buildings. It is edited between rounds, it is reused, and
//     it is what makes the handover survivable: whoever walks the route for the
//     first time reads the same list as the person who has walked it for years.
//   * `tour_runs` — one WALKING of a route, on one day, by one person. It
//     happened the way it happened, so it is history and not configuration.
//
// ── `tour` is optional on a run, and that is the whole ad-hoc mode ──────────
//
// A run with no template is the improvised round: three overdue Spots on the
// way home. Tour scale varies wildly in this group — sometimes one building,
// sometimes a planned full-day sweep — and a schema in which every run needs a
// template first would push the small case out of the app entirely. Somebody
// then walks it and writes nothing, which is the WhatsApp history all over
// again.
//
// So there is no `tours` row called "ad hoc", and no nullable-template
// workaround: the relation is simply not required, and the client shows a run
// without a name as "Runde" rather than inventing one.
//
// ── Progress is the visits, not a fourth collection ────────────────────────
//
// The obvious fourth table is `tour_run_spots`: one row per planned stop, with
// a state of done/skipped. It is not here, because every one of those states is
// already a `visit`:
//
//   * a checked Spot        → a visit with `outcome = checked`
//   * a Spot skipped        → a visit with `outcome = skipped` and a
//     with a reason           `skip_reason` — the SAME six reasons a lone visit
//                             uses, so nothing about a skip is tour-specific
//   * a Spot added mid-run  → a visit whose Spot is not in `tour_spots`
//
// which is why `visits.tour_run` is added by this migration and nothing else
// is. Progress = the template's stops LEFT JOIN this run's visits, computed
// where it is displayed. A second representation of the same fact is a second
// thing to keep in step, and the one that would drift is the derived one.
//
// It also makes the concept's "adding and skipping are equal-rank actions, not
// error paths" true in the schema rather than only in the UI: both write the
// same row shape, and neither needs a state the other does not have.
//
// ── What a run does NOT snapshot, and the drift that costs ─────────────────
//
// A run does not copy the template's spot list. If somebody edits "Tour 1"
// while a run of it is open, the open run's planned stops change under it.
//
// That is a real, accepted cost, and the reason it is accepted is that the
// alternative is worse in this domain: a snapshot would freeze a route that a
// coordinator edited BECAUSE of something the walker just reported ("the yard
// is a building site, drop it"). Follow-up dates are stored precisely because a
// plan must not shift retroactively — but a `due_at` is a promise about a
// single nest, while a tour is a list somebody is standing in front of. The
// list should be current. The visits already written are the immutable part,
// and they are stored per-visit, so no edit can rewrite what was done.
//
// ── The name snapshot ──────────────────────────────────────────────────────
//
// `tour_runs.tour_name` is not denormalisation for speed. `tour_runs.tour` does
// not cascade: a retired or deleted template must not take last spring's rounds
// with it. Which means the relation can go empty, and an id whose target is
// gone describes the past WRONGLY — "a run of (nothing)". So the run stores the
// name it was walked under, the same reason every visit stores `author_name`.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && (@request.auth.role = "member" || @request.auth.role = "coordinator")';
const COORDINATOR = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && @request.auth.role = "coordinator"';

migrate(
  (app) => {
    const organisations = app.findCollectionByNameOrId("organisations");
    const spots = app.findCollectionByNameOrId("spots");
    const users = app.findCollectionByNameOrId("users");

    // ── The template ───────────────────────────────────────────────────────
    const tours = new Collection({
      type: "base",
      name: "tours",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Any active member may build a template. This group is small and
      // everybody does field work; the person who knows the route is the person
      // who walks it, not necessarily the one with the coordinator role. The
      // destructive end of the same collection is the coordination's.
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false',
      // Deleting a template destroys its stop list and orphans every run ever
      // walked under it — the run survives (see `tour_name`), but the route
      // that produced it is gone and cannot be walked again. `is_active = false`
      // is the move for a route the group has stopped walking, and it keeps
      // both.
      deleteRule: `${COORDINATOR} && org = @request.auth.org`,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          collectionId: organisations.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        { name: "name", type: "text", required: true, min: 1, max: 120 },
        { name: "note", type: "text", required: false, max: 2000 },
        // Not `required`: PocketBase reads a required bool as "must be true",
        // which would make a retired template unrepresentable. The client sets
        // it explicitly on create.
        { name: "is_active", type: "bool", required: false },
        // Tours have an order the group thinks in — "Tour 1", "Tour 2", the
        // Thursday round. Alphabetical scatters that the moment one is named
        // after a district.
        { name: "sort_index", type: "number", required: false, onlyInt: true },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        "CREATE INDEX idx_tours_org_sort ON tours (org, sort_index)",
        // A name IS the identity here: "Tour 1 fortsetzen" has to mean one
        // thing. Two templates called "Tour 1" in one org make every sentence
        // the app says about a tour ambiguous, so the database refuses it —
        // case-insensitively, because "tour 1" is the same route to a reader.
        // The price: a retired template keeps its name occupied. That is
        // deliberate; reusing the name of a route the group used to walk is
        // exactly the ambiguity this index exists to prevent.
        "CREATE UNIQUE INDEX idx_tours_org_name ON tours (org, name COLLATE NOCASE)",
      ],
    });
    app.save(tours);

    // ── The ordered route ──────────────────────────────────────────────────
    const tourSpots = new Collection({
      type: "base",
      name: "tour_spots",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      // Only `sort_index` is editable. Re-pointing a stop at another Spot or
      // another Tour is not an edit anybody means to make: it silently rewrites
      // what a route is while every screen keeps showing the same row. Removing
      // the stop and adding the right one is the honest operation, and it is one
      // extra tap.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.tour:isset = false' +
        ' && @request.body.spot:isset = false',
      // Removing a stop from a route destroys nothing but the stop — no visit,
      // no nest, no history hangs off it. Ordinary editing, so ordinary members.
      deleteRule: `${MEMBER} && org = @request.auth.org`,
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          collectionId: organisations.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        {
          name: "tour",
          type: "relation",
          required: true,
          collectionId: tours.id,
          maxSelect: 1,
          // A stop has no meaning without the route it is a stop on.
          cascadeDelete: true,
        },
        {
          name: "spot",
          type: "relation",
          required: true,
          collectionId: spots.id,
          maxSelect: 1,
          // A deleted building cannot remain a stop on a route. Note this is
          // the ONLY thing deleting a Spot destroys that is not part of that
          // building's own memory — the route loses a stop, and the remaining
          // stops keep their order.
          cascadeDelete: true,
        },
        { name: "sort_index", type: "number", required: false, onlyInt: true },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // Every read of a route is "this tour's stops, in order".
        "CREATE INDEX idx_tour_spots_tour_sort ON tour_spots (tour, sort_index)",
        "CREATE INDEX idx_tour_spots_org ON tour_spots (org)",
        // The same building twice on one route is a mistake every time — it
        // makes progress uncountable ("2 of 7 done" over six distinct
        // buildings) and there is no field trip it describes.
        "CREATE UNIQUE INDEX idx_tour_spots_unique ON tour_spots (tour, spot)",
      ],
    });
    app.save(tourSpots);

    // ── One walking of a route ─────────────────────────────────────────────
    const tourRuns = new Collection({
      type: "base",
      name: "tour_runs",
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      createRule: `${MEMBER} && @request.body.org = @request.auth.org`,
      // Finishing a run and annotating it are the only edits. Everything that
      // says WHICH run this is — the template, the name it was walked under, who
      // walked it, when it started — is pinned, because those are the facts the
      // visits inside it are grouped by. `finished_at` is the one-way door:
      // there is no `is_open` flag to fall out of step with it, the absence of a
      // timestamp IS open.
      updateRule:
        `${MEMBER} && org = @request.auth.org` +
        ' && @request.body.org:isset = false' +
        ' && @request.body.tour:isset = false' +
        ' && @request.body.tour_name:isset = false' +
        ' && @request.body.started_by:isset = false' +
        ' && @request.body.started_by_name:isset = false' +
        ' && @request.body.started_at:isset = false',
      // You may discard YOUR OWN run while it is still open. That is the
      // accidental start — a tap on the dashboard, wrong tour — and without a
      // way out it sits there being offered as "fortsetzen" forever.
      //
      // A FINISHED run is history and nothing deletes it, not even the
      // coordination: it is what a set of visits was walked as, and the visits
      // it grouped cannot be deleted either. Note that `visits.tour_run` does
      // NOT cascade, so even discarding an open run leaves any visit already
      // recorded in it standing, with an empty run.
      deleteRule:
        `${MEMBER} && org = @request.auth.org` +
        " && started_by = @request.auth.id && finished_at = null",
      fields: [
        {
          name: "org",
          type: "relation",
          required: true,
          collectionId: organisations.id,
          maxSelect: 1,
          cascadeDelete: false,
        },
        {
          name: "tour",
          type: "relation",
          // NOT required: a run without a template is the improvised round.
          required: false,
          collectionId: tours.id,
          maxSelect: 1,
          // The run outlives the route. See the header.
          cascadeDelete: false,
        },
        // The snapshot beside the id. Empty for an ad-hoc run — which is how a
        // reader tells "improvised" from "the template is gone".
        { name: "tour_name", type: "text", required: false, max: 120 },
        {
          name: "started_by",
          type: "relation",
          required: true,
          collectionId: users.id,
          maxSelect: 1,
          // A deleted account must not take the rounds it walked with it.
          cascadeDelete: false,
        },
        { name: "started_by_name", type: "text", required: false, max: 200 },
        { name: "started_at", type: "date", required: true },
        // Absent = open. The dashboard's "Tour 1 fortsetzen" is exactly this
        // field being empty, which is why there is no second flag for it.
        { name: "finished_at", type: "date", required: false },
        { name: "note", type: "text", required: false, max: 2000 },
        { name: "created", type: "autodate", onCreate: true, onUpdate: false },
        { name: "updated", type: "autodate", onCreate: true, onUpdate: true },
      ],
      indexes: [
        // The dashboard's question: has this person got a run still open? A
        // partial index would be tidier, but PocketBase parses these itself and
        // the org+person+finished shape answers the same query.
        "CREATE INDEX idx_tour_runs_open ON tour_runs (org, started_by, finished_at)",
        "CREATE INDEX idx_tour_runs_org_started ON tour_runs (org, started_at)",
        "CREATE INDEX idx_tour_runs_tour ON tour_runs (tour, started_at)",
      ],
    });
    app.save(tourRuns);

    // ── The join back to the work: visits.tour_run ─────────────────────────
    //
    // Added here rather than in migration 009 because 009 is an applied
    // historical fact. The field is optional in both directions: a visit made
    // outside any round has no run, and a run's progress is read through this
    // relation.
    const visits = app.findCollectionByNameOrId("visits");
    visits.fields.add(
      new Field({
        name: "tour_run",
        type: "relation",
        required: false,
        collectionId: tourRuns.id,
        maxSelect: 1,
        // Deleting a run must not delete the visits made during it. The visit
        // is the observation this whole app exists to keep; the run is only the
        // bag it was carried in.
        cascadeDelete: false,
      }),
    );
    // The visits collection's update rule guards every field that is not the
    // free-text note, one `:isset` clause at a time (see 009). A new field with
    // no guard would be the one thing an update could rewrite — moving a visit
    // into another round after the fact, which changes what a completed run
    // says was done on it. Appended rather than restated: restating the rule
    // here would put a second copy of the whole guard list in a second file.
    const guard = ' && @request.body.tour_run:isset = false';
    if (!String(visits.updateRule || "").includes("tour_run")) {
      visits.updateRule = String(visits.updateRule) + guard;
    }
    app.save(visits);

    // A run's progress, and the Spot chronology's "walked as part of Tour 1".
    // Added as a second save because indexes and fields go through different
    // setters and doing both in one call has bitten before.
    const withIndex = app.findCollectionByNameOrId("visits");
    withIndex.indexes = withIndex.indexes.concat([
      "CREATE INDEX idx_visits_tour_run ON visits (tour_run)",
    ]);
    app.save(withIndex);
  },
  (app) => {
    const visits = app.findCollectionByNameOrId("visits");
    visits.indexes = visits.indexes.filter(
      (i) => !String(i).includes("idx_visits_tour_run"),
    );
    visits.fields.removeByName("tour_run");
    visits.updateRule = String(visits.updateRule || "").replace(
      ' && @request.body.tour_run:isset = false',
      "",
    );
    app.save(visits);

    app.delete(app.findCollectionByNameOrId("tour_runs"));
    app.delete(app.findCollectionByNameOrId("tour_spots"));
    app.delete(app.findCollectionByNameOrId("tours"));
  },
);
