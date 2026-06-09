#!/usr/bin/env bash
# Post-commit review hook for Claude Code
# After every successful `git commit` made via the Bash tool, run a Codex
# review on HEAD and return a verdict back to Claude.
set -euo pipefail

# --- Config (env overrides; numeric knobs fall back to defaults on garbage
# so a bad value can't trip set -e mid-script) ---
: "${CODEX_REVIEW_MAX_OUTPUT:=8000}"
case "$CODEX_REVIEW_MAX_OUTPUT" in
  ''|*[!0-9]*) CODEX_REVIEW_MAX_OUTPUT=8000 ;;
esac
# In-script review timeout, kept under the 300s harness hook timeout so the
# script itself observes the kill and can record a TIMEOUT verdict (a harness
# kill is a fatal signal: bash never runs the EXIT trap, state stays RUNNING).
: "${CODEX_REVIEW_TIMEOUT:=280}"
case "$CODEX_REVIEW_TIMEOUT" in
  ''|*[!0-9]*) CODEX_REVIEW_TIMEOUT=280 ;;
esac
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
# POSIX-class boundaries instead of \b, which BSD grep (macOS) doesn't support.
if ! printf '%s' "$COMMAND" \
    | grep -qE '(^|[^[:alnum:]_])git([[:space:]][^;&|]*)?[[:space:]]commit([^[:alnum:]_]|$)'; then
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

# Fast negative gate only: an obviously failed commit never needs repo
# resolution. Whether the commit actually SUCCEEDED is decided later from
# git itself (HEAD freshness + history dedup), not by sniffing stdout prose
# -- the old positive sniff ("N files changed") missed quiet commits
# (git commit -q) and non-English locales, and false-positived on commands
# like `git log --grep commit --stat`.
if printf '%s' "$TOOL_RESPONSE" | grep -qE '^(error|fatal):|nothing to commit'; then
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
COMMIT_SEGMENT=""
if [ -n "$COMMIT_LINE" ]; then
  COMMIT_SEGMENT=$(printf '%s\n' "$COMMAND_SEGMENTED" | awk -v n="$COMMIT_LINE" 'NR == n')
fi
if [ -n "$COMMIT_LINE" ] && [ "$COMMIT_LINE" -gt 1 ]; then
  COMMAND_PREFIX=$(printf '%s\n' "$COMMAND_SEGMENTED" | awk -v n="$COMMIT_LINE" 'NR < n')
else
  COMMAND_PREFIX=""
fi

# Apply every `cd` in the prefix cumulatively (absolute paths reset, relative
# ones append) so chains like `cd a && cd b && git commit` resolve to a/b.
# The match is anchored to the segment start, so `echo cd /x` is not a cd.
CANDIDATE_DIR="$SESSION_CWD"
while IFS= read -r SEG; do
  [ -n "$SEG" ] || continue
  CD_RAW=$(printf '%s' "$SEG" \
    | grep -oE "^[[:space:]]*cd[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
    || true)
  [ -n "$CD_RAW" ] || continue
  CD_DIR=$(printf '%s' "$CD_RAW" | sed -E "s/^[[:space:]]*cd[[:space:]]+//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")
  # shellcheck disable=SC2088  # matching a literal ~ in the cd argument
  case "$CD_DIR" in
    /*)        CANDIDATE_DIR="$CD_DIR" ;;
    '~')       CANDIDATE_DIR="$HOME" ;;
    '~/'*)     CANDIDATE_DIR="$HOME/${CD_DIR#\~/}" ;;
    *)         CANDIDATE_DIR="$CANDIDATE_DIR/$CD_DIR" ;;
  esac
done <<<"$COMMAND_PREFIX"

# `git -C` is extracted from the commit segment only -- a `-C` on some other
# command in the same line (`git -C /other log; git commit`) must not
# redirect the review to the wrong repo.
GIT_C_RAW=$(printf '%s' "${COMMIT_SEGMENT:-$COMMAND}" \
  | grep -oE "git[[:space:]]+-C[[:space:]]+(\"[^\"]+\"|'[^']+'|[^[:space:];&|]+)" \
  | tail -1 || true)
GIT_C_DIR=""
if [ -n "$GIT_C_RAW" ]; then
  GIT_C_DIR=$(printf '%s' "$GIT_C_RAW" | sed -E "s/^git[[:space:]]+-C[[:space:]]+//; s/^\"(.*)\"$/\\1/; s/^'(.*)'$/\\1/")
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

# Resolve the state/history location via Git so linked worktrees and
# submodules (where $REPO_ROOT/.git is a file, not a directory) work
# correctly. State lives inside the git dir -- never in the working tree --
# so the fix loop can't stage it with `git add -A` and no per-project
# .gitignore edit is needed.
GITDIR=$(cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null || true)
if [ -z "$GITDIR" ]; then
  GITDIR="$REPO_ROOT/.git"
elif [ "${GITDIR#/}" = "$GITDIR" ]; then
  # Relative path -- anchor it to the repo root.
  GITDIR="$REPO_ROOT/$GITDIR"
fi

STATE_FILE="$GITDIR/codex-review-state"
LOOP_COUNTER="$GITDIR/codex-review-loop-count"
HISTORY_FILE="$GITDIR/codex-reviews.jsonl"

# File-based kill switch (works mid-session, unlike the env var, which hooks
# only inherit from Claude Code's launch environment).
if [ -e "$GITDIR/codex-review-skip" ]; then
  echo '{}'; exit 0
fi

# One-time migration: pre-1.4.0 releases kept state markers in the working
# tree, where the fix loop could accidentally commit them.
rm -f "$REPO_ROOT/.codex-review-state" "$REPO_ROOT/.codex-review-loop-count" 2>/dev/null || true

# Positive gate: HEAD must have been committed just now. A just-made commit
# (including --amend, which refreshes the committer date) always has a
# committer timestamp within seconds of the hook firing; `git log`-ish
# commands that slipped past the command regex never do.
COMMIT_TS=$(git -C "$REPO_ROOT" log -1 --format=%ct HEAD 2>/dev/null || echo 0)
case "$COMMIT_TS" in
  ''|*[!0-9]*) COMMIT_TS=0 ;;
esac
NOW=$(date +%s)
if [ "$COMMIT_TS" -eq 0 ] \
   || [ $((NOW - COMMIT_TS)) -gt 15 ] || [ $((COMMIT_TS - NOW)) -gt 15 ]; then
  echo '{}'; exit 0
fi

# Dedup: skip a sha that already has a history entry. Catches a failed
# `git commit` seconds after a successful one (HEAD still fresh) and avoids
# re-paying for a re-review of an identical commit.
if [ -f "$HISTORY_FILE" ] && grep -qF "\"sha\":\"$HEAD_SHA\"" "$HISTORY_FILE" 2>/dev/null; then
  echo '{}'; exit 0
fi

# Plugin version for history entries, read from the manifest so it can't
# drift from plugin.json again.
PLUGIN_MANIFEST="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}/.claude-plugin/plugin.json"
PLUGIN_VERSION=$(jq -r '.version // "unknown"' "$PLUGIN_MANIFEST" 2>/dev/null || echo "unknown")

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
    --arg ver "$PLUGIN_VERSION" \
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

# Mark in-flight so a kill is distinguishable from a real FAIL/PASS.
# State format: "<VERDICT> <full-sha> <epoch>" -- the Stop hook uses the sha
# and timestamp to detect and clear stale state.
#
# The EXIT trap is a backstop for script failures (set -e) only: it records
# ERROR so a bug here is never mislabeled as a review timeout. It does NOT
# fire on a harness kill -- bash skips EXIT traps on fatal signals -- which
# is why the review itself runs under `timeout` below.
echo "RUNNING $HEAD_SHA $START_TS" > "$STATE_FILE"
# shellcheck disable=SC2154  # rc/s are assigned inside the trap at fire time
trap '
  rc=$?
  if [ "$rc" -ne 0 ] && [ -f "$STATE_FILE" ]; then
    s=$(cat "$STATE_FILE" 2>/dev/null || true)
    case "$s" in
      RUNNING*)
        echo "ERROR $HEAD_SHA $(date +%s)" > "$STATE_FILE"
        append_history "ERROR" 2>/dev/null || true
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
# Run under coreutils `timeout` when available (stock macOS lacks it) so the
# script -- not the harness -- observes a hung review and can log TIMEOUT.
TIMEOUT_BIN=$(command -v timeout || true)
if [ -n "$TIMEOUT_BIN" ]; then
  REVIEW_JSONL=$(cd "$REPO_ROOT" && "$TIMEOUT_BIN" "$CODEX_REVIEW_TIMEOUT" \
    "$CODEX_BIN" exec review --json \
    --commit "$HEAD_SHA" \
    --full-auto \
    2>"$STDERR_FILE") || REVIEW_EXIT=$?
else
  REVIEW_JSONL=$(cd "$REPO_ROOT" && "$CODEX_BIN" exec review --json \
    --commit "$HEAD_SHA" \
    --full-auto \
    2>"$STDERR_FILE") || REVIEW_EXIT=$?
fi
REVIEW_STDERR=$(cat "$STDERR_FILE" 2>/dev/null || true)
rm -f "$STDERR_FILE"

# timeout(1) exits 124 (TERM) or 137 (KILL) when the limit is hit.
IS_TIMEOUT=false
if [ -n "$TIMEOUT_BIN" ] && { [ "$REVIEW_EXIT" -eq 124 ] || [ "$REVIEW_EXIT" -eq 137 ]; }; then
  IS_TIMEOUT=true
fi

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
if [ "$IS_TIMEOUT" = "true" ]; then
  REVIEW_PROSE="(review timed out after ${CODEX_REVIEW_TIMEOUT}s)"
elif [ "$JSONL_MODE" = "true" ]; then
  # Codex can emit several agent_message items (streaming partials + final).
  # Take the LAST one -- that's the authoritative final summary. Concatenating
  # them duplicates the review text in the prose surfaced back to Claude.
  #
  # Use per-line `try fromjson catch empty` so a single malformed/trailing
  # line in the stream doesn't abort parsing and mask earlier findings the
  # way `jq -s` (slurp) would. Each match is emitted as a single-line JSON
  # string literal (-c without -r) so embedded newlines survive the
  # `tail -n 1` that picks the last match, then decoded back to raw text
  # with a second jq pass -- a pure-jq round-trip, since base64(1) decode
  # flags differ across GNU/macOS.
  LAST_MESSAGE_JSON=$(printf '%s\n' "$REVIEW_JSONL" \
    | jq -cR 'try (fromjson | select(.type=="item.completed" and .item.type=="agent_message") | .item.text) catch empty' \
    2>/dev/null \
    | tail -n 1)
  if [ -n "$LAST_MESSAGE_JSON" ]; then
    REVIEW_PROSE=$(printf '%s' "$LAST_MESSAGE_JSON" | jq -r '.' 2>/dev/null || true)
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
# Same [^=[:space:]] tail as the HAS_ISSUES pattern: rubric legend lines
# ("[P1] = critical") must not count as findings, or blocking_count could
# read >0 on a PASS verdict.
FINDINGS_JSON=$(printf '%s\n' "$REVIEW_PROSE" \
  | grep -E '^[[:space:]]*([-*>][[:space:]]+)?\[P[123]\][[:space:]]+[^=[:space:]]' \
  | jq -Rn '[inputs | capture("^[[:space:]]*([-*>][[:space:]]+)?\\[(?<priority>P[123])\\][[:space:]]+(?<title>[^=[:space:]].*)$")]' \
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
# TIMEOUT and ERROR are infrastructure outcomes, not review findings: they
# surface as non-blocking context. Only genuine [P1]/[P2] findings block.
if [ "$IS_TIMEOUT" = "true" ]; then
  echo "TIMEOUT $HEAD_SHA $(date +%s)" > "$STATE_FILE"
  append_history "TIMEOUT"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg secs "$CODEX_REVIEW_TIMEOUT" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " timed out after " + $secs + "s and was skipped. You are not blocked. Mention the timeout to the user; they can re-check with /codex-review (possibly on a smaller slice) or investigate a hung Codex MCP server (see plugin README troubleshooting).")}}'
elif [ "$REVIEW_EXIT" -ne 0 ]; then
  echo "ERROR $HEAD_SHA $(date +%s)" > "$STATE_FILE"
  append_history "ERROR"
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg exit_code "$REVIEW_EXIT" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " errored (exit code: " + $exit_code + ") and produced no verdict. You are not blocked.\n\n" + $review + "\n\nMention the error to the user -- likely a Codex auth or rate-limit issue.")}}'
elif [ "$HAS_ISSUES" = "true" ]; then
  echo "FAIL $HEAD_SHA $(date +%s)" > "$STATE_FILE"
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
