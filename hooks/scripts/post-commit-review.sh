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

# Honor `cd <dir>` and `git -C <dir>` in the command (quoted or unquoted).
# `git -C` wins if both are present. Each candidate is validated by asking
# git whether it points into a repo, so spurious path tokens can't poison
# the resolution.
#
# cd parsing is limited to the command prefix BEFORE the first `git commit`
# token so trailing `&& cd ..` style resets don't flip us into the wrong
# directory after the commit has already landed.
COMMIT_OFFSET=$(printf '%s' "$COMMAND" | grep -boE '\bgit\b[^;&|]*\bcommit\b' | head -1 | cut -d: -f1 || true)
if [ -n "$COMMIT_OFFSET" ] && [ "$COMMIT_OFFSET" -gt 0 ]; then
  COMMAND_PREFIX="${COMMAND:0:$COMMIT_OFFSET}"
else
  COMMAND_PREFIX="$COMMAND"
fi

CD_RAW=$(printf '%s' "$COMMAND_PREFIX" \
  | grep -oE "\\bcd[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
  | tail -1 || true)
CD_DIR=""
if [ -n "$CD_RAW" ]; then
  CD_DIR=$(printf '%s' "$CD_RAW" | sed -E "s/^cd[[:space:]]+//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")
fi

GIT_C_RAW=$(printf '%s' "$COMMAND" \
  | grep -oE "git[[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
  | tail -1 || true)
GIT_C_DIR=""
if [ -n "$GIT_C_RAW" ]; then
  GIT_C_DIR=$(printf '%s' "$GIT_C_RAW" | sed -E "s/^git[[:space:]]+-C[[:space:]]+//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")
fi

CANDIDATE_DIR="$SESSION_CWD"
if [ -n "$CD_DIR" ]; then
  case "$CD_DIR" in
    /*) CANDIDATE_DIR="$CD_DIR" ;;
    *)  CANDIDATE_DIR="$SESSION_CWD/$CD_DIR" ;;
  esac
fi
if [ -n "$GIT_C_DIR" ]; then
  case "$GIT_C_DIR" in
    /*) CANDIDATE_DIR="$GIT_C_DIR" ;;
    *)  CANDIDATE_DIR="$CANDIDATE_DIR/$GIT_C_DIR" ;;
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

# Finding detection: real findings appear in the summary section as lines that
# START with [P1]/[P2] (optionally after a list marker/quote), followed by
# whitespace and non-'=' content. This rejects in-paragraph mentions and the
# rubric legend (e.g., "[P1] = must-fix"). Only evaluated on exit-0 output.
# Run detection on the FULL summary before any truncation, so late findings
# aren't silently dropped.
HAS_ISSUES=false
if [ "$REVIEW_EXIT" -eq 0 ]; then
  if printf '%s\n' "$REVIEW_SUMMARY" \
      | grep -qE '^[[:space:]]*([-*>][[:space:]]+)?\[P[12]\][[:space:]]+[^=[:space:]]'; then
    HAS_ISSUES=true
  fi
fi

# Truncate for display only (AFTER detection). Keep the TAIL of the summary
# rather than the head -- Codex puts its findings list at the end, so head-
# truncation can hide the very issues that caused HAS_ISSUES=true.
if [ ${#REVIEW_SUMMARY} -gt "$CODEX_REVIEW_MAX_OUTPUT" ]; then
  REVIEW_SUMMARY="... [truncated head]"$'\n'"${REVIEW_SUMMARY: -$CODEX_REVIEW_MAX_OUTPUT}"
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
