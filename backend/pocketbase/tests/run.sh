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
# Env:    ZV_TEST_PORT (default 8097)
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

cleanup() {
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
#   request there). Nothing signs in through either; the credentials are fake.
docker run -d --name "$NAME" -p "$PORT:8090" \
  -e EIERMANN_COORDINATOR_EMAIL="$COORD_EMAIL" \
  -e EIERMANN_COORDINATOR_PASSWORD="$COORD_PASS" \
  -e EIERMANN_OAUTH2_PROVIDERS=oidc,google \
  -e EIERMANN_OAUTH2_OIDC_CLIENT_ID=test-client \
  -e EIERMANN_OAUTH2_OIDC_CLIENT_SECRET=test-secret \
  -e EIERMANN_OAUTH2_OIDC_AUTH_URL=https://id.invalid/authorize \
  -e EIERMANN_OAUTH2_OIDC_TOKEN_URL=https://id.invalid/token \
  -e EIERMANN_OAUTH2_OIDC_USERINFO_URL=https://id.invalid/userinfo \
  -e EIERMANN_OAUTH2_GOOGLE_CLIENT_ID=test-client \
  -e EIERMANN_OAUTH2_GOOGLE_CLIENT_SECRET=test-secret \
  -e EIERMANN_MAP_MODE=raster \
  -e EIERMANN_MAP_TILE_URL='https://raster.invalid/{z}/{x}/{y}.png' \
  -e EIERMANN_MAP_STYLE_URL=https://vector.invalid/style.json \
  -e EIERMANN_MAP_ATTRIBUTION='© Test Tiles' \
  -e EIERMANN_MAP_API_KEY=test-map-key \
  -e EIERMANN_NOMINATIM_URL=http://127.0.0.1:1 \
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
