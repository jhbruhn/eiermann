#!/bin/sh
# Apply migrations, THEN serve. Baked into the image, not only the dev override.
#
# ── Why this exists ────────────────────────────────────────────────────────
#
# `onBootstrap` + `e.next()` does NOT guarantee the migrations have been applied.
# The coordinator-bootstrap hook in main.pb.js runs there, and on a fresh data
# directory it found no `organisations` collection at all — so it silently did
# nothing on the FIRST boot of a new instance, which is the only boot where it
# matters. Restarting the container fixed it, which is the worst possible
# symptom: a self-hoster sees "no way in", restarts, and it works, and nobody
# ever learns why.
#
# Verified against the real image before this file existed: first boot, login
# 400 and no log line; after a restart, 200.
#
# The dev override had its own `migrate up && exec serve` command and therefore
# never showed the problem — the shipped image was the broken one. Fixed here so
# the ordering is a property of the image, and the override no longer has to
# restate it.
set -e

# Only for `serve`. `migrate down`, `superuser upsert` and friends must run
# exactly what was asked, and quietly migrating up before a `migrate down` would
# be actively wrong.
if [ "$1" = "serve" ]; then
  # The paths are fixed by the Dockerfile (COPY .. /pb/pb_migrations, /pb/pb_data
  # created there). Taking them from the serve arguments would mean parsing
  # flags in shell, for no gain.
  pocketbase migrate up --dir=/pb/pb_data --migrationsDir=/pb/pb_migrations
fi

exec pocketbase "$@"
