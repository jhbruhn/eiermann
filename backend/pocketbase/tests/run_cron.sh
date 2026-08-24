#!/usr/bin/env bash
# eiermann-gb1 — the cron harness. Boots a throwaway PocketBase with the cron
# schedules rewritten, so a job whose real cadence is daily can actually be
# observed.
#
# ── Why crons need their own harness ───────────────────────────────────────
#
# `cronAdd` jobs are invisible to the rule suite: nothing an HTTP request can do
# will trigger one, so a job can be wrong for months and every test stays green.
# The only way to watch one run is to make it due, which means rewriting its
# schedule — and that means the hooks have to be MOUNTED from a copy rather than
# taken from the image.
#
# That mount is also why this script copies the zv_* libraries out of the image
# first. A mount over /pb/pb_hooks replaces the whole directory, and the shared
# libraries live in zugvogel-pb-base rather than in this repo — without the copy
# every `require` of one fails at request time, which surfaces during setup as a
# generic 400 and reads like a schema problem.
#
# ── Backdating vs a small window ───────────────────────────────────────────
#
# A window measured against a server-owned column (`created`) cannot be reached
# by backdating, and the usual answer is to make the window vanishingly small in
# the test. This job is the easier case: it keys on `paused_until`, which a client
# writes, so the test backdates that directly and the window needs no rewriting.
# Only the SCHEDULE does.
#
# Usage:  backend/pocketbase/tests/run_cron.sh
# Env:    ZV_TEST_PORT (default 8098 — one above the rule suite's, so both can
#         run at once)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PB_DIR="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$PB_DIR/../.." && pwd)"
IMAGE="eiermann-pocketbase:test"
PORT="${ZV_TEST_PORT:-8098}"
NAME="zv_cron_$$"
DATA="$(mktemp -d)"
HOOKS="$(mktemp -d)"
ADMIN_EMAIL="admin@eiermann.local"
ADMIN_PASS="Admin12345!"
COORD_EMAIL="coordinator@eiermann.local"
COORD_PASS="CoordPass12345!"

cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  docker run --rm -v "$DATA:/data" --entrypoint sh "$IMAGE" \
    -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null' >/dev/null 2>&1 || true
  rm -rf "$DATA" "$HOOKS"
}
trap cleanup EXIT

echo "==> Building image $IMAGE"
# Unconditionally, for the same reason the rule suite does: the hooks are baked,
# so a cached image tests whatever was in it the day it was first built.
docker build --target backend -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"

echo "==> Copying hooks and making the auto-resume job due every minute"
cp -r "$PB_DIR/pb_hooks/." "$HOOKS/"
# The shared libraries, which the mount below would otherwise hide.
docker run --rm -v "$HOOKS:/out" --entrypoint sh "$IMAGE" \
  -c 'cp /pb/pb_hooks/zv_*.js /out/'
ls "$HOOKS"/zv_*.js >/dev/null 2>&1 || {
  echo "FATAL: no zv_* libraries copied out of $IMAGE" >&2; exit 1; }

sed -i 's|cronAdd("spotAutoResume", "20 4 \* \* \*"|cronAdd("spotAutoResume", "* * * * *"|' \
  "$HOOKS/spot_auto_resume.pb.js"
# The guard matters more than the sed: a schedule that silently failed to be
# rewritten produces a suite that waits, sees nothing happen, and reports the
# job as broken — or worse, one that is adjusted until it passes.
grep -q 'cronAdd("spotAutoResume", "\* \* \* \* \*"' "$HOOKS/spot_auto_resume.pb.js" || {
  echo "FATAL: the auto-resume schedule was not rewritten — did it change?" >&2
  exit 1
}

# The second job: the geocode cache purge. Same treatment, and it needs no
# window rewriting either — it keys on `expires_at`, which the cache WRITES
# rather than inheriting from the server, so the suite can put a row's expiry in
# the past directly. (`created` would have been the unreachable case: an autodate
# cannot be backdated, and then the constant would have to be patched in this
# copy while being pinned in the original.)
sed -i 's|cronAdd("geocodeCachePurge", "0 4 \* \* \*"|cronAdd("geocodeCachePurge", "* * * * *"|' \
  "$HOOKS/geocode.pb.js"
grep -q 'cronAdd("geocodeCachePurge", "\* \* \* \* \*"' "$HOOKS/geocode.pb.js" || {
  echo "FATAL: the geocode purge schedule was not rewritten — did it change?" >&2
  exit 1
}

# The third job: the audit retention purge. This is the case the geocode comment
# above calls out as the unreachable one — it keys on `created`, an autodate the
# SERVER owns, so no test can backdate a row into the window. The window itself
# has to shrink instead.
#
# `audit_retention_days` is a float here, so the suite can set a window of about
# nine seconds (0.0001 days) and watch a row cross it while the test runs. That
# number is a SETTING rather than a constant, so nothing in the hook needs
# patching for it — only the schedule does.
sed -i 's|cronAdd("auditRetention", "30 3 \* \* \*"|cronAdd("auditRetention", "* * * * *"|' \
  "$HOOKS/audit_retention.pb.js"
grep -q 'cronAdd("auditRetention", "\* \* \* \* \*"' "$HOOKS/audit_retention.pb.js" || {
  echo "FATAL: the audit retention schedule was not rewritten — did it change?" >&2
  exit 1
}

MOUNTS=(
  -v "$HOOKS:/pb/pb_hooks:ro"
  -v "$DATA:/pb/pb_data"
)

echo "==> Applying migrations to throwaway data dir"
docker run --rm "${MOUNTS[@]}" "$IMAGE" migrate up

echo "==> Creating superuser"
docker run --rm "${MOUNTS[@]}" "$IMAGE" superuser upsert "$ADMIN_EMAIL" "$ADMIN_PASS"

echo "==> Starting server on :$PORT"
# `--dev` overrides the image's CMD purely to get logs on STDOUT. Without it
# PocketBase writes its log records to an internal table, `docker logs` shows
# nothing at all, and a hook that threw is indistinguishable from a hook that
# never ran — which is precisely the state this harness exists to diagnose. The
# SQL noise is the price.
docker run -d --name "$NAME" -p "$PORT:8090" \
  -e EIERMANN_COORDINATOR_EMAIL="$COORD_EMAIL" \
  -e EIERMANN_COORDINATOR_PASSWORD="$COORD_PASS" \
  -e EIERMANN_NOMINATIM_URL=http://127.0.0.1:1 \
  "${MOUNTS[@]}" \
  "$IMAGE" serve \
  --http=0.0.0.0:8090 \
  --dir=/pb/pb_data \
  --migrationsDir=/pb/pb_migrations \
  --hooksDir=/pb/pb_hooks \
  --automigrate=0 \
  --dev >/dev/null

echo "==> Waiting for health"
for _ in $(seq 1 40); do
  curl -sf "http://localhost:$PORT/api/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://localhost:$PORT/api/health" >/dev/null || {
  echo "server never became healthy"; docker logs "$NAME"; exit 1; }

echo "==> Running cron suite"
ZV_TEST_URL="http://localhost:$PORT" \
ZV_ADMIN_EMAIL="$ADMIN_EMAIL" \
ZV_ADMIN_PASS="$ADMIN_PASS" \
EIERMANN_COORD_EMAIL="$COORD_EMAIL" \
EIERMANN_COORD_PASS="$COORD_PASS" \
PYTHONPATH="$PB_DIR/tests" \
  python3 "$HERE/test_cron.py" || {
    status=$?
    echo "==> Container log (errors and this app's lines)"
    # Both, and not just "eiermann:" — an uncaught error in a hook is reported as
    # a bare ERROR with a JS stack and never carries the app prefix, which is
    # exactly the failure that leaves a create answering a generic 400 with an
    # empty `data`.
    docker logs "$NAME" 2>&1 \
      | grep -viE 'SELECT|INSERT INTO|UPDATE .* SET|CREATE (TABLE|INDEX)' \
      | grep -A2 -iE 'eiermann:|ERROR' | tail -30 || echo "  (none)"
    exit $status
  }
