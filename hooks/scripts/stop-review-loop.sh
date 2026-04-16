#!/usr/bin/env bash
# Stop hook for codex-review plugin
# Prevents Claude from stopping if there's a pending review failure.
# Claude must fix the issues and re-commit until codex approves.
set -euo pipefail

MAX_LOOPS=5

# Read hook input from stdin
INPUT=$(cat)

# Derive state file paths from CWD
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
  echo '{}'
  exit 0
fi

STATE_FILE="$CWD/.codex-review-state"
LOOP_COUNTER="$CWD/.codex-review-loop-count"

# No pending review - let Claude stop normally
if [ ! -f "$STATE_FILE" ]; then
  rm -f "$LOOP_COUNTER"
  echo '{}'
  exit 0
fi

VERDICT=$(cat "$STATE_FILE" 2>/dev/null || echo "")

if [ "$VERDICT" = "FAIL" ]; then
  # Track loop iterations to prevent infinite loops
  COUNT=0
  if [ -f "$LOOP_COUNTER" ]; then
    COUNT=$(cat "$LOOP_COUNTER" 2>/dev/null || echo "0")
  fi
  COUNT=$((COUNT + 1))
  echo "$COUNT" > "$LOOP_COUNTER"

  if [ "$COUNT" -ge "$MAX_LOOPS" ]; then
    # Safety valve: allow stop after MAX_LOOPS failed attempts
    rm -f "$STATE_FILE" "$LOOP_COUNTER"
    echo '{}'
    exit 0
  fi

  jq -n '{"decision": "block", "reason": "Codex review found issues that need fixing. Fix the issues identified in the review and create a new commit. Do NOT re-run the codex review yourself -- the post-commit hook will trigger it automatically when you commit. Do NOT stop until the review passes."}'
elif [ "$VERDICT" = "ERROR" ]; then
  # Errors are ambiguous - let the user decide, don't force a loop
  rm -f "$STATE_FILE" "$LOOP_COUNTER"
  echo '{}'
else
  # Unknown state - clean up and let Claude stop
  rm -f "$STATE_FILE" "$LOOP_COUNTER"
  echo '{}'
fi
