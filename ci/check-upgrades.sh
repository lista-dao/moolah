#!/usr/bin/env bash
#
# Run upgrade-guard over a set of upgradeable contracts, comparing the OLD build
# (base branch / last release) against the NEW build (PR head).
#
# Usage: check-upgrades.sh <old-out-dir> <new-out-dir> <targets-file> [src-dir]
#
# Target selection (the switch):
#   * If <targets-file> has any non-comment entries  -> use them verbatim
#     (manual override / allow-list).
#   * Otherwise AUTO-DISCOVER every contract under <src-dir> (default "src")
#     that inherits UUPSUpgradeable — so new upgradeable contracts are covered
#     automatically and the list never goes stale.
#
# Targets entry format: `Contract` (assumes Contract.sol) or `File.sol:Contract`.
#
# Exit: 0 if every target is upgrade-safe, 1 if any is unsafe / errored.
set -uo pipefail

OLD_OUT="${1:?old out dir}"
NEW_OUT="${2:?new out dir}"
TARGETS="${3:?targets file}"
SRC_DIR="${4:-src}"

# Build the working list of entries into a temp file (portable to bash 3.2).
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

if [[ -f "$TARGETS" ]] && grep -qvE '^[[:space:]]*(#.*)?$' "$TARGETS"; then
  echo "Using manual target list: $TARGETS"
  sed 's/#.*//' "$TARGETS" | grep -vE '^[[:space:]]*$' > "$TMP"
else
  echo "No manual targets — auto-discovering UUPSUpgradeable contracts under $SRC_DIR/"
  grep -rl 'UUPSUpgradeable' "$SRC_DIR" --include='*.sol' \
    | xargs -n1 basename \
    | sed 's/\.sol$//' \
    | sort -u > "$TMP"
fi

count="$(grep -cvE '^[[:space:]]*$' "$TMP" || true)"
if [[ "$count" -eq 0 ]]; then
  echo "::error::no contracts to check (empty target list and no UUPSUpgradeable matches under $SRC_DIR/)"
  exit 1
fi
echo "Gating $count contract(s)."

fail=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
  entry="$(echo -n "$raw" | xargs)" # trim whitespace
  [[ -z "$entry" ]] && continue

  if [[ "$entry" == *:* ]]; then
    file="${entry%%:*}"; name="${entry##*:}"
  else
    name="$entry"; file="${name}.sol"
  fi

  old="$OLD_OUT/$file/$name.json"
  new="$NEW_OUT/$file/$name.json"

  if [[ ! -f "$new" ]]; then
    echo "::error::missing NEW artifact for $name ($new) — did the build emit storageLayout?"
    fail=1; continue
  fi
  if [[ ! -f "$old" ]]; then
    echo "::notice::$name has no base artifact — treating as a new contract, skipping upgrade check"
    continue
  fi

  echo "::group::upgrade check — $name"
  if upgrade-guard --old "$old" --new "$new"; then
    echo "::endgroup::"
  else
    echo "::endgroup::"
    echo "::error::$name failed the upgrade-safety check (see log above)"
    fail=1
  fi
done < "$TMP"

if [[ "$fail" -eq 0 ]]; then
  echo "All upgrade-safety checks passed."
fi
exit "$fail"
