#!/usr/bin/env bash
#
# Verify that src/carquet is exactly the pinned commit of the qio branch of the
# carquet fork, and that the fork's branch is exactly the pinned upstream commit
# plus the recorded patch series.
#
#   tools/check-vendor-drift.sh
#
# The fork sits between qio and upstream: its `main` mirrors upstream, and its
# `qio` branch carries one commit per local patch on top of the upstream pin.
# That makes the vendored tree reproducible from two commit ids and nothing
# else, so this check has three parts:
#
#   1. src/carquet matches the fork at the fork pin, file for file.
#   2. The upstream pin is an ancestor of the fork pin -- the series really is
#      built on the pinned upstream commit and not on some other base.
#   3. The number of commits between them matches the ledger, so a patch added
#      to the fork without a ledger entry fails here.
#
# Requires: git, rsync, and network access to both repositories. Reads both
# pins and both URLs from .agents/VENDORED.md so there is one source of truth.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

ledger=".agents/VENDORED.md"
vendored="src/carquet"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$ledger" ] || fail "missing $ledger"
[ -d "$vendored" ] || fail "missing $vendored"

# The internal notes must never ship in the source package; the ledger and the
# pins live there, so this is checked in the same place it matters.
grep -q '^\^\\\.agents\$' .Rbuildignore ||
    fail ".Rbuildignore does not exclude .agents/"

# Both pins come from the table at the top of the ledger. Each row is
# `| [name](url) | ... | `commit` | ... |`.
read_row() {
    local label="$1" row
    row="$(grep -E "^\| \[$label\]" "$ledger" || true)"
    [ -n "$row" ] || fail "no $label row in $ledger"
    printf '%s' "$row"
}

upstream_row="$(read_row carquet)"
fork_row="$(read_row 'carquet fork')"

upstream_url="$(printf '%s' "$upstream_row" | grep -oE 'https://[^)]+' | head -1)"
upstream_pin="$(printf '%s' "$upstream_row" | grep -oE '[0-9a-f]{40}' | head -1)"
fork_url="$(printf '%s' "$fork_row" | grep -oE 'https://[^)]+' | head -1)"
fork_pin="$(printf '%s' "$fork_row" | grep -oE '[0-9a-f]{40}' | head -1)"

[ -n "$upstream_pin" ] || fail "no 40-character commit in the carquet row of $ledger"
[ -n "$fork_pin" ] || fail "no 40-character commit in the carquet fork row of $ledger"

# One ledger entry per patch, each a level-3 heading under "Local carquet
# patches". The series on the fork must have exactly that many commits.
expected_patches="$(awk '
    /^## Local carquet patches/ { in_section = 1; next }
    /^## / { in_section = 0 }
    in_section && /^### / { n++ }
    END { print n + 0 }
' "$ledger")"
[ "$expected_patches" -gt 0 ] || fail "no patch entries found in $ledger"

echo "upstream: $upstream_url @ $upstream_pin"
echo "fork:     $fork_url @ $fork_pin"
echo "ledger:   $expected_patches patches"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --filter=blob:none --no-checkout "$fork_url" "$work/fork"
git -C "$work/fork" remote add upstream "$upstream_url"
git -C "$work/fork" fetch --quiet --filter=blob:none upstream

git -C "$work/fork" cat-file -e "$upstream_pin^{commit}" 2>/dev/null ||
    fail "upstream pin $upstream_pin is not reachable from $upstream_url"
git -C "$work/fork" cat-file -e "$fork_pin^{commit}" 2>/dev/null ||
    fail "fork pin $fork_pin is not reachable from $fork_url"

# 2. The series is built on the pinned upstream commit.
git -C "$work/fork" merge-base --is-ancestor "$upstream_pin" "$fork_pin" ||
    fail "upstream pin $upstream_pin is not an ancestor of fork pin $fork_pin.
The fork's qio branch was rebased onto a different upstream commit than the one
recorded in $ledger, or the ledger is stale."

# 3. One commit per ledger entry.
actual_patches="$(git -C "$work/fork" rev-list --count "$upstream_pin..$fork_pin")"
[ "$actual_patches" = "$expected_patches" ] || fail \
"the fork carries $actual_patches commits over the upstream pin but $ledger
records $expected_patches patches. Every commit on the fork's qio branch needs a
ledger entry, and every entry needs a commit."

# 1. The vendored tree matches the fork, file for file.
git -C "$work/fork" checkout --quiet "$fork_pin"

# Assemble the fork in the vendored layout. Keep this list in step with the
# "Included source" section of .agents/VENDORED.md.
mkdir -p "$work/expected"
cp -R "$work/fork/include/carquet" "$work/expected/carquet"
for dir in compression core encoding metadata reader simd thrift util writer; do
    [ -d "$work/fork/src/$dir" ] || fail "the fork is missing src/$dir"
    cp -R "$work/fork/src/$dir" "$work/expected/$dir"
done
cp "$work/fork/LICENSE" "$work/expected/LICENSE"

# Copy the vendored tree without build products.
mkdir -p "$work/actual"
rsync -a --exclude='*.o' --exclude='*.so' --exclude='*.dll' --exclude='*.dylib' \
    "$vendored/" "$work/actual/"

if ! diff -ru "$work/actual" "$work/expected"; then
    fail "$vendored differs from $fork_url at $fork_pin.
A vendored file was edited in place instead of on the fork. Make the change on
the fork's qio branch, push it, and update the fork pin in $ledger."
fi

echo "OK: $vendored is $fork_url @ $fork_pin, exactly,"
echo "    which is upstream $upstream_pin plus $actual_patches recorded patches."
