#!/usr/bin/env bash
# Post-commit review hook for Claude Code
# After every successful `git commit` made via the Bash tool, run a Codex
# review on HEAD and return a verdict back to Claude.
set -euo pipefail

# --- Config (env overrides) ---
: "${CODEX_REVIEW_MAX_OUTPUT:=8000}"
CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"

# --- Read input ---
INPUT=$(cat)
if ! printf '%s' "$INPUT" | jq -e . >/dev/null 2>&1; then
  echo '{}'; exit 0
fi

# --- Global bypass switch ---
if [ -n "${CODEX_REVIEW_SKIP:-}" ]; then
  echo '{}'; exit 0
fi

# --- Gate 1: this Bash call was a git commit ---
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
if [ -z "$COMMAND" ]; then
  echo '{}'; exit 0
fi

# Broad match: any `git ... commit` token in the command, including env-prefixed
# forms (`GIT_AUTHOR_NAME=x git commit`, `sudo git commit`, `env FOO=1 git commit`).
if ! printf '%s' "$COMMAND" | grep -qE '\bgit\b[^;&|]*\bcommit\b'; then
  echo '{}'; exit 0
fi

# --- Gate 2: commit succeeded ---
TOOL_RESPONSE=$(printf '%s' "$INPUT" | jq -r '
  (.tool_response // empty) as $r
  | if ($r|type) == "string" then $r
    elif ($r|type) == "object" then
      (($r.stdout // "") + "\n" + ($r.stderr // "") + "\n" + ($r.output // ""))
    else "" end
')

HAS_SUCCESS=false
if printf '%s' "$TOOL_RESPONSE" | grep -qE 'files?[[:space:]]+changed'; then
  HAS_SUCCESS=true
elif printf '%s' "$TOOL_RESPONSE" | grep -qE '\[.+[[:space:]]+[0-9a-f]+\]'; then
  HAS_SUCCESS=true
fi

if printf '%s' "$TOOL_RESPONSE" | grep -qE '^(error|fatal):|nothing to commit'; then
  HAS_SUCCESS=false
fi

if [ "$HAS_SUCCESS" = "false" ]; then
  echo '{}'; exit 0
fi

# --- Gate 3: Codex binary available (silent skip; never block) ---
if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
  echo '{}'; exit 0
fi

# --- Resolve repo root via git (no heuristics over command text) ---
SESSION_CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
if [ -z "$SESSION_CWD" ]; then
  SESSION_CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

# Respect explicit `git -C <dir>` in the command (quoted or unquoted)
GIT_C_RAW=$(printf '%s' "$COMMAND" \
  | grep -oE "git[[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
  | tail -1 || true)
GIT_C_DIR=""
if [ -n "$GIT_C_RAW" ]; then
  GIT_C_DIR=$(printf '%s' "$GIT_C_RAW" | sed -E "s/^git[[:space:]]+-C[[:space:]]+//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")
fi

CANDIDATE_DIR="$SESSION_CWD"
if [ -n "$GIT_C_DIR" ]; then
  case "$GIT_C_DIR" in
    /*) CANDIDATE_DIR="$GIT_C_DIR" ;;
    *)  CANDIDATE_DIR="$SESSION_CWD/$GIT_C_DIR" ;;
  esac
fi

REPO_ROOT=""
if [ -d "$CANDIDATE_DIR" ]; then
  REPO_ROOT=$(cd "$CANDIDATE_DIR" && git rev-parse --show-toplevel 2>/dev/null || true)
fi
if [ -z "$REPO_ROOT" ]; then
  echo '{}'; exit 0
fi

HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)
if [ -z "$HEAD_SHA" ]; then
  echo '{}'; exit 0
fi
SHORT_SHA=$(printf '%s' "$HEAD_SHA" | cut -c1-8)

STATE_FILE="$REPO_ROOT/.codex-review-state"
LOOP_COUNTER="$REPO_ROOT/.codex-review-loop-count"

# Mark in-flight so a kill (timeout) is distinguishable from a real FAIL/PASS.
echo "RUNNING $SHORT_SHA" > "$STATE_FILE"
trap '
  rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$STATE_FILE" ]; then
    s=$(cat "$STATE_FILE" 2>/dev/null || true)
    case "$s" in
      RUNNING*) echo "TIMEOUT" > "$STATE_FILE" ;;
    esac
  fi
' EXIT

# --- Run Codex review ---
REVIEW_EXIT=0
REVIEW_OUTPUT=$(cd "$REPO_ROOT" && "$CODEX_BIN" exec review \
  --commit "$HEAD_SHA" \
  --full-auto \
  2>&1) || REVIEW_EXIT=$?

# --- Strip ANSI colour codes, then extract the summary section ---
ESC=$(printf '\033')
ANSI_STRIPPED=$(printf '%s\n' "$REVIEW_OUTPUT" | sed "s/${ESC}\\[[0-9;]*m//g")
REVIEW_SUMMARY=$(printf '%s\n' "$ANSI_STRIPPED" | sed -n '/^codex$/,$p')
if [ -z "$REVIEW_SUMMARY" ]; then
  REVIEW_SUMMARY="$ANSI_STRIPPED"
fi

# Truncate for display only.
if [ ${#REVIEW_SUMMARY} -gt "$CODEX_REVIEW_MAX_OUTPUT" ]; then
  REVIEW_SUMMARY="${REVIEW_SUMMARY:0:$CODEX_REVIEW_MAX_OUTPUT}... [truncated]"
fi

# Finding detection: real findings appear in the summary section as lines that
# START with [P1]/[P2] (optionally after a list marker/quote), followed by
# whitespace and non-'=' content. This rejects in-paragraph mentions and the
# rubric legend (e.g., "[P1] = must-fix"). Only evaluated on exit-0 output.
HAS_ISSUES=false
if [ "$REVIEW_EXIT" -eq 0 ]; then
  if printf '%s\n' "$REVIEW_SUMMARY" \
      | grep -qE '^[[:space:]]*([-*>][[:space:]]+)?\[P[12]\][[:space:]]+[^=[:space:]]'; then
    HAS_ISSUES=true
  fi
fi

# --- Emit verdict ---
if [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "ERROR" > "$STATE_FILE"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg exit_code "$REVIEW_EXIT" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " errored (exit code: " + $exit_code + ").\n\n" + $review + "\n\nReview the output above and decide whether to push or fix issues.")}'
elif [ "$HAS_ISSUES" = "true" ]; then
  echo "FAIL" > "$STATE_FILE"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " found issues:\n\n" + $review + "\n\nFix the issues identified above, then create a new commit. Do NOT re-run the codex review yourself -- this hook will trigger it automatically on your next commit. Do NOT push to GitHub until the review passes.")}'
else
  rm -f "$STATE_FILE" "$LOOP_COUNTER"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " passed (no issues found).\n\n" + $review + "\n\nThe code looks good. Ask the user if they want to push to GitHub.")}}'
fi

# Clear the trap; we emitted a verdict cleanly.
trap - EXIT
