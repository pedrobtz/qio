#!/usr/bin/env bash
#
# Verify that src/carquet is exactly the pinned upstream commit plus
# .agents/carquet-changes.patch, and nothing else.
#
#   tools/check-vendor-drift.sh
#
# The check reverse-applies the patch to a copy of the vendored tree and
# compares the result with pristine upstream. Any difference means either a
# vendored file was edited without updating the patch record, or the patch no
# longer matches the tree. Both are drift, and both are what this catches.
#
# Requires: git, patch, rsync, and network access to the upstream repository.
# Reads the pin and repository URL from .agents/VENDORED.md so there is one
# source of truth for the version.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

ledger=".agents/VENDORED.md"
patch_file=".agents/carquet-changes.patch"
vendored="src/carquet"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[ -f "$ledger" ] || fail "missing $ledger"
[ -f "$patch_file" ] || fail "missing $patch_file"
[ -d "$vendored" ] || fail "missing $vendored"

# The internal notes must never ship in the source package; the patch record
# lives there, so this is checked in the same place it matters.
grep -q '^\^\\\.agents\$' .Rbuildignore ||
    fail ".Rbuildignore does not exclude .agents/"

ledger_row="$(grep -E '^\| \[carquet\]' "$ledger" || true)"
[ -n "$ledger_row" ] || fail "no carquet row in $ledger"

pin="$(printf '%s' "$ledger_row" | grep -oE '[0-9a-f]{40}' | head -1)"
url="$(printf '%s' "$ledger_row" | grep -oE 'https://[^)]+' | head -1)"
[ -n "$pin" ] || fail "no 40-character commit in the carquet row of $ledger"
[ -n "$url" ] || fail "no upstream URL in the carquet row of $ledger"

echo "upstream: $url"
echo "pin:      $pin"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

git clone --quiet --filter=blob:none --no-checkout "$url" "$work/upstream"
git -C "$work/upstream" checkout --quiet "$pin"

# Assemble pristine upstream in the vendored layout. Keep this list in step
# with the "Included source" section of .agents/VENDORED.md.
mkdir -p "$work/pristine/carquet"
cp -R "$work/upstream/include/carquet" "$work/pristine/carquet/carquet"
for dir in compression core encoding metadata reader simd thrift util writer; do
    [ -d "$work/upstream/src/$dir" ] || fail "upstream is missing src/$dir"
    cp -R "$work/upstream/src/$dir" "$work/pristine/carquet/$dir"
done
cp "$work/upstream/LICENSE" "$work/pristine/carquet/LICENSE"

# Copy the vendored tree without build products, then undo the local patches.
mkdir -p "$work/reversed"
rsync -a --exclude='*.o' --exclude='*.so' --exclude='*.dll' --exclude='*.dylib' \
    "$vendored/" "$work/reversed/carquet/"

if ! (cd "$work/reversed" && patch -p1 -R --quiet --fuzz=0 < "$root/$patch_file"); then
    fail "$patch_file does not reverse-apply cleanly to $vendored"
fi

if ! diff -ru "$work/reversed/carquet" "$work/pristine/carquet"; then
    fail "$vendored differs from upstream $pin after reversing $patch_file.
A vendored file was changed without updating the patch record, or the patch is
stale. Regenerate it as described in .agents/VENDORED.md."
fi

echo "OK: $vendored is upstream $pin plus $patch_file, exactly."
