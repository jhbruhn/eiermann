#!/usr/bin/env bash
# eiermann-uwd.8 — the coverage gate.
#
# Two checks, and the second is the one that matters more.
#
# ── 1. A floor on the line rate ────────────────────────────────────────────
#
# CI carried no floor until now, deliberately: "there is barely any code to
# cover and a number over a skeleton is theatre". There is code now, and the
# app sits at ~85%, so the floor goes in below that — high enough that a screen
# shipped without tests moves it, low enough that it is not a ratchet somebody
# games by testing getters.
#
# ── 2. Every lib/ file APPEARS in the report ───────────────────────────────
#
# The half a bare percentage cannot see. `flutter test --coverage` instruments
# only the libraries that were LOADED during the run, so a file no test ever
# imports does not appear in lcov.info at all — it is not counted as uncovered,
# it is not counted. A whole feature added without a single test therefore
# RAISES the reported percentage, because the average is taken over a smaller
# set. That is the opposite of what a coverage gate is for.
#
# So the files legitimately absent are listed here by name, with the reason, and
# anything else absent fails the build. Entrypoints and generated code cannot be
# unit-tested and pretending otherwise would be the theatre this file avoids.

set -euo pipefail

FLOOR="${COVERAGE_FLOOR:-80}"
LCOV="${1:-apps/eiermann/coverage/lcov.info}"

if [[ ! -f "$LCOV" ]]; then
  echo "no coverage report at $LCOV — run: (cd apps/eiermann && flutter test --coverage)" >&2
  exit 1
fi

# Files that may be absent from the report. Each is here because nothing can
# import it in a test, not because nobody got round to it.
ALLOWED_ABSENT=(
  # The four entrypoints and what they call. `main()` builds the app against a
  # real server and a real platform; a test that imported one would be starting
  # the app, not testing it.
  "lib/main.dart"
  "lib/main_development.dart"
  "lib/main_production.dart"
  "lib/main_staging.dart"
  "lib/bootstrap.dart"
  "lib/app/app.dart"
  "lib/app/view/app.dart"
  # The error reporter installs zone and Flutter error handlers process-wide.
  "lib/core/logging/app_logger.dart"
  # A conditional import triple: exactly one of the two implementations is
  # compiled per platform, and the stub exists to satisfy the other.
  "lib/routing/url_strategy/url_strategy.dart"
  "lib/routing/url_strategy/url_strategy_io.dart"
  "lib/routing/url_strategy/url_strategy_web.dart"
  # The same shape, for the browser window the identity-provider sign-in opens:
  # the web half imports `package:web`, which a VM test cannot load. The
  # interface and the native half ARE in the graph, so what stays untested here
  # is the two lines that talk to `window`.
  "lib/features/auth/oauth_popup_web.dart"
)

cd "$(dirname "$0")/.."

rate=$(awk -F: '
  /^LH:/ { hit += $2 }
  /^LF:/ { found += $2 }
  END {
    if (found == 0) { print "0.0"; exit }
    printf "%.1f", 100 * hit / found
  }
' "$LCOV")

echo "line coverage: ${rate}% (floor ${FLOOR}%)"

# The instrumented set, as repo-relative paths.
covered=$(grep '^SF:' "$LCOV" | sed 's|^SF:||' | sed 's|^\./||' | sort -u)

# Every hand-written library. Generated trees are excluded here rather than in
# the allowlist: `*.g.dart` and `*.freezed.dart` are rebuilt, never reviewed,
# and `l10n/gen/` carries `// coverage:ignore-file` for the same reason.
present=$(cd apps/eiermann && find lib -name '*.dart' \
  ! -name '*.g.dart' ! -name '*.freezed.dart' ! -path 'lib/l10n/gen/*' \
  | sort)

unexpected=()
while IFS= read -r file; do
  [[ -z "$file" ]] && continue
  if grep -Fxq "$file" <<<"$covered"; then
    continue
  fi
  allowed=false
  for entry in "${ALLOWED_ABSENT[@]}"; do
    [[ "$file" == "$entry" ]] && allowed=true && break
  done
  $allowed || unexpected+=("$file")
done <<<"$present"

status=0

if (( ${#unexpected[@]} > 0 )); then
  status=1
  echo >&2
  echo "These lib/ files are in NO test's import graph:" >&2
  printf '  %s\n' "${unexpected[@]}" >&2
  echo >&2
  echo "They are not counted as uncovered — they are not counted at all, which" >&2
  echo "means adding them RAISED the percentage above. Write a test that reaches" >&2
  echo "them, or add the file to ALLOWED_ABSENT in tools/check-coverage.sh with" >&2
  echo "the reason nothing can import it." >&2
fi

if awk -v r="$rate" -v f="$FLOOR" 'BEGIN { exit (r >= f) ? 0 : 1 }'; then
  :
else
  status=1
  echo >&2
  echo "Coverage ${rate}% is below the ${FLOOR}% floor." >&2
fi

exit $status
