#!/usr/bin/env bash
# eiermann-fi2.5 — compiles both report templates against a fixture payload and
# asserts on the TEXT that comes out.
#
#   backend/pocketbase/typst/tests/run.sh
#
# ── Why the text and not the exit code ─────────────────────────────────────
#
# A zero exit from `typst compile` proves almost nothing about a template. A
# `set` rule inside a function that does not take its body compiles perfectly
# and styles NOTHING, so a footer that silently fails to render looks exactly
# like one that was never asked for — that is the bug zugvogel's own probe caught
# while `a4Report` was being written. An unmapped enum, a `#let` that ended at a
# line break and typeset its own source, a rate printed as 0 % instead of a
# dash: all of these compile.
#
# ── Why in a container ─────────────────────────────────────────────────────
#
# `typst` and `pdftotext` both live in the image, and the TEMPLATES ARE BAKED
# there rather than mounted — so the build is what picks up an edit, and what is
# under test is the file layout that ships (`/pb/typst`, where the app's
# templates sit beside the base image's zv_report_common.typ). Mounting host
# files over the image would mean the image itself is never exercised, which is
# the same fidelity hole the rule suite closed.
#
# Only the payload is mounted, and under the typst `--root`: a path outside /pb
# is unreadable to typst, exactly as it is for the real hook.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"   # repo root (holds the Dockerfile)
IMAGE="eiermann-typst:test"

echo "==> Building $IMAGE"
docker build --target typsttest -t "$IMAGE" -f "$ROOT/Dockerfile" "$ROOT"

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

render() {
  local template="$1"
  # `--root /pb` so the template can read shared_strings.json beside itself, and
  # the payload arrives as a FILE (`dataPath`) rather than an --input string:
  # an argv element is size-capped and world-readable in the process table, and
  # this payload carries one entry per visit in the period.
  docker run --rm \
    -v "$HERE/fixture.json:/pb/report-tmp/data.json:ro" \
    --entrypoint sh "$IMAGE" -c "
      set -e
      typst compile --root /pb --input dataPath=/report-tmp/data.json \
        /pb/typst/$template /tmp/out.pdf
      pdftotext /tmp/out.pdf -
    "
}

# Matching is case-INSENSITIVE. The section headings are typeset through
# `upper()`, so pdftotext reads them back as "BESUCHE JE ADRESSE" — asserting the
# uppercase form would tie every one of these to a styling choice, and asserting
# the mixed-case form would silently stop matching them. The words are what is
# under test.
fail=0
check() {
  local label="$1"
  local text="$2"
  shift 2
  for expected in "$@"; do
    if ! grep -qiF -- "$expected" <<<"$text"; then
      echo "  MISSING in $label: $expected" >&2
      fail=1
    fi
  done
}
refute() {
  local label="$1"
  local text="$2"
  shift 2
  for unexpected in "$@"; do
    if grep -qiF -- "$unexpected" <<<"$text"; then
      echo "  UNEXPECTED in $label: $unexpected" >&2
      fail=1
    fi
  done
}

echo "==> report.typ (Behördenbericht)"
report="$(render report.typ)"
check "report.typ" "$report" \
  "Bericht zur Gelegekontrolle 2026" \
  "Stadttauben Oldenburg e. V." \
  "kontakt@example.org · 0441 123456" \
  "01.01.2026 – 31.12.2026" \
  "Eier entnommen" \
  "Besuche je Adresse" \
  "Mühlenstraße 5, 26121 Oldenburg" \
  "Hinterhof Nord" \
  "14.03.2026" \
  "Getauscht" \
  "Halbgelege" \
  "Geschützte Art" \
  "Totfund" \
  "brandneu" \
  "Dohle" \
  "Nicht geprüft · Kein Schlüssel" \
  "Erstellt am 21.08.2026" \
  "Seite 1 von"
# The strings mechanism, both halves: the template's own dict AND
# shared_strings.json resolve through the same `S`. A missing merge would drop
# exactly the second kind.
check "report.typ shared strings" "$report" "Nester geprüft" "Attrappen gelegt"
# A building with no street identifies itself by name rather than leaving the
# reader an empty heading.
refute "report.typ" "$report" \
  "Im gewählten Zeitraum ist kein Besuch erfasst" \
  "keine Angaben"

echo "==> summary.typ (Förderer-Zusammenfassung)"
summary="$(render summary.typ)"
# A KPI label sits in a narrow box and wraps, so only a distinctive fragment of
# it survives as one line of extracted text. The value beside it is asserted too,
# which is the half that would break if the aggregate changed.
check "summary.typ" "$summary" \
  "Jahresübersicht Gelegemanagement 2026" \
  "Entnommene Eier im Zeitverlauf" \
  "betreute Gebäude" \
  "Zugang erhalten" \
  "67 %" \
  "vollständig" \
  "75 %" \
  "Gebäude nach Status" \
  "In Betreuung" \
  "Erkundungen nach Stand" \
  "Eigentümer gesprochen" \
  "Stand heute, unabhängig vom gewählten Zeitraum." \
  "Besuche je Gebäude" \
  "Balken: entnommene Eier"
# A funder's document must NOT carry the per-visit detail: that is the authority
# report's job, and a list of individual trips answers a question a funder did
# not ask while its length hides the two figures they did.
refute "summary.typ" "$summary" "Besuche je Adresse" "14.03.2026"

echo "==> the English half resolves too"
# Not decoration: `?lang=en` is a supported parameter, and a report that falls
# back to German for half its strings is the failure mode the two-file mechanism
# exists to prevent.
en="$(sed 's/"lang": "de"/"lang": "en"/' "$HERE/fixture.json" > "$OUT/en.json"; \
  docker run --rm -v "$OUT/en.json:/pb/report-tmp/data.json:ro" \
    --entrypoint sh "$IMAGE" -c "
      set -e
      typst compile --root /pb --input dataPath=/report-tmp/data.json \
        /pb/typst/report.typ /tmp/out.pdf
      pdftotext /tmp/out.pdf -
    ")"
check "report.typ (en)" "$en" \
  "Clutch management report 2026" \
  "Nests checked" \
  "Half clutch" \
  "Protected species" \
  "Not checked · No key" \
  "Generated 2026-08-21" \
  "Page 1 of"
refute "report.typ (en)" "$en" "Nester geprüft" "Halbgelege"

if [ "$fail" -ne 0 ]; then
  echo "typst templates: FAILED" >&2
  exit 1
fi
echo "typst templates: ok"
