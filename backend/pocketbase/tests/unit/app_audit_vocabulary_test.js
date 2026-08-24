// Node tests for the audit VOCABULARY — the tables, not the machinery.
//
//   node backend/pocketbase/tests/unit/app_audit_vocabulary_test.js
//
// These run without a server and without the image. That is the whole reason
// `app_audit_vocabulary.js` requires nothing: `zv_audit.js` is vendored into the
// base image and is not in this repo, so anything that reaches for it can only
// be checked inside a running container — and these tables are exactly the half
// worth checking in milliseconds.
//
// What is NOT here: everything that needs the machinery. Whether a contact's
// phone number is actually redacted, whether a diff drops a derived field,
// whether a row lands in `spot_id` — those need `withRegistry` and are asserted
// against a live schema in the rule suite (eiermann-30w.8). Guessing at a stub
// for them would only test the stub.

const assert = require("node:assert");
const { test } = require("node:test");
const path = require("node:path");

global.__hooks = path.join(__dirname, "..", "..", "pb_hooks");

const vocab = require(path.join(global.__hooks, "app_audit_vocabulary.js"));

test("the vocabulary loads with no vendored module present", () => {
  // The point of the file having no require: a developer's machine has no
  // zv_audit.js, and a vocabulary that could only be read inside a container
  // would be a vocabulary nothing cheap could check.
  assert.ok(vocab.ACTION_LIST.length > 0);
  assert.deepStrictEqual(vocab.SEVERITY, {
    INFO: "info",
    NOTICE: "notice",
    SECURITY: "security",
  });
});

test("every action string is unique", () => {
  // Two names for one wire value would merge silently: the second would file
  // its rows under the first's meaning, and the client would render them as
  // that first sentence forever.
  const seen = new Map();
  for (const name of Object.keys(vocab.ACTIONS)) {
    const wire = vocab.ACTIONS[name];
    assert.ok(
      !seen.has(wire),
      `${name} and ${seen.get(wire)} are both "${wire}"`,
    );
    seen.set(wire, name);
  }
});

test("every action is domain.verb, lowercase, no German", () => {
  // The shape the client's label map is keyed by, and the shape a reader of the
  // stored table can group on. A hook never sends user-facing text, so an
  // action that is not this shape is usually one somebody wrote as a sentence.
  for (const wire of vocab.ACTION_LIST) {
    assert.match(wire, /^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$/, wire);
  }
});

test("COLLECTION_ACTIONS names only actions that exist", () => {
  // The Tier A registry is looked up at request time and its miss is silent:
  // `emitRecordChange` returns early on an unknown action, so a typo here is a
  // collection that is quietly never audited.
  const known = new Set(vocab.ACTION_LIST);
  for (const collection of Object.keys(vocab.COLLECTION_ACTIONS)) {
    const spec = vocab.COLLECTION_ACTIONS[collection];
    for (const verb of Object.keys(spec)) {
      const action = spec[verb];
      if (action === null) continue; // covered elsewhere, or cannot happen
      assert.ok(known.has(action), `${collection}.${verb} -> ${action}`);
    }
  }
});

test("every audited collection covers all three verbs explicitly", () => {
  // `null` is a decision ("this verb is covered elsewhere"); a MISSING key is an
  // oversight, and the two read identically at the call site. Saying so here
  // means a new entry has to answer for the delete it did not list.
  for (const collection of Object.keys(vocab.COLLECTION_ACTIONS)) {
    const spec = vocab.COLLECTION_ACTIONS[collection];
    for (const verb of ["created", "updated", "deleted"]) {
      assert.ok(verb in spec, `${collection} does not say what ${verb} means`);
    }
  }
});

test("DEFAULT_SEVERITY names only actions that exist", () => {
  const known = new Set(vocab.ACTION_LIST);
  for (const action of Object.keys(vocab.DEFAULT_SEVERITY)) {
    assert.ok(known.has(action), `severity for unknown action ${action}`);
  }
});

test("DEFAULT_SEVERITY uses only the three levels", () => {
  const levels = new Set(Object.keys(vocab.SEVERITY).map((k) => vocab.SEVERITY[k]));
  for (const action of Object.keys(vocab.DEFAULT_SEVERITY)) {
    assert.ok(
      levels.has(vocab.DEFAULT_SEVERITY[action]),
      `${action} -> ${vocab.DEFAULT_SEVERITY[action]}`,
    );
  }
});

test("the acts that can be illegal or unmakeable are not filed as noise", () => {
  // Releasing a nest re-enables egg removal on it; a role change hands somebody
  // the coordination. Both are the reason this table exists, and `info` would
  // put them in the same filter as an ordinary Besuch.
  for (const action of [
    "nest.unprotected",
    "user.role_changed",
    "user.deactivated",
    "auth.login_failed",
  ]) {
    assert.strictEqual(
      vocab.DEFAULT_SEVERITY[action],
      vocab.SEVERITY.SECURITY,
      action,
    );
  }
});

test("CONTENT_FIELDS covers every audited collection", () => {
  // A create or a delete records the allowlist and nothing else, so a missing
  // entry is not an error anywhere — it is a row that says a thing was created
  // and declines to say what it was.
  for (const collection of Object.keys(vocab.COLLECTION_ACTIONS)) {
    const fields = vocab.CONTENT_FIELDS[collection];
    assert.ok(Array.isArray(fields) && fields.length, `${collection} records nothing`);
  }
});

test("no allowlisted content field is one the log withholds", () => {
  // The two tables would otherwise disagree in the direction that leaks: a
  // field named in CONTENT_FIELDS and also in SENSITIVE or FREE_TEXT still ends
  // up redacted by `contentOf`, but the entry reads as if it were recorded, and
  // the next person copies the pattern to a field where nothing catches it.
  const prose = new Set(vocab.FREE_TEXT);
  for (const collection of Object.keys(vocab.CONTENT_FIELDS)) {
    const withheld = new Set(vocab.SENSITIVE[collection] || []);
    for (const field of vocab.CONTENT_FIELDS[collection]) {
      assert.ok(
        !withheld.has(field),
        `${collection}.${field} is in CONTENT_FIELDS and SENSITIVE`,
      );
      assert.ok(
        !prose.has(field),
        `${collection}.${field} is in CONTENT_FIELDS and FREE_TEXT`,
      );
    }
  }
});

test("a member of the public is never labelled and never recorded", () => {
  // spot_contacts is this app's finders: a Hausmeister did not sign up for
  // anything, and their name in an append-only table outlives every correction.
  // Both halves are load-bearing — redacting the fields while letting the
  // subject label carry the name would undo the redaction from the envelope.
  assert.ok(vocab.NEVER_LABELLED.includes("spot_contacts"));
  for (const field of ["name", "phone", "email", "note"]) {
    assert.ok(
      vocab.SENSITIVE.spot_contacts.includes(field),
      `spot_contacts.${field} is not withheld`,
    );
  }
  assert.ok(
    !vocab.LABEL_FIELDS.spot_contacts,
    "a never-labelled collection with label fields is a contradiction",
  );
});

test("the correlation is the Spot, and names this app's own columns", () => {
  // eiermann-30w.1: before zugvogel 6f5ef44 these rows landed in `case_id`
  // whatever the app called its centre.
  const c = vocab.REGISTRY.correlation;
  assert.strictEqual(c.collection, "spots");
  assert.strictEqual(c.field, "spot");
  assert.strictEqual(c.labelField, "name");
  assert.strictEqual(c.column, "spot_id");
  assert.strictEqual(c.labelColumn, "spot_label");
});

test("every collection that reaches a Spot only through a parent says so", () => {
  // Without the hop, such a row edited directly through the collection API is
  // filed under nothing at all and never appears in its building's history.
  // These three are the collections with no `spot` relation of their own.
  for (const collection of ["visit_photos", "nest_checks", "nest_eggs"]) {
    const via = vocab.REGISTRY.correlation.via[collection];
    assert.ok(via && via.field && via.collection, `${collection} has no hop`);
  }
});

test("the registry is the tables, not a copy of them", () => {
  // A registry assembled from literals would drift from the tables the tests
  // and the parsers read, and nothing would say so.
  assert.strictEqual(vocab.REGISTRY.sensitive, vocab.SENSITIVE);
  assert.strictEqual(vocab.REGISTRY.freeText, vocab.FREE_TEXT);
  assert.strictEqual(vocab.REGISTRY.neverLabelled, vocab.NEVER_LABELLED);
  assert.strictEqual(vocab.REGISTRY.labelFields, vocab.LABEL_FIELDS);
  assert.strictEqual(vocab.REGISTRY.relationTargets, vocab.RELATION_TARGETS);
  assert.strictEqual(vocab.REGISTRY.defaultSeverity, vocab.DEFAULT_SEVERITY);
  assert.strictEqual(
    vocab.REGISTRY.loginFailedAction,
    vocab.ACTIONS.AUTH_LOGIN_FAILED,
  );
});
