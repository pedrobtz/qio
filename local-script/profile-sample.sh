#!/usr/bin/env bash
set -euo pipefail

script="${1:?Usage: ./profile-sample.sh path/to/script.R [output.txt]}"
out="${2:-profile.sample.txt}"
seconds="${SECONDS_TO_SAMPLE:-15}"
interval_ms="${INTERVAL_MS:-1}"
summary="${out%.txt}.summary.txt"

# (Re)build a package from source with debug symbols and frame pointers so
# `sample` can resolve native (C) frames. INSTALL selects which:
#   qio (default) -> R CMD INSTALL .   |   nanoparquet / any CRAN pkg -> source
#   none / SKIP_INSTALL=1 -> skip
# Flags are injected via R_MAKEVARS_USER, which applies to any source build
# (qio has no ./configure, so --configure-vars would be a no-op).
install="${INSTALL:-qio}"
[ -n "${SKIP_INSTALL:-}" ] && install=none

if [ "$install" != "none" ]; then
  mk="$(mktemp -t qio-makevars.XXXXXX)"
  trap 'rm -f "$mk"' EXIT
  cat > "$mk" <<'EOF'
CFLAGS = -g -O2 -fno-omit-frame-pointer
CXXFLAGS = -g -O2 -fno-omit-frame-pointer
EOF
  export R_MAKEVARS_USER="$mk"

  if [ "$install" = "qio" ]; then
    R CMD INSTALL .
  else
    Rscript -e "install.packages('$install', type='source', repos='https://cloud.r-project.org')"
  fi
fi

Rscript "$script" &
pid=$!

sleep 0.5

echo "Sampling PID $pid for ${seconds}s every ${interval_ms}ms"
sample "$pid" "$seconds" "$interval_ms" -file "$out" || true

wait "$pid" || true
echo "Wrote $out"

# Extract the aggregated self-time / total-time tables that `sample` appends
# after the call tree ("Total number in stack" through "Binary Images"), and
# print them to the console while also saving to $summary.
awk '/Total number in stack/{f=1} /Binary Images:/{f=0} f' "$out" \
  | tee "$summary"
echo "Wrote $summary"
