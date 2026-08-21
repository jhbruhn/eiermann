#!/usr/bin/env bash
# Bump the zugvogel commit pin in EVERY workspace member at once.
#
#   tools/bump-zugvogel.sh <40-char-commit-hash>
#
# Why this exists as a script: a pub workspace resolves ONE ref per git
# dependency, so bumping apps/eiermann/pubspec.yaml alone leaves the whole
# workspace at a hard `version solving failed`. That happened twice in one
# session — the failure is loud but its cause is not, because the error names
# version solving and not the two files that disagree.
set -euo pipefail

HASH="${1:-}"
if [[ ! "$HASH" =~ ^[0-9a-f]{40}$ ]]; then
  echo "usage: $0 <40-char-commit-hash>" >&2
  echo "" >&2
  echo "A full hash, never a tag: a tag can be re-pointed, pub caches by ref," >&2
  echo "and two machines then resolve the same declaration onto different code." >&2
  exit 2
fi

cd "$(dirname "$0")/.."
mapfile -t FILES < <(grep -rl 'github.com/jhbruhn/zugvogel' --include='pubspec.yaml' .)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "no pubspec.yaml declares zugvogel — nothing to bump" >&2
  exit 1
fi

for file in "${FILES[@]}"; do
  sed -i "s/ref: [0-9a-f]\{40\}/ref: $HASH/g" "$file"
  echo "  bumped $file"
done

echo ""
echo "All ${#FILES[@]} members now pin $HASH. Next: flutter pub get from the root."
