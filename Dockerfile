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

# The shared PocketBase runtime: the binary, the zv_* hook libraries, the Typst
# base and the migrate-before-serve entrypoint. Published from zugvogel by
# .github/workflows/pb-base.yml.
#
# Pinned to a `sha-<commit>` tag for the same reason the Dart packages are pinned
# to a commit hash: it names one commit and nothing can re-point it. `latest`
# exists on that package and must not be used here.
#
# Bumping it is a deliberate step, exactly like bumping the pubspec pin — and the
# two are independent: a change to zugvogel's Dart packages does not move this,
# and a change to the shared hooks does not move the pubspec.
ARG ZUGVOGEL_PB_BASE=ghcr.io/jhbruhn/zugvogel-pb-base:sha-6f5ef44dc0e393f9a90c1ec9f831fe00d3201a9c

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

# ── Typst fetch ───────────────────────────────────────────────────────────────
# The report renderer (eiermann-fi2.6). A single static Rust binary, fetched and
# verified with the same rigour as the PocketBase binary in the base image —
# EXCEPT that Typst publishes no checksums.txt, so these SHA256s were computed
# by hand from the v0.15.0 release assets. Bumping TYPST_VERSION therefore means
# re-downloading and re-hashing both architectures yourself; there is no upstream
# file to diff against.
#
# Bundled rather than fetched at runtime, for the same reason as everything else
# in this file: a self-hosted instance that cannot render a report without
# reaching GitHub is not self-hosted, and a permission renewal is not the moment
# to discover that.
#
# ── Why this lives here and not in zugvogel-pb-base ─────────────────────────
# It arguably belongs there: the base already ships the Typst report BASE
# (`/pb/typst/zv_report_common.typ`), and federfall carries an identical fetch
# stage — two copies of one decision. Measured against the pinned base image
# (sha-d7ea6d19): /pb/typst exists, `typst` is not on PATH. Moving the binary
# into the base is filed as eiermann-uxn; until that image is published and the
# pin bumped, following federfall's precedent is what keeps the two apps' report
# pipelines identical.
FROM alpine:3.20 AS typstfetch
ARG TYPST_VERSION=0.15.0
ARG TARGETARCH
RUN apk add --no-cache wget xz ca-certificates
WORKDIR /typst
RUN set -eux; \
    case "${TARGETARCH}" in \
        amd64) TT_TARGET=x86_64-unknown-linux-musl; TT_SHA256=59b207df01be2dab9f13e80f73d04d7ff8273ffd46b3dd1b9eef5c60f3eeabea ;; \
        arm64) TT_TARGET=aarch64-unknown-linux-musl; TT_SHA256=cdf50ffc7b8ba759ed02200632eda3d78eb8b99aacb6611f4f75684990647620 ;; \
        *)     echo "unsupported arch: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    wget -q "https://github.com/typst/typst/releases/download/v${TYPST_VERSION}/typst-${TT_TARGET}.tar.xz" -O /tmp/typst.tar.xz; \
    echo "${TT_SHA256}  /tmp/typst.tar.xz" | sha256sum -c -; \
    tar -xJf /tmp/typst.tar.xz -C /typst --strip-components=1; \
    rm /tmp/typst.tar.xz; \
    chmod +x /typst/typst

# ── Backend runtime (lean: PB + migrations + hooks, no web) ────────────────────
# This stage IS the rule-test image (built via `--target backend`), which is the
# point: the suite exercises the image that ships, not a directory of host files
# mounted over it.
#
# The base brings PocketBase, the zv_* libraries, the Typst base and the
# entrypoint. Everything added below is eiermann's own.
FROM ${ZUGVOGEL_PB_BASE} AS backend
# Released images get this set to the release-please version via --build-arg.
# zv_info.js reads it at request time, so the RUNNING IMAGE is the single source
# of truth for the version it reports and no source file needs a release-time
# edit. Local builds keep the dev default, which the version check reads as
# "unversioned" and lets through.
ARG EIERMANN_VERSION=0.0.0-dev
ENV EIERMANN_VERSION=${EIERMANN_VERSION}
# Baked in, so the image is self-contained: nothing here is bind-mounted, in dev
# or in production. It used to be, and that was a fidelity hole — the rule suite
# and the dev stack both ran host files while the image sat untested underneath.
#
# `pb_hooks/` holds ONLY eiermann's own hooks now. The zv_* libraries come from
# the base image and land in the same directory, so a `require` finds them
# exactly as before — and there is no vendored copy left to drift.
# report.pb.js shells out to this.
COPY --from=typstfetch /typst/typst /usr/local/bin/typst
COPY backend/pocketbase/pb_migrations/ /pb/pb_migrations/
COPY backend/pocketbase/pb_hooks/      /pb/pb_hooks/
# eiermann's report templates and the shared_strings.json both they and the CSV
# branch read. They land in the SAME directory as the base image's
# zv_report_common.typ, which is what lets `#import "zv_report_common.typ"`
# resolve as a plain sibling import — and why this is a merge into /pb/typst/
# rather than a directory of its own.
COPY backend/pocketbase/typst/         /pb/typst/
# A signpost at `/` for the lean image, which has no SPA to serve. Without it the
# address answers 404, which is indistinguishable from a broken deployment — and
# that cost real confusion once. The `full` stage copies the Flutter build over
# this directory, and its own index.html wins, so the signpost only ever appears
# on the image that needs it.
COPY backend/pocketbase/pb_public_dev/ /pb/pb_public/
EXPOSE 8090
# automigrate OFF by default: the schema changes only through the committed
# migration files above, and never drifts in from somebody clicking in the Admin
# UI. A migration is a historical fact; the Admin UI does not write history.
# ENTRYPOINT comes from the base: it applies migrations before handing off to
# `serve`. Not decoration — the coordinator-bootstrap hook runs in onBootstrap,
# which is NOT guaranteed to be after the migrations, so on a fresh volume it did
# nothing on the first boot and worked on the second. The base deliberately sets
# no CMD, so each app states its own flags rather than inheriting a wrong default.
CMD ["serve", "--http=0.0.0.0:8090", \
     "--dir=/pb/pb_data", \
     "--migrationsDir=/pb/pb_migrations", \
     "--hooksDir=/pb/pb_hooks", \
     "--publicDir=/pb/pb_public", \
     "--automigrate=0"]

# ── Template test stage ───────────────────────────────────────────────────────
# `backend/pocketbase/typst/tests/run.sh` builds this and asserts on the TEXT of
# a rendered report. It exists as its own stage for two reasons:
#
#   * `pdftotext` is needed to read the output, and a PDF text extractor has no
#     business shipping in the production image;
#   * a template edit must be exercised by the test. The templates are BAKED into
#     the image (not mounted), so the test's build is what picks the edit up —
#     the same stance the rule suite takes, and for the same reason: mounting
#     host files over an image means the image itself is never tested.
#
# Assertions are on the text and not on typst's exit code, because a `set` rule
# inside a function that does not take its body compiles perfectly and styles
# NOTHING — a footer that silently fails to render looks exactly like one that
# was never asked for.
FROM backend AS typsttest
RUN apk add --no-cache poppler-utils
# Deliberately NOT the last stage in this file: a `docker build` with no
# `--target` takes whatever stage comes last, and CI's "build the full image"
# step passes none. Ending the file here would have quietly turned that job into
# a build of this stage — which skips the Flutter web build entirely and would
# have reported success for an image nobody had compiled.

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
