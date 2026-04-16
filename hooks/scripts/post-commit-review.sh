#!/usr/bin/env bash
# Post-commit review hook for Claude Code
# Detects git commits, runs Codex review, returns verdict to Claude
set -euo pipefail

CODEX_BIN="$(command -v codex || true)"
MAX_OUTPUT=8000

# Read hook input from stdin
INPUT=$(cat)

# --- Gate 1: Command contains git commit ---
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  echo '{}'
  exit 0
fi

if ! echo "$COMMAND" | grep -qP '(^|&&\s*|;\s*)git\s+(-\S+\s+\S+\s+)*commit(\s|$)'; then
  echo '{}'
  exit 0
fi

# --- Gate 2: Commit succeeded ---
TOOL_RESPONSE=$(echo "$INPUT" | jq -r 'if .tool_response | type == "string" then .tool_response elif .tool_response | type == "object" then (.tool_response | tostring) else empty end // empty')

HAS_SUCCESS=false
if echo "$TOOL_RESPONSE" | grep -qP 'files?\s+changed'; then
  HAS_SUCCESS=true
elif echo "$TOOL_RESPONSE" | grep -qP '\[.+\s+[0-9a-f]+\]'; then
  HAS_SUCCESS=true
fi

if echo "$TOOL_RESPONSE" | grep -qP '(error:|fatal:|nothing to commit)'; then
  HAS_SUCCESS=false
fi

if [ "$HAS_SUCCESS" = "false" ]; then
  echo '{}'
  exit 0
fi

# --- Gate 3: Codex binary exists ---
if [ ! -x "$CODEX_BIN" ]; then
  jq -n --arg msg "Codex review skipped: codex binary not found at $CODEX_BIN" \
    '{"decision": "block", "reason": $msg}'
  exit 0
fi

# --- Get commit SHA and working directory ---
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')
if [ -z "$CWD" ]; then
  CWD="."
fi

# Approach 1: Extract directory from "cd <dir>" in the command
CD_DIR=$(echo "$COMMAND" | grep -oP '\bcd\s+\K\S+' | tail -1 || true)
if [ -n "$CD_DIR" ]; then
  if [[ "$CD_DIR" = /* ]]; then
    CWD="$CD_DIR"
  else
    CWD="$CWD/$CD_DIR"
  fi
fi

# Approach 2: Extract directory from "git -C <dir>" in the command
GIT_C_DIR=$(echo "$COMMAND" | grep -oP '\bgit\s+-C\s+\K\S+' | tail -1 || true)
if [ -n "$GIT_C_DIR" ]; then
  if [[ "$GIT_C_DIR" = /* ]]; then
    CWD="$GIT_C_DIR"
  else
    CWD="$CWD/$GIT_C_DIR"
  fi
fi

# Try to find HEAD
HEAD_SHA=""
if [ -d "$CWD" ]; then
  HEAD_SHA=$(cd "$CWD" && git rev-parse HEAD 2>/dev/null || echo "")
fi

# Approach 3: Try directory-like paths mentioned in the command
if [ -z "$HEAD_SHA" ]; then
  for DIR in $(echo "$COMMAND" | grep -oP '(?:^|\s)/[^\s;&|]+' || true); do
    if [ -d "$DIR" ]; then
      HEAD_SHA=$(cd "$DIR" && git rev-parse HEAD 2>/dev/null || echo "")
      if [ -n "$HEAD_SHA" ]; then
        CWD="$DIR"
        break
      fi
    fi
  done
fi

if [ -z "$HEAD_SHA" ]; then
  echo '{}'
  exit 0
fi

# State files live in the project directory
STATE_FILE="$CWD/.codex-review-state"
LOOP_COUNTER="$CWD/.codex-review-loop-count"

SHORT_SHA=$(echo "$HEAD_SHA" | cut -c1-8)

# --- Run Codex review ---
REVIEW_OUTPUT=""
REVIEW_EXIT=0

REVIEW_OUTPUT=$(cd "$CWD" && "$CODEX_BIN" exec review \
  --commit "$HEAD_SHA" \
  --full-auto \
  2>&1) || REVIEW_EXIT=$?

# --- Parse verdict on FULL output before truncation ---
HAS_ISSUES=false
if echo "$REVIEW_OUTPUT" | grep -qP '\[P[12]\]'; then
  HAS_ISSUES=true
fi

# Extract just the review summary (from "codex" line to end) for cleaner output
REVIEW_SUMMARY=$(echo "$REVIEW_OUTPUT" | sed -n '/^codex$/,$p')
if [ -z "$REVIEW_SUMMARY" ]; then
  REVIEW_SUMMARY="$REVIEW_OUTPUT"
fi

# Truncate for display
if [ ${#REVIEW_SUMMARY} -gt $MAX_OUTPUT ]; then
  REVIEW_SUMMARY="${REVIEW_SUMMARY:0:$MAX_OUTPUT}... [truncated]"
fi

if [ "$REVIEW_EXIT" -ne 0 ]; then
  # Codex itself errored
  echo "ERROR" > "$STATE_FILE"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg exit_code "$REVIEW_EXIT" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " errored (exit code: " + $exit_code + ").\n\n" + $review + "\n\nReview the output above and decide whether to push or fix issues.")}'
elif [ "$HAS_ISSUES" = "true" ]; then
  # Issues found - write state so stop hook keeps Claude going
  echo "FAIL" > "$STATE_FILE"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " found issues:\n\n" + $review + "\n\nFix the issues identified above, then create a new commit. Do NOT re-run the codex review yourself -- this hook will trigger it automatically on your next commit. Do NOT push to GitHub until the review passes.")}'
else
  # Clean review - clear state and loop counter
  rm -f "$STATE_FILE" "$LOOP_COUNTER"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " passed (no issues found).\n\n" + $review + "\n\nThe code looks good. Ask the user if they want to push to GitHub.")}}'
fi
