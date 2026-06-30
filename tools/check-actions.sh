#!/usr/bin/env bash
#
# check-actions.sh — report the status of the latest GitHub Actions runs.
#
# For the repository in the current directory, this prints the most recent run
# of each workflow. For any run that did NOT succeed, it downloads the full
# logs, the failed-step logs, and any artifacts into the .logs/ directory.
#
# Requires: gh (https://cli.github.com), authenticated via `gh auth login`.
#
# Usage:
#   tools/check-actions.sh [-b BRANCH] [-L LIMIT] [-d DIR] [WORKFLOW_FILTER]
#
#   -b BRANCH   Only consider runs from this branch (default: all branches).
#   -L LIMIT    Number of recent runs to scan when finding the latest per
#               workflow (default: 100).
#   -d DIR      Directory to download logs/artifacts into (default: .logs).
#   WORKFLOW_FILTER
#               Optional case-insensitive substring; only workflows whose name
#               matches are reported.
#
# Exit status: 0 if every reported run succeeded, 1 if any run failed.

set -euo pipefail

BRANCH=""
LIMIT=100
LOGS_DIR=".logs"
FILTER=""

usage() {
  sed -n '3,30p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while getopts ":b:L:d:h" opt; do
  case "$opt" in
    b) BRANCH="$OPTARG" ;;
    L) LIMIT="$OPTARG" ;;
    d) LOGS_DIR="$OPTARG" ;;
    h) usage 0 ;;
    \?) echo "error: unknown option -$OPTARG" >&2; usage 2 ;;
    :)  echo "error: option -$OPTARG requires an argument" >&2; usage 2 ;;
  esac
done
shift $((OPTIND - 1))
FILTER="${1:-}"

# --- preconditions ----------------------------------------------------------
command -v gh >/dev/null 2>&1 || {
  echo "error: the GitHub CLI 'gh' is required (https://cli.github.com)." >&2
  exit 1
}
gh auth status >/dev/null 2>&1 || {
  echo "error: gh is not authenticated. Run 'gh auth login'." >&2
  exit 1
}

# --- gather latest run per workflow -----------------------------------------
# Pull the recent runs, group by workflow, and keep the newest of each.
list_args=(--limit "$LIMIT")
[ -n "$BRANCH" ] && list_args+=(--branch "$BRANCH")

if ! runs="$(
  gh run list "${list_args[@]}" \
    --json databaseId,workflowName,status,conclusion,headBranch,displayTitle,createdAt,url \
    --jq 'group_by(.workflowName)[]
          | max_by(.createdAt)
          | [.databaseId, .workflowName, .status, .conclusion,
             .headBranch, .displayTitle, .url]
          | @tsv' 2>/tmp/check-actions.err
)"; then
  echo "error: could not list workflow runs:" >&2
  sed 's/^/  /' /tmp/check-actions.err >&2
  rm -f /tmp/check-actions.err
  echo "  (is this repo pushed to GitHub and are Actions enabled?)" >&2
  exit 1
fi
rm -f /tmp/check-actions.err

if [ -z "$runs" ]; then
  echo "No workflow runs found${BRANCH:+ for branch '$BRANCH'}."
  exit 0
fi

# --- report + download on failure -------------------------------------------
sanitize() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }

failures=0
printf '%s\n' "Latest workflow runs${BRANCH:+ (branch: $BRANCH)}:"
echo

while IFS=$'\t' read -r id name status conclusion branch title url; do
  [ -n "$id" ] || continue
  if [ -n "$FILTER" ]; then
    case "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" in
      *"$(printf '%s' "$FILTER" | tr 'A-Z' 'a-z')"*) ;;
      *) continue ;;
    esac
  fi

  # Determine an outcome label and marker.
  if [ "$status" != "completed" ]; then
    marker="•"; outcome="$status"
  else
    case "$conclusion" in
      success)               marker="✔"; outcome="success" ;;
      failure|startup_failure) marker="✗"; outcome="$conclusion" ;;
      cancelled|timed_out|action_required) marker="✖"; outcome="$conclusion" ;;
      skipped|neutral)       marker="—"; outcome="$conclusion" ;;
      *)                     marker="?"; outcome="${conclusion:-unknown}" ;;
    esac
  fi

  printf '  %s  %-22s %-12s %s\n' "$marker" "$name" "$outcome" "$branch"
  printf '       %s\n' "$title"
  printf '       %s\n' "$url"

  # Download logs + artifacts for anything that completed unsuccessfully.
  if [ "$status" = "completed" ] && [ "$conclusion" != "success" ] \
       && [ "$conclusion" != "skipped" ] && [ "$conclusion" != "neutral" ]; then
    failures=$((failures + 1))
    dest="$LOGS_DIR/$(sanitize "$name")-$id"
    mkdir -p "$dest"
    echo "       ↓ downloading logs/artifacts into $dest"

    if gh run view "$id" --log >"$dest/run.log" 2>"$dest/run.log.err"; then
      rm -f "$dest/run.log.err"
    else
      echo "       ! could not fetch full log (see $dest/run.log.err)"
    fi

    gh run view "$id" --log-failed >"$dest/failed.log" 2>/dev/null || true
    [ -s "$dest/failed.log" ] || rm -f "$dest/failed.log"

    mkdir -p "$dest/artifacts"
    if gh run download "$id" --dir "$dest/artifacts" >/dev/null 2>&1; then
      :
    else
      # No artifacts is a normal, non-fatal case.
      rmdir "$dest/artifacts" 2>/dev/null || true
    fi
  fi
  echo
done <<< "$runs"

if [ "$failures" -gt 0 ]; then
  echo "$failures failing run(s). Logs and artifacts are in '$LOGS_DIR/'."
  exit 1
fi

echo "All reported runs succeeded."
exit 0
