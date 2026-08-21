#!/usr/bin/env bash
# Verify every workspace member pins the SAME zugvogel commit.
#
# Runs BEFORE `flutter pub get`, and that ordering is the entire point. A pub
# workspace resolves one ref per git dependency, so a half-bump fails at
# RESOLUTION — which means `flutter test` never executes and no Dart test can
# ever report it. A Dart guard for this was written and deleted for exactly that
# reason: it could only pass.
#
# pub's own message does name both files and both hashes, so this exists to add
# the one thing it cannot know — that there is a script which fixes it.
set -euo pipefail

cd "$(dirname "$0")/.."

mapfile -t FILES < <(grep -rl 'github.com/jhbruhn/zugvogel' --include='pubspec.yaml' .)
if [[ ${#FILES[@]} -lt 3 ]]; then
  # Guards the guard: if the search stops finding files, every check below would
  # pass by vacuum.
  echo "check-zugvogel-pin: expected at least 3 pubspecs declaring zugvogel," >&2
  echo "  found ${#FILES[@]}: ${FILES[*]:-none}" >&2
  exit 1
fi

REFS=$(grep -rh 'ref:' "${FILES[@]}" | awk '{print $NF}' | sort -u)
COUNT=$(echo "$REFS" | wc -l)

if [[ "$COUNT" -ne 1 ]]; then
  echo "check-zugvogel-pin: the workspace pins $COUNT different zugvogel commits," >&2
  echo "so \`flutter pub get\` cannot resolve. Found:" >&2
  for ref in $REFS; do
    echo "  $ref" >&2
    grep -rl "$ref" "${FILES[@]}" | sed 's/^/    /' >&2
  done
  echo "" >&2
  echo "Fix: tools/bump-zugvogel.sh <hash>  (edits every member at once)" >&2
  exit 1
fi

if [[ ! "$REFS" =~ ^[0-9a-f]{40}$ ]]; then
  # A tag can be re-pointed and pub caches by ref, so two machines would resolve
  # the same declaration onto different code.
  echo "check-zugvogel-pin: '$REFS' is not a 40-char commit hash." >&2
  echo "Pin a commit, never a tag or a branch." >&2
  exit 1
fi

echo "check-zugvogel-pin: ${#FILES[@]} members, all on $REFS"
