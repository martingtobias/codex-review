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
# cd parsing is limited to the command segments BEFORE the one that runs
# `git commit`. Splitting on shell sequence tokens (`;`, `&&`, `||`, `|`,
# `|&`) rather than raw text means:
#   - post-commit `cd ..` resets in the same command line are ignored
#   - `git commit` appearing inside a quoted argument (e.g.
#     `grep "git commit" docs`) does not terminate the prefix, because
#     such matches are not at the start of a segment
# If `git commit` is the very first segment, the prefix is empty and no
# cd influences the resolution.
# Segment the command on unquoted shell sequence operators (;, &&, ||, |, |&).
# Quote-aware: operators inside single- or double-quoted strings do NOT split,
# so `cd "sub;repo" && git commit` stays correctly segmented.
COMMAND_SEGMENTED=$(printf '%s' "$COMMAND" | awk '
{
  out = ""
  in_single = 0
  in_double = 0
  i = 1
  L = length($0)
  while (i <= L) {
    c = substr($0, i, 1)
    nxt = (i < L) ? substr($0, i, 2) : ""
    if (c == "\47" && !in_double) { in_single = !in_single; out = out c; i++; continue }
    if (c == "\"" && !in_single) { in_double = !in_double; out = out c; i++; continue }
    if (!in_single && !in_double) {
      if (nxt == "||" || nxt == "&&" || nxt == "|&") { out = out "\n"; i += 2; continue }
      if (c == ";" || c == "|")                       { out = out "\n"; i++;   continue }
    }
    out = out c
    i++
  }
  print out
}')

# Match a segment whose effective command is `git ... commit`. Tolerate:
#   - leading env-assignments / wrappers (GIT_AUTHOR_NAME=x git commit,
#     sudo git commit, env FOO=1 git commit)
#   - a leading `(` (subshell grouping, e.g. `(git commit -m x)`)
#   - path-qualified git (e.g. `/usr/bin/git commit`, `./bin/git commit`)
COMMIT_LINE=$(printf '%s\n' "$COMMAND_SEGMENTED" | awk '
  /^[[:space:]]*([^[:space:];&|]+[[:space:]]+)*\(?([^[:space:];&|]*\/)?git([[:space:]]+[^[:space:];&|]+)*[[:space:]]+commit([[:space:]]|$)/ { print NR; exit }
')
if [ -n "$COMMIT_LINE" ] && [ "$COMMIT_LINE" -gt 1 ]; then
  COMMAND_PREFIX=$(printf '%s\n' "$COMMAND_SEGMENTED" | awk -v n="$COMMIT_LINE" 'NR < n')
else
  COMMAND_PREFIX=""
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

# Resolve the history log location via Git so linked worktrees and submodules
# (where $REPO_ROOT/.git is a file, not a directory) work correctly.
GITDIR=$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)
if [ -z "$GITDIR" ]; then
  GITDIR="$REPO_ROOT/.git"
elif [ "${GITDIR#/}" = "$GITDIR" ]; then
  # Relative path -- anchor it to the repo root.
  GITDIR="$REPO_ROOT/$GITDIR"
fi
HISTORY_FILE="$GITDIR/codex-reviews.jsonl"

# Defaults so the EXIT trap (timeout path) has valid values to log with.
START_TS=$(date +%s)
REVIEW_PROSE="(review did not complete)"
FINDINGS_JSON="[]"
REVIEW_EXIT=0

# Append-to-history helper. Defined before the trap so the timeout path
# can call it. Write failures are swallowed so they never break the hook.
append_history() {
  local verdict="$1"
  local prose_log
  if [ ${#REVIEW_PROSE} -gt 2000 ]; then
    prose_log="${REVIEW_PROSE:0:2000}... [truncated]"
  else
    prose_log="$REVIEW_PROSE"
  fi
  local duration=$(( $(date +%s) - START_TS ))
  jq -nc \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg sha "$HEAD_SHA" \
    --arg short "$SHORT_SHA" \
    --arg branch "$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || true)" \
    --arg author_name "$(git -C "$REPO_ROOT" log -1 --format=%an "$HEAD_SHA" 2>/dev/null || true)" \
    --arg author_email "$(git -C "$REPO_ROOT" log -1 --format=%ae "$HEAD_SHA" 2>/dev/null || true)" \
    --arg verdict "$verdict" \
    --argjson findings "$FINDINGS_JSON" \
    --arg prose "$prose_log" \
    --arg codex_exit "$REVIEW_EXIT" \
    --arg duration "$duration" \
    --arg ver "1.2.0" \
    '{timestamp:$ts, sha:$sha, short_sha:$short, branch:$branch,
      author_name:$author_name, author_email:$author_email,
      verdict:$verdict,
      finding_count:($findings|length),
      blocking_count:([$findings[] | select(.priority=="P1" or .priority=="P2")] | length),
      findings:$findings,
      review_prose:$prose,
      codex_exit:($codex_exit|tonumber),
      duration_seconds:($duration|tonumber),
      plugin_version:$ver}' \
    >> "$HISTORY_FILE" 2>/dev/null || true
}

# Mark in-flight so a kill (timeout) is distinguishable from a real FAIL/PASS.
# On abnormal exit, downgrade state to TIMEOUT and log the event so the
# history file faithfully records every outcome advertised in the README.
echo "RUNNING $SHORT_SHA" > "$STATE_FILE"
trap '
  rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$STATE_FILE" ]; then
    s=$(cat "$STATE_FILE" 2>/dev/null || true)
    case "$s" in
      RUNNING*)
        echo "TIMEOUT" > "$STATE_FILE"
        append_history "TIMEOUT" 2>/dev/null || true
        ;;
    esac
  fi
' EXIT

# --- Run Codex review (JSONL event stream via --json) ---
# Observed event schema (Codex CLI ~2026-04):
#   thread.started / turn.started / turn.completed   -- lifecycle
#   item.started / item.completed                    -- wraps each item
# Item subtypes (.item.type):
#   command_execution    -- tool calls the agent ran while investigating
#   todo_list            -- progress tracking
#   agent_message        -- the final review prose; .item.text carries it
# We parse ONLY the agent_message(s), which isolates the final verdict
# from tool-call noise and Codex's own priority-rubric preamble -- the
# class of false positives that the earlier text parser produced.
# Capture stdout (JSONL events) and stderr separately. Mixing them with 2>&1
# lets Codex startup warnings (e.g. a "could not update PATH" line on
# read-only filesystems) contaminate the first line of the stream, which
# defeats the JSONL_MODE probe and silently forces the fallback parser.
STDERR_FILE=$(mktemp 2>/dev/null || echo "/tmp/codex-review-stderr.$$")
REVIEW_JSONL=$(cd "$REPO_ROOT" && "$CODEX_BIN" exec review --json \
  --commit "$HEAD_SHA" \
  --full-auto \
  2>"$STDERR_FILE") || REVIEW_EXIT=$?
REVIEW_STDERR=$(cat "$STDERR_FILE" 2>/dev/null || true)
rm -f "$STDERR_FILE"

# Detect JSONL mode; older Codex CLIs may emit plain text even with --json.
# Extract the first line via bash parameter expansion rather than `| head -1`:
# under `set -o pipefail`, `head` closing stdin early sends SIGPIPE to the
# upstream `printf`, causing the whole pipeline to return non-zero even when
# jq matched. That silently forced every JSONL review to fall back to the
# legacy text parser and surfaced the raw event stream as review prose.
JSONL_MODE=false
FIRST_LINE="${REVIEW_JSONL%%$'\n'*}"
if [ -n "$FIRST_LINE" ] && printf '%s' "$FIRST_LINE" | jq -e 'has("type")' >/dev/null 2>&1; then
  JSONL_MODE=true
fi

REVIEW_PROSE=""
if [ "$JSONL_MODE" = "true" ]; then
  # Codex can emit several agent_message items (streaming partials + final).
  # Take the LAST one -- that's the authoritative final summary. Concatenating
  # them duplicates the review text in the prose surfaced back to Claude.
  #
  # Use per-line `try fromjson catch empty` so a single malformed/trailing
  # line in the stream doesn't abort parsing and mask earlier findings the
  # way `jq -s` (slurp) would. Base64-encode each match so embedded newlines
  # survive the `tail -n 1` that picks the last match.
  LAST_ENCODED=$(printf '%s\n' "$REVIEW_JSONL" \
    | jq -rR 'try (fromjson | select(.type=="item.completed" and .item.type=="agent_message") | .item.text | @base64) catch empty' \
    2>/dev/null \
    | tail -n 1)
  if [ -n "$LAST_ENCODED" ]; then
    REVIEW_PROSE=$(printf '%s' "$LAST_ENCODED" | base64 -d 2>/dev/null || true)
  fi
  if [ -z "$REVIEW_PROSE" ]; then
    REVIEW_PROSE="(Codex produced no agent_message; stderr: ${REVIEW_STDERR:-<empty>})"
  fi
else
  # Legacy text-parser fallback: strip ANSI, take everything from the 'codex'
  # marker onwards. Will be removed in a future release.
  ESC=$(printf '\033')
  ANSI_STRIPPED=$(printf '%s\n' "$REVIEW_JSONL" | sed "s/${ESC}\\[[0-9;]*m//g")
  REVIEW_PROSE=$(printf '%s\n' "$ANSI_STRIPPED" | sed -n '/^codex$/,$p')
  if [ -z "$REVIEW_PROSE" ]; then
    REVIEW_PROSE="$ANSI_STRIPPED"
  fi
fi

# Finding detection on the clean review prose. Line-anchored pattern rejects
# prose mentions and rubric legend entries.
HAS_ISSUES=false
if [ "$REVIEW_EXIT" -eq 0 ]; then
  if printf '%s\n' "$REVIEW_PROSE" \
      | grep -qE '^[[:space:]]*([-*>][[:space:]]+)?\[P[12]\][[:space:]]+[^=[:space:]]'; then
    HAS_ISSUES=true
  fi
fi

# Extract structured findings (priority + verbatim title-line) for the history
# log. Title retains the " — file:line" suffix as emitted by Codex; callers
# can parse further if they want. Missing-match lines are filtered by grep.
FINDINGS_JSON=$(printf '%s\n' "$REVIEW_PROSE" \
  | grep -E '^[[:space:]]*([-*>][[:space:]]+)?\[P[123]\][[:space:]]+' \
  | jq -Rn '[inputs | capture("^[[:space:]]*([-*>][[:space:]]+)?\\[(?<priority>P[123])\\][[:space:]]+(?<title>.*)$")]' \
  2>/dev/null || true)
if ! printf '%s' "$FINDINGS_JSON" | jq -e . >/dev/null 2>&1; then
  FINDINGS_JSON="[]"
fi

# Display text for Claude: the prose itself, tail-preserving truncation when
# we're blocking on findings (Codex puts its list at the end).
REVIEW_SUMMARY="$REVIEW_PROSE"
if [ ${#REVIEW_SUMMARY} -gt "$CODEX_REVIEW_MAX_OUTPUT" ]; then
  if [ "$HAS_ISSUES" = "true" ]; then
    REVIEW_SUMMARY="... [truncated head]"$'\n'"${REVIEW_SUMMARY: -$CODEX_REVIEW_MAX_OUTPUT}"
  else
    REVIEW_SUMMARY="${REVIEW_SUMMARY:0:$CODEX_REVIEW_MAX_OUTPUT}... [truncated]"
  fi
fi

# --- Emit verdict ---
if [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "ERROR" > "$STATE_FILE"
  append_history "ERROR"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg exit_code "$REVIEW_EXIT" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " errored (exit code: " + $exit_code + ").\n\n" + $review + "\n\nReview the output above and decide whether to push or fix issues.")}'
elif [ "$HAS_ISSUES" = "true" ]; then
  echo "FAIL" > "$STATE_FILE"
  append_history "FAIL"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"decision": "block", "reason": ("Codex review of commit " + $sha + " found issues:\n\n" + $review + "\n\nFix the issues identified above, then create a new commit. Do NOT re-run the codex review yourself -- this hook will trigger it automatically on your next commit. Do NOT push to GitHub until the review passes.")}'
else
  rm -f "$STATE_FILE" "$LOOP_COUNTER"
  append_history "PASS"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " passed (no issues found).\n\n" + $review + "\n\nThe code looks good. Ask the user if they want to push to GitHub.")}}'
fi

# Clear the trap; we emitted a verdict cleanly.
trap - EXIT
