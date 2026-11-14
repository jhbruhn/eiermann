#!/usr/bin/env bash
# eiermann-h7q.19 — backend rule/hook tests against a throwaway PocketBase.
#
# From zugvogel's template; the harness it drives is shared, every assertion is
# this app's.
#
# Spins up a disposable container (fresh pb_data in a tempdir, migrations + hooks
# mounted, a known superuser), waits for health, runs the assertion suite against
# it, then tears everything down. The exit code propagates from the suite.
#
# Usage:  backend/pocketbase/tests/run.sh
# Env:    ZV_TEST_PORT (default 8097), ZV_OIDC_PORT (default 9181)
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PB_DIR="$(cd "$HERE/.." && pwd)"      # backend/pocketbase
ROOT="$(cd "$PB_DIR/../.." && pwd)"   # repo root (holds the Dockerfile)
IMAGE="eiermann-pocketbase:test"
PORT="${ZV_TEST_PORT:-8097}"
NAME="zv_test_$$"
DATA="$(mktemp -d)"
ADMIN_EMAIL="admin@eiermann.local"
ADMIN_PASS="Admin12345!"
# The app-level coordinator, distinct from the PocketBase superuser above: a
# superuser is an operator with no org and no role, so it cannot stand in for a
# member of the team in any rule test. The bootstrap hook creates this one.
COORD_EMAIL="coordinator@eiermann.local"
COORD_PASS="CoordPass12345!"
# eiermann-bd8 — the fake OIDC provider (fake_oidc.py) runs on the HOST, and the
# container reaches it through this name. Podman defines it by itself; Docker
# (CI) does not, which is why `docker run` below maps it explicitly to the
# host gateway. One name for both runtimes, so the server's config is the same.
OIDC_PORT="${ZV_OIDC_PORT:-9181}"
OIDC_HOST="host.containers.internal"
OIDC_PID=""

cleanup() {
  [ -n "$OIDC_PID" ] && kill "$OIDC_PID" >/dev/null 2>&1 || true
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # Files under $DATA/storage are created by the container as root, so the host
  # user cannot rm them directly — clear the contents from inside a container
  # (same image, already built) before removing the now-empty tempdir.
  docker run --rm -v "$DATA:/data" --entrypoint sh "$IMAGE" \
    -c 'rm -rf /data/* /data/.[!.]* /data/..?* 2>/dev/null' >/dev/null 2>&1 || true
  rm -rf "$DATA"
}
trap cleanup EXIT

echo "==> Building image $IMAGE"
# The lean PocketBase-only target of the repo Dockerfile (no Flutter web build).
#
# UNCONDITIONALLY, every run. The hooks and migrations are baked into the image
# now, so an inspect-or-build would test whatever was in it the day it was first
# built — a hook edit would look like a rule that does not work, or worse, like
# one that does. The layer is cached, so a run with nothing changed costs
# seconds.
docker build --target backend -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"

# Only the data directory is mounted. The hooks, migrations and Typst files are
# BAKED, and the suite now runs against the image's own copies.
#
# It used to mount all three, which was a fidelity hole in a rule suite: the
# thing under test was a directory of host files laid over the image, so the
# image itself was never exercised. It became an outright bug once the zv_*
# libraries moved into zugvogel-pb-base — mounting eiermann's pb_hooks over
# /pb/pb_hooks replaces the base's libraries with a directory that does not
# contain them, and every `require` fails at request time.
#
# The cost is a rebuild per hook edit. It is a cached COPY layer near the end of
# the Dockerfile, so it is seconds, and run.sh builds anyway.
MOUNTS=(
  -v "$DATA:/pb/pb_data"
)

echo "==> Applying migrations to throwaway data dir"
# Its own step, before serve. The coordinator-bootstrap hook runs in
# onBootstrap, and `--automigrate` had not yet created the collections it
# queries — so on a fresh data dir it failed on the first boot and quietly
# worked on the second. Explicit ordering instead of emergent.
docker run --rm "${MOUNTS[@]}" "$IMAGE" migrate up

echo "==> Creating superuser"
docker run --rm "${MOUNTS[@]}" "$IMAGE" superuser upsert "$ADMIN_EMAIL" "$ADMIN_PASS"

echo "==> Starting the fake OIDC provider on :$OIDC_PORT"
python3 "$HERE/fake_oidc.py" "$OIDC_PORT" &
OIDC_PID=$!
for _ in $(seq 1 20); do
  curl -sf "http://localhost:$OIDC_PORT/" >/dev/null && break
  sleep 0.25
done
curl -sf "http://localhost:$OIDC_PORT/" >/dev/null || {
  echo "fake OIDC provider never came up on :$OIDC_PORT"; exit 1; }

echo "==> Starting server on :$PORT"
# Every value below exists to make a specific assertion possible. Keep the
# reasons when you change them:
#
#   MAP_MODE=raster + a STYLE_URL for the OTHER mode — so a test can prove
#   /info ignores the wrong-mode URL while zv_web_headers still contributes its
#   origin to the CSP.
#
#   NOMINATIM_URL pointing at a CLOSED local port — no test may reach the real
#   Nominatim, and a refused connection is what makes "the input was rejected"
#   (400) distinguishable from "the input was accepted and the upstream then
#   failed" (502). Without that distinction a coordinate-validation test is
#   vacuous.
#
#   Two dummy OAuth2 providers — a generic OIDC one, which must be told to ask
#   for the groups scope because a group mapping is configured, and a social
#   one, which must NOT be (an unknown scope fails the whole authorization
#   request there). The credentials are fake. The OIDC one's token and userinfo
#   endpoints point at fake_oidc.py (eiermann-bd8), so the suite can complete a
#   real code exchange; its authorize URL stays at id.invalid, because the
#   browser half of the flow is never walked — the suite invents the code.
#
#   --add-host maps the provider's host name to the host gateway. Podman has
#   the name already (and accepts the mapping); Docker on CI needs it.
docker run -d --name "$NAME" -p "$PORT:8090" \
  --add-host="$OIDC_HOST:host-gateway" \
  -e EIERMANN_COORDINATOR_EMAIL="$COORD_EMAIL" \
  -e EIERMANN_COORDINATOR_PASSWORD="$COORD_PASS" \
  -e EIERMANN_OAUTH2_PROVIDERS=oidc,google \
  -e EIERMANN_OAUTH2_OIDC_CLIENT_ID=test-client \
  -e EIERMANN_OAUTH2_OIDC_CLIENT_SECRET=test-secret \
  -e EIERMANN_OAUTH2_OIDC_AUTH_URL=https://id.invalid/authorize \
  -e EIERMANN_OAUTH2_OIDC_TOKEN_URL="http://$OIDC_HOST:$OIDC_PORT/token" \
  -e EIERMANN_OAUTH2_OIDC_USERINFO_URL="http://$OIDC_HOST:$OIDC_PORT/userinfo" \
  -e EIERMANN_OAUTH2_GOOGLE_CLIENT_ID=test-client \
  -e EIERMANN_OAUTH2_GOOGLE_CLIENT_SECRET=test-secret \
  -e EIERMANN_MAP_MODE=raster \
  -e EIERMANN_MAP_TILE_URL='https://raster.invalid/{z}/{x}/{y}.png' \
  -e EIERMANN_MAP_STYLE_URL=https://vector.invalid/style.json \
  -e EIERMANN_MAP_ATTRIBUTION='© Test Tiles' \
  -e EIERMANN_MAP_API_KEY=test-map-key \
  -e EIERMANN_NOMINATIM_URL=http://127.0.0.1:1 \
  `# The report route's budget is 10 a minute in production, which is far above` \
  `# any human use and far below what this suite makes of it: the year-boundary` \
  `# assertions alone pull four exports, and the format matrix pulls six more.` \
  `# A throttled suite reports a 429 as a broken renderer, so the CAP is raised` \
  `# here — harness housekeeping, exactly as zugvogel's rate_limits assertion` \
  `# says it should be. That the budget is APPLIED at all is asserted through` \
  `# the settings, which is the property; the number is configuration.` \
  -e EIERMANN_REPORT_RATE_MAX=500 \
  "${MOUNTS[@]}" \
  "$IMAGE" >/dev/null

echo "==> Waiting for health"
for _ in $(seq 1 40); do
  curl -sf "http://localhost:$PORT/api/health" >/dev/null && break
  sleep 0.5
done
curl -sf "http://localhost:$PORT/api/health" >/dev/null || {
  echo "server never became healthy"; docker logs "$NAME"; exit 1; }

echo "==> Running assertion suite"
ZV_TEST_URL="http://localhost:$PORT" \
ZV_ADMIN_EMAIL="$ADMIN_EMAIL" \
ZV_ADMIN_PASS="$ADMIN_PASS" \
EIERMANN_COORD_EMAIL="$COORD_EMAIL" \
EIERMANN_COORD_PASS="$COORD_PASS" \
PYTHONPATH="$PB_DIR/tests" \
  python3 "$HERE/test_rules.py"
