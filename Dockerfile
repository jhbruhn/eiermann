# syntax=docker/dockerfile:1
#
# Eiermann — one image, two targets.
#
#   --target backend   PocketBase + migrations + hooks. No Flutter. This is the
#                      image the rule-test harness builds.
#   (default) full     the same, plus the built web SPA served from /pb/pb_public.
#
# eiermann-h7q.8. Everything fetched here is PINNED and CHECKSUM-VERIFIED: a
# self-hosted instance that cannot be rebuilt byte-for-byte is not really
# self-hosted, and a supply-chain swap in a tile-sized dependency is exactly the
# kind of thing nobody notices.

ARG PB_VERSION=0.39.8

# ── Flutter web build ──────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS flutterbuild

# Keep in sync with the repo's pinned Flutter (apps/eiermann: flutter ^3.44.0)
# AND with zugvogel's CI, which compiles the shared library with the same
# toolchain.
ARG FLUTTER_VERSION=3.44.3

ENV DEBIAN_FRONTEND=noninteractive \
    PUB_CACHE=/pub-cache \
    PATH="/flutter/bin:/flutter/bin/cache/dart-sdk/bin:${PATH}"

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git unzip xz-utils \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${FLUTTER_VERSION}" \
        https://github.com/flutter/flutter.git /flutter \
    && git config --global --add safe.directory /flutter \
    && flutter --version \
    && flutter config --no-analytics --enable-web \
    && flutter precache --web

WORKDIR /src

# Resolve dependencies first, so a source edit does not re-run pub get. The
# workspace root pubspec has to come along: every member resolves through it.
COPY pubspec.yaml ./
COPY apps/eiermann/pubspec.yaml apps/eiermann/
COPY packages/eiermann_models/pubspec.yaml packages/eiermann_models/
COPY packages/eiermann_data/pubspec.yaml packages/eiermann_data/
RUN flutter pub get

COPY . .

# Codegen and l10n before the build, once PER PACKAGE that declares
# build_runner: it only generates for the package it runs in, and a workspace
# does not change that.
#
# `cd` into each, rather than a flag. build_runner has no `--directory` option —
# its positional argument is a directory INSIDE the package to build — so
# `--directory packages/eiermann_models` is a usage error and exits 64. That
# broke the `full` image from the day the packages were added, and went unseen
# because the dev override builds the `backend` target, which skips this stage
# entirely. The only thing that exercises it is building the full image.
RUN cd packages/eiermann_models \
    && dart run build_runner build --delete-conflicting-outputs \
    && cd ../../apps/eiermann \
    && dart run build_runner build --delete-conflicting-outputs \
    && flutter gen-l10n

# --wasm for the dart2wasm/skwasm renderer, which needs the COOP/COEP headers the
# web_headers hook serves. --no-web-resources-cdn keeps canvaskit out of
# gstatic, which is what lets the CSP stay same-origin.
RUN cd apps/eiermann && flutter build web --release --wasm \
        --no-web-resources-cdn \
        --target lib/main_production.dart \
        --dart-define-from-file=dart_defines/production.json

# ── PocketBase fetch ──────────────────────────────────────────────────────────
FROM alpine:3.20 AS pbfetch
ARG PB_VERSION
ARG TARGETARCH
RUN apk add --no-cache unzip wget ca-certificates
WORKDIR /pb
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) PB_ARCH=amd64; PB_SHA256=3b675575ff0e6dcc5befc85a9644aea6b04ac617ce125ecb2b6989a3c5b5664f ;; \
        arm64) PB_ARCH=arm64; PB_SHA256=d9e44e40f2483b468bb4dd64e12b554aa85941dc5ee9c4bb87aee8fa9e469425 ;; \
        arm)   PB_ARCH=armv7; PB_SHA256=4824b6999c93227a2a544783e4007e57f43b72aac37f2aebbc99fe75055328b9 ;; \
        *)     echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q "https://github.com/pocketbase/pocketbase/releases/download/v${PB_VERSION}/pocketbase_${PB_VERSION}_linux_${PB_ARCH}.zip" -O /tmp/pb.zip; \
    echo "${PB_SHA256}  /tmp/pb.zip" | sha256sum -c -; \
    unzip /tmp/pb.zip -d /pb; \
    rm /tmp/pb.zip; \
    chmod +x /pb/pocketbase

# ── Backend runtime (lean: PB + migrations + hooks, no web) ────────────────────
# This stage IS the rule-test image (built via `--target backend`).
FROM alpine:3.20 AS backend
RUN apk add --no-cache ca-certificates tzdata wget
COPY --from=pbfetch /pb/pocketbase /usr/local/bin/pocketbase
WORKDIR /pb
# Released images get this set to the release-please version via --build-arg.
# zv_info.js reads it at request time, so the RUNNING IMAGE is the single source
# of truth for the version it reports and no source file needs a release-time
# edit. Local builds keep the dev default, which the version check reads as
# "unversioned" and lets through.
ARG EIERMANN_VERSION=0.0.0-dev
ENV EIERMANN_VERSION=${EIERMANN_VERSION}
RUN mkdir -p /pb/pb_data
# Baked in, so the image is self-contained: production runs these with no host
# bind mounts. Local dev shadows them via docker-compose.override.yml, which is
# also where automigrate goes back on.
COPY backend/pocketbase/pb_migrations/ /pb/pb_migrations/
COPY backend/pocketbase/pb_hooks/      /pb/pb_hooks/
COPY backend/pocketbase/entrypoint.sh  /usr/local/bin/entrypoint.sh
EXPOSE 8090
# automigrate OFF by default: the schema changes only through the committed
# migration files above, and never drifts in from somebody clicking in the Admin
# UI. A migration is a historical fact; the Admin UI does not write history.
# The entrypoint applies migrations before handing off to `serve`. It is not
# decoration: the coordinator-bootstrap hook runs in onBootstrap, which is NOT
# guaranteed to be after the migrations, and on a fresh volume it therefore did
# nothing on the first boot and worked on the second. See entrypoint.sh.
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["serve", "--http=0.0.0.0:8090", \
     "--dir=/pb/pb_data", \
     "--migrationsDir=/pb/pb_migrations", \
     "--hooksDir=/pb/pb_hooks", \
     "--automigrate=0"]

# ── Full app image (backend + the web SPA) ────────────────────────────────────
FROM backend AS full
# Where PocketBase serves static files. --indexFallback (on by default) sends
# unknown non-/api, non-/_ paths to index.html, so a client-side deep link
# resolves; the API and Admin routes still take precedence.
COPY --from=flutterbuild /src/apps/eiermann/build/web /pb/pb_public
# Inherits the entrypoint from `backend`; only the served paths differ.
CMD ["serve", "--http=0.0.0.0:8090", \
     "--dir=/pb/pb_data", \
     "--migrationsDir=/pb/pb_migrations", \
     "--hooksDir=/pb/pb_hooks", \
     "--publicDir=/pb/pb_public", \
     "--automigrate=0"]
