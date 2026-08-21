/// <reference path="../pb_data/types.d.ts" />

// eiermann-3is.1 — species_labels: the Artbezeichnungen this org has actually
// written down.
//
// The app does not identify species. It asks the person standing in front of
// the nest, and it takes their words. So the picker behind that field cannot be
// a curated list: a seeded taxonomy goes stale in BOTH directions at once — it
// carries entries nobody in this city has seen in years, and it lacks the one
// bird the volunteer is looking at right now. federfall solved the same problem
// the same way for `animal_species`, and the property that makes it work is
// that there is nothing to maintain: the vocabulary IS the record.
//
// The price is stated where it is felt, in the field's own hint: two spellings
// are two rows. "Dohle" and "dohle" both appear, nothing normalises behind the
// user's back, and that is the cheaper problem — a normaliser that folds
// "Turmfalke" into "Turmfalken" is a normaliser that will one day fold two
// species together, and nobody will notice.
//
// ── Why BOTH tables ────────────────────────────────────────────────────────
//
// `findings.species_label` and `nests.species_label` are the same vocabulary
// used in two places: the dead jackdaw on the floor and the jackdaw nest in the
// attic are the same word, typed by the same people. Suggesting only one half
// would mean the volunteer who named the nest last month re-types the name — and
// re-types it differently, which is precisely the cost this view exists to keep
// small. The UNION is what makes one field's history the other field's picker.
//
// `UNION ALL` and not `UNION`: the deduplication is the GROUP BY, and it has to
// happen AFTER both halves are in, or `used_count` would count each table once
// instead of counting uses.
//
// ── The id ─────────────────────────────────────────────────────────────────
//
// `org || ':' || label`. A view needs an id and this is the only stable one
// available: the label is the identity of a row here, there is no underlying
// record to point at, and a ROW_NUMBER() would renumber every row the moment
// somebody records a species alphabetically ahead of the others. The org has to
// be in it because two organisations that both wrote "Dohle" are two rows, and
// an id colliding across tenants is a cache reading one org's row for another's.
//
// ── What is NOT here ───────────────────────────────────────────────────────
//
// No "last used" date. Both halves would have to supply one, and the nests half
// has nothing honest to offer: `nests.updated` moves when somebody corrects a
// position hint, so the column would claim a precision it does not have and the
// picker would reorder for reasons the reader cannot see. `used_count` is the
// ordering, and it is a count of rows — which is exactly what it says.

const MEMBER = '@request.auth.id != "" && @request.auth.is_active = true' +
  ' && (@request.auth.role = "member" || @request.auth.role = "coordinator")';

migrate(
  (app) => {
    const labels = new Collection({
      type: "view",
      name: "species_labels",
      // A view does NOT inherit the rules of the tables under it. Without these
      // two lines this is a public window onto every species anybody has ever
      // recorded, in every organisation.
      listRule: `${MEMBER} && org = @request.auth.org`,
      viewRule: `${MEMBER} && org = @request.auth.org`,
      // Every computed column is ONE line, however long: PocketBase parses this
      // SELECT list itself and follows neither a `--` comment nor an expression
      // wrapped across newlines — both come back as "invalid identifier parts".
      // The reasoning lives in the header above.
      //
      // `used_count` is a plain integer expression, which is what keeps it from
      // arriving quoted: a computed view column falls back to type `json`, and a
      // number that is not a bare integer expression crosses the wire as a
      // string.
      viewQuery: `
        SELECT
          (u.org || ':' || u.species_label) AS id,
          u.org AS org,
          u.species_label AS label,
          COUNT(*) AS used_count
        FROM (
          SELECT org, species_label FROM findings WHERE species_label IS NOT NULL AND species_label != ''
          UNION ALL
          SELECT org, species_label FROM nests WHERE species_label IS NOT NULL AND species_label != ''
        ) u
        GROUP BY u.org, u.species_label
      `,
    });
    app.save(labels);
  },
  (app) => {
    app.delete(app.findCollectionByNameOrId("species_labels"));
  },
);
