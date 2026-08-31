#!/usr/bin/env bash
# Assert shell-script invariants that `bash -n` cannot see.
#
# Everything checked here is SYNTACTICALLY VALID bash. That is the whole point:
# `bash -n` passes, CI passes, and the script silently does the wrong thing at
# deploy time. Each check below exists because the failure actually happened.
#
# Usage: scripts/assert-shell.sh [file...]        (default: the repo's own shells)
# Exit:  0 all checks pass, 1 otherwise (prints every finding, not just the first)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Default target list: the shared scripts plus every env's install.sh. Env dirs are
# gitignored, so CI only ever sees template/ — but an operator running this from
# their own env dir gets their own copy checked, which is where the bug that
# motivated check 1 actually lived.
if [ "$#" -gt 0 ]; then
  FILES=("$@")
else
  mapfile -t FILES < <(
    find "$REPO_ROOT/scripts" -maxdepth 1 -name '*.sh' -type f
    find "$REPO_ROOT/opentofu/aws" -maxdepth 2 -name 'install.sh' -type f
  )
fi

FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=1; }

# ── Check 1: a comment line immediately after a line-continuation ─────────────
#
# A `#` line following a `\` continuation swallows its own trailing backslash, so
# the continuation ENDS at that comment. Every remaining flag is dropped from the
# command, and bash tries to execute the following line as a new command.
#
# Observed: a commented-out `--set` parked inside `helm upgrade` in
# Test-dev-cluster/install.sh detached `--wait --timeout 10m`. helm ran without
# --wait, then `--wait: command not found` (exit 127) aborted deploy_aggregator
# under `set -e`, skipping restart_aggregator_config_consumers — so a fetched
# aggregator.config.yaml / consent change never reached the pods.
#
# Only flagged when the PRECEDING line is not itself a comment: a fully-commented
# block (every line starting with `#`) is inert and legitimate, which is how the
# resolve-network-brand notes in deploy_aggregator are written.
echo "Asserting shell invariants (${#FILES[@]} file(s))"
found_cont=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  while IFS= read -r finding; do
    fail "comment breaks a line-continuation: ${finding}"
    found_cont=1
  done < <(
    awk -v rel="${f#"$REPO_ROOT"/}" '
      prev ~ /\\[[:space:]]*$/ && prev !~ /^[[:space:]]*#/ && $0 ~ /^[[:space:]]*#/ {
        gsub(/^[[:space:]]+/, "", $0)
        print rel ":" NR ": " $0
      }
      { prev = $0 }
    ' "$f"
  )
done
[ "$found_cont" -eq 0 ] && pass "no comment interrupts a line-continuation"

# ── Check 2: every targeted file still parses ────────────────────────────────
# Cheap, and it keeps this script a single entry point for "are the shells sane".
found_syntax=0
for f in "${FILES[@]}"; do
  [ -f "$f" ] || continue
  if ! bash -n "$f" 2>/dev/null; then
    fail "bash -n failed: ${f#"$REPO_ROOT"/}"
    found_syntax=1
  fi
done
[ "$found_syntax" -eq 0 ] && pass "all files parse (bash -n)"

echo
if [ "$FAILED" -eq 0 ]; then
  echo "shell assertions: ALL PASSED"
else
  echo "shell assertions: FAILED" >&2
fi
exit "$FAILED"
