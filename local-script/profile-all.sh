#!/usr/bin/env bash
set -euo pipefail

# Profile qio and nanoparquet back-to-back with the same sampling harness.
# Env vars (SECONDS_TO_SAMPLE, INTERVAL_MS, SKIP_INSTALL) pass through to
# profile-sample.sh. Run from the repo root so relative paths (., local-data/)
# resolve regardless of where this is invoked from.
cd "$(dirname "$0")/.."
d="local-script"

echo "==> Profiling qio ..."
INSTALL=qio "$d/profile-sample.sh" "$d/qio-test.R" "$d/qio.sample.txt"

echo
echo "==> Profiling nanoparquet ..."
INSTALL=nanoparquet "$d/profile-sample.sh" "$d/nano-test.R" "$d/nano.sample.txt"

echo
echo "Done."
echo "  full traces: $d/{qio,nano}.sample.txt"
echo "  summaries:   $d/{qio,nano}.sample.summary.txt"
