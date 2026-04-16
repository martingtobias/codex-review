#!/usr/bin/env bash
# Stop hook for codex-review plugin
# Keeps Claude iterating on fixes until a pending FAIL review clears, with
# a safety-valve cap on iterations.
set -euo pipefail

: "${CODEX_REVIEW_MAX_LOOPS:=5}"

INPUT=$(cat)
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo '{}'; exit 0
fi

if [ -n "${CODEX_REVIEW_SKIP:-}" ]; then
  echo '{}'; exit 0
fi

# Resolve state-file location the same way post-commit-review.sh did: session
# CWD -> git repo root. Any failure -> pass through.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

REPO_ROOT=""
if [ -d "$CWD" ]; then
  REPO_ROOT=$(cd "$CWD" && git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$REPO_ROOT" ]; then
  REPO_ROOT="$CWD"
fi

STATE_FILE="$REPO_ROOT/.codex-review-state"
LOOP_COUNTER="$REPO_ROOT/.codex-review-loop-count"

if [ ! -f "$STATE_FILE" ]; then
  rm -f "$LOOP_COUNTER"
  echo '{}'; exit 0
fi

# Read first token only (handles "RUNNING <sha>" or trailing whitespace).
VERDICT=$(head -c 128 "$STATE_FILE" 2>/dev/null | awk '{print $1; exit}' || true)

case "$VERDICT" in
  FAIL)
    COUNT=0
    if [ -f "$LOOP_COUNTER" ]; then
      raw=$(cat "$LOOP_COUNTER" 2>/dev/null || echo 0)
      case "$raw" in
        ''|*[!0-9]*) COUNT=0 ;;
        *)           COUNT=$raw ;;
      esac
    fi
    COUNT=$((COUNT + 1))
    echo "$COUNT" > "$LOOP_COUNTER"

    if [ "$COUNT" -ge "$CODEX_REVIEW_MAX_LOOPS" ]; then
      rm -f "$STATE_FILE" "$LOOP_COUNTER"
      jq -n --arg max "$CODEX_REVIEW_MAX_LOOPS" \
        '{"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": ("Codex review fix-loop reached the max of " + $max + " iterations without passing. Stopping. Resolve the remaining issues manually and use /codex-review to re-check.")}}'
      exit 0
    fi

    jq -n '{"decision": "block", "reason": "Codex review found issues that need fixing. Fix the issues identified in the review and create a new commit. Do NOT re-run the codex review yourself -- the post-commit hook will trigger it automatically when you commit. Do NOT stop until the review passes."}'
    ;;
  RUNNING)
    # Review is mid-flight; nothing to block on yet.
    echo '{}'
    ;;
  ERROR|TIMEOUT)
    rm -f "$STATE_FILE" "$LOOP_COUNTER"
    echo '{}'
    ;;
  *)
    # Unknown verdict — do NOT silently clear (that would hide a corruption bug).
    # Let Claude stop; leave the state file in place for the user to inspect.
    echo '{}'
    ;;
esac
