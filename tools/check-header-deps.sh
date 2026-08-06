#!/usr/bin/env bash
#
# Verify that touching a shared vendored header rebuilds every object.
#
#   tools/check-header-deps.sh
#
# carquet's reader_internal.h defines structs shared by several translation
# units. R's build rules do not track headers, so without the dependency rule
# in src/Makevars a header edit that changes a struct layout would relink new
# objects against stale ones: no linker error, memory corruption at runtime.
#
# This builds three times, so it takes a few minutes.
#
# It deliberately uses R CMD INSTALL and not pkgbuild::compile_dll(). devtools
# precleans, so every object is recompiled whatever Makevars says and the check
# would pass even with the dependency rule deleted. R CMD INSTALL runs plain
# make incrementally, which is both what users and CRAN do and the only way to
# observe a stale object being reused.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

header="src/carquet/reader/reader_internal.h"
[ -f "$header" ] || { echo "FAIL: missing $header" >&2; exit 1; }

lib="$(mktemp -d)"
marker="$(mktemp)"
trap 'rm -rf "$lib" "$marker"' EXIT

build() {
    R CMD INSTALL --no-docs --no-help --no-byte-compile -l "$lib" . >/dev/null 2>&1
}

count_objects() { find src -name '*.o' | wc -l | tr -d ' '; }
rebuilt_since_marker() { find src -name '*.o' -newer "$marker" | wc -l | tr -d ' '; }

echo "cleaning"
find src \( -name '*.o' -o -name '*.so' -o -name '*.dll' \) -delete

echo "first build"
build
total="$(count_objects)"
[ "$total" -gt 1 ] ||
    { echo "FAIL: expected many objects, found $total. Did the build link?" >&2
      exit 1; }
echo "built $total objects"

# Control: with nothing changed the build must be incremental, otherwise the
# test below cannot distinguish a working dependency from a full rebuild.
touch "$marker"; sleep 1
build
churn="$(rebuilt_since_marker)"
[ "$churn" -eq 0 ] ||
    { echo "FAIL: a no-change rebuild recompiled $churn of $total objects." >&2
      echo "The build is not incremental here, so this check cannot prove anything." >&2
      exit 1; }
echo "no-change rebuild recompiled 0 objects, as expected"

touch "$marker"; sleep 1
touch "$header"
build
rebuilt="$(rebuilt_since_marker)"
if [ "$rebuilt" -ne "$total" ]; then
    echo "FAIL: touching $header rebuilt only $rebuilt of $total objects." >&2
    echo "The rest would be relinked against a possibly changed struct layout:" >&2
    echo "no linker error, memory corruption at runtime." >&2
    echo "src/Makevars must declare the header dependency; see its comments." >&2
    exit 1
fi

echo "OK: a change to $header rebuilds all $total objects."
