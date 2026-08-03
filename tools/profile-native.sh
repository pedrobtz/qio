#!/usr/bin/env bash
set -euo pipefail

# Profile a read down to native (C) frames, and print the aggregated
# self-time and total-time tables.
#
#   tools/profile-native.sh data.parquet              # profile qio
#   tools/profile-native.sh data.parquet nanoparquet  # profile a comparison
#   SECONDS_TO_SAMPLE=30 INTERVAL_MS=1 tools/profile-native.sh data.parquet
#
# Every ranked profile in .agents/read-performance.md came from this. R's own
# Rprof() samples the R call stack and attributes an entire native read to one
# .Call, which is useless for ranking work inside carquet; this attaches a
# native sampler to the running process instead.
#
# The build flags are the point. A default R package build omits frame
# pointers, so the sampler cannot walk C stacks and reports unresolved
# addresses. R_MAKEVARS_USER is the injection point that works for any source
# build -- qio has no ./configure, so --configure-vars would be a no-op.
#
# macOS only: it uses sample(1). The Linux equivalent is
#   perf record -g --call-graph=fp -p <pid> && perf report
# with the same -fno-omit-frame-pointer build.

path="${1:?Usage: tools/profile-native.sh <file.parquet> [package] [output.txt]}"
package="${2:-qio}"
out="${3:-${package}.sample.txt}"
seconds="${SECONDS_TO_SAMPLE:-15}"
interval_ms="${INTERVAL_MS:-1}"
summary="${out%.txt}.summary.txt"

if [ ! -f "$path" ]; then
  echo "no such file: $path" >&2
  exit 1
fi
if ! command -v sample >/dev/null 2>&1; then
  echo "sample(1) not found; this script is macOS only. See the header for" >&2
  echo "the perf equivalent on Linux." >&2
  exit 1
fi

# Rebuild with debug symbols and frame pointers unless told not to. Skipping is
# only safe when the last build already used these flags.
if [ -z "${SKIP_INSTALL:-}" ]; then
  makevars="$(mktemp -t qio-profile-makevars.XXXXXX)"
  trap 'rm -f "$makevars"' EXIT
  cat > "$makevars" <<'FLAGS'
CFLAGS = -g -O2 -fno-omit-frame-pointer
CXXFLAGS = -g -O2 -fno-omit-frame-pointer
FLAGS
  export R_MAKEVARS_USER="$makevars"

  if [ "$package" = "qio" ]; then
    # -O2, never load_all(): see bench/README.md on the -O0 trap.
    find src \( -name '*.o' -o -name '*.so' \) -delete
    R CMD INSTALL .
  else
    Rscript -e "install.packages('$package', type = 'source', repos = 'https://cloud.r-project.org')"
  fi
fi

# A read loop for the sampler to attach to. Long enough that startup and the
# first read are a small fraction of the window.
driver="$(mktemp -t qio-profile-driver.XXXXXX.R)"
trap 'rm -f "$driver" "${makevars:-}"' EXIT
cat > "$driver" <<DRIVER
library($package)
path <- "$path"
invisible($package::read_parquet(path))  # warm up caches and the DLL
repeat {
  x <- $package::read_parquet(path)
  invisible(nrow(x))
}
DRIVER

Rscript "$driver" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -f "$driver" "${makevars:-}"' EXIT

sleep 0.5
echo "Sampling $package (pid $pid) for ${seconds}s every ${interval_ms}ms"
sample "$pid" "$seconds" "$interval_ms" -file "$out" || true
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true
echo "Wrote $out"

# sample(1) appends aggregated tables after the call tree. Those are the
# rankable part; the tree above them is too deep to read directly.
awk '/Total number in stack/{f=1} /Binary Images:/{f=0} f' "$out" | tee "$summary"
echo "Wrote $summary"
