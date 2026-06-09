#!/usr/bin/env bash
# Stop hook for codex-review plugin
# Keeps Claude iterating on fixes until a pending FAIL review clears, with
# a safety-valve cap on iterations and staleness checks so leftover state
# from a killed review or an abandoned session never blocks unrelated work.
set -euo pipefail

: "${CODEX_REVIEW_MAX_LOOPS:=5}"
case "$CODEX_REVIEW_MAX_LOOPS" in
  ''|*[!0-9]*) CODEX_REVIEW_MAX_LOOPS=5 ;;
esac

# A FAIL older than this (seconds) is treated as abandoned and cleared.
FAIL_MAX_AGE=3600
# A RUNNING marker older than this is a fossil from a review the harness
# killed at the hook timeout (the post-commit script never got to downgrade
# it) and is cleared.
RUNNING_MAX_AGE=600

INPUT=$(cat)
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo '{}'; exit 0
fi

if [ -n "${CODEX_REVIEW_SKIP:-}" ]; then
  echo '{}'; exit 0
fi

# Resolve state-file location the same way post-commit-review.sh does:
# session CWD -> repo root -> git common dir. Not in a repo -> nothing to do.
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

REPO_ROOT=""
if [ -d "$CWD" ]; then
  REPO_ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
fi
if [ -z "$REPO_ROOT" ]; then
  echo '{}'; exit 0
fi

GITDIR=$(cd "$REPO_ROOT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || GITDIR=""
if [ -z "$GITDIR" ]; then
  GITDIR="$REPO_ROOT/.git"
elif [ "${GITDIR#/}" = "$GITDIR" ]; then
  GITDIR="$REPO_ROOT/$GITDIR"
fi

# One-time migration: pre-1.4.0 releases kept state in the working tree.
rm -f "$REPO_ROOT/.codex-review-state" "$REPO_ROOT/.codex-review-loop-count" 2>/dev/null || true

# File-based kill switch (works mid-session, unlike the env var).
if [ -e "$GITDIR/codex-review-skip" ]; then
  echo '{}'; exit 0
fi

STATE_FILE="$GITDIR/codex-review-state"
LOOP_COUNTER="$GITDIR/codex-review-loop-count"

if [ ! -f "$STATE_FILE" ]; then
  rm -f "$LOOP_COUNTER"
  echo '{}'; exit 0
fi

# State format: "<VERDICT> <full-sha> <epoch>". Pre-1.4.0 wrote fewer fields;
# missing sha/epoch reads as stale below, which is the safe interpretation.
STATE=$(head -c 256 "$STATE_FILE" 2>/dev/null || true)
read -r VERDICT STATE_SHA STATE_TS _ <<<"$STATE " || true
case "${STATE_TS:-}" in
  ''|*[!0-9]*) STATE_TS=0 ;;
esac

NOW=$(date +%s)
HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)

case "${VERDICT:-}" in
  FAIL)
    # Stale FAIL: old state format, the offending commit is gone/superseded,
    # or the review happened too long ago (abandoned session). Clear it so
    # leftover state can't hijack an unrelated future turn.
    if [ -z "${STATE_SHA:-}" ] || [ "$STATE_TS" -eq 0 ] \
       || [ "$HEAD_SHA" != "$STATE_SHA" ] \
       || [ $((NOW - STATE_TS)) -gt "$FAIL_MAX_AGE" ]; then
      rm -f "$STATE_FILE" "$LOOP_COUNTER"
      echo '{}'; exit 0
    fi

    # Corruption guard: if we already forced a continuation (stop_hook_active)
    # but the loop counter has vanished, don't restart the count from zero --
    # clear state and let Claude stop.
    STOP_ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
    if [ "$STOP_ACTIVE" = "true" ] && [ ! -f "$LOOP_COUNTER" ]; then
      rm -f "$STATE_FILE"
      echo '{}'; exit 0
    fi

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
    # Review mid-flight: nothing to block on. But a RUNNING marker that has
    # outlived the hook timeout is a fossil from a killed review -- clear it.
    if [ "$STATE_TS" -eq 0 ] || [ $((NOW - STATE_TS)) -gt "$RUNNING_MAX_AGE" ]; then
      rm -f "$STATE_FILE" "$LOOP_COUNTER"
    fi
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
