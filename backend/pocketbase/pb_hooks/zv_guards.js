/// <reference path="../pb_data/types.d.ts" />

// The two record guards every Zugvogel app registers, as functions its own
// thin `.pb.js` wires up. See templates/pb_hooks/ for those wrappers.
//
// Both are here rather than in their own files because they are two lines each:
// the reasoning lives in zv_org_scope.js and zv_authorship.js, and splitting a
// registration across two more files would only add places to look.

/**
 * federfall-jo1l / -ti77 — a record's relations must live in its own org.
 *
 * Register on the MODEL events (onRecordCreate/onRecordUpdate), NOT the
 * *Request variants: a server-side route writes with `tx.save()`, which fires no
 * request hook, and a row's org must hold for those writers too. Custody-style
 * checks are the opposite case — they are about who is ASKING, so they need
 * `e.auth` and therefore a request event.
 *
 * Deliberately registered with NO collection tags. A tag list is the hand-kept
 * list this replaces: the point is that a collection added tomorrow is covered
 * without anybody remembering to come back. The check's first act is to ask
 * whether this record's collection has any relation worth looking at, and for
 * most writes the answer costs no query.
 */
function orgScope(e, isCreate, config) {
  const bad = require(`${__hooks}/zv_org_scope.js`).foreignRelation(
    e.app,
    e.record,
    isCreate,
    config,
  );
  if (bad) {
    throw new BadRequestError("`" + bad + "` belongs to another organisation.");
  }
  e.next();
}

/**
 * federfall-vfry — pin the authorship fields to the authenticated caller.
 *
 * Register on the *Request variants over the app's own collection tag list.
 * `RecordRequestEvent` is the only event kind carrying `e.auth`, and it is also
 * exactly the surface at issue: server-side routes write with `$app.save`, which
 * fires no request hook, and they already set these fields from the
 * authenticated user themselves. So this covers the direct collection writes and
 * leaves the routes alone.
 *
 * ── Why a hook and not a create rule ──────────────────────────────────────
 * `@request.body.author = @request.auth.id` would work — but it REJECTS a create
 * that omits the field instead of filling it in, which makes it a wire-contract
 * break for any client that does not send it. Setting the value server-side is
 * invisible to a well-behaved client and simply corrects a misbehaving one.
 *
 * A superuser write is left untouched: a superuser is not a `users` record, so
 * there is no id to pin that would not dangle.
 */
function authorship(e, actorFields, isCreate) {
  if (!e.hasSuperuserAuth()) {
    let isUser = false;
    try {
      isUser = !!e.auth && String(e.auth.collection().name) === "users";
    } catch (_) {
      isUser = false;
    }
    if (isUser) {
      require(`${__hooks}/zv_authorship.js`).stampActor(e, actorFields, {
        isCreate: isCreate,
      });
    }
  }
  e.next();
}

module.exports = { orgScope: orgScope, authorship: authorship };
