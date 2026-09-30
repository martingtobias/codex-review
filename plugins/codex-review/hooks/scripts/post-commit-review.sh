#!/usr/bin/env bash
# Post-commit review hook for Claude Code
# After every successful `git commit` made via the Bash tool, run a Codex
# review on HEAD and return a verdict back to Claude.
set -euo pipefail

# --- Config (env overrides; numeric knobs fall back to defaults on garbage
# so a bad value can't trip set -e mid-script) ---
# All-digit values are additionally normalized with $((10#...)): a leading
# zero would otherwise read as octal inside $(( )) and abort on 08/09.
: "${CODEX_REVIEW_MAX_OUTPUT:=8000}"
case "$CODEX_REVIEW_MAX_OUTPUT" in
  ''|*[!0-9]*) CODEX_REVIEW_MAX_OUTPUT=8000 ;;
esac
CODEX_REVIEW_MAX_OUTPUT=$((10#$CODEX_REVIEW_MAX_OUTPUT))
# In-script review timeout. Must stay under the 900s harness hook timeout in
# hooks.json so the script itself observes the kill and can record a TIMEOUT
# verdict (a harness kill is a fatal signal: bash never runs the EXIT trap,
# state stays RUNNING). Default sized at ~4x an observed legitimate review of
# a small commit; reviews investigate the repo, not just the diff.
: "${CODEX_REVIEW_TIMEOUT:=600}"
case "$CODEX_REVIEW_TIMEOUT" in
  ''|*[!0-9]*) CODEX_REVIEW_TIMEOUT=600 ;;
esac
CODEX_REVIEW_TIMEOUT=$((10#$CODEX_REVIEW_TIMEOUT))
# Cap on consecutive FAIL review rounds since the last PASS (each fix+commit/
# amend is one round). At the cap the review STOPS BLOCKING: findings become
# advisory context, state clears, and work can proceed/push. Distinct from
# CODEX_REVIEW_MAX_LOOPS (the Stop-hook safety valve), which only counts when
# Claude tries to END ITS TURN on a FAIL — same-turn fix-and-amend cycles never
# increment it, so long review sagas were effectively unbounded.
: "${CODEX_REVIEW_MAX_ROUNDS:=8}"
case "$CODEX_REVIEW_MAX_ROUNDS" in
  ''|*[!0-9]*) CODEX_REVIEW_MAX_ROUNDS=8 ;;
esac
CODEX_REVIEW_MAX_ROUNDS=$((10#$CODEX_REVIEW_MAX_ROUNDS))
# Which priorities block the commit (space-separated). Codex's rubric spans
# P0-P3; blocking on every tier turns each style nit into a billed fix round,
# which is what makes long sagas expensive. Narrowing to e.g. "P0 P1" keeps the
# gate on the tiers that matter and demotes the rest to advisory -- they are
# still parsed, still logged, still shown to Claude, just not blocking.
# Default preserves the historical P1/P2 gate.
# Every token must be a real priority; a typo would otherwise silently widen or
# empty the gate, and an empty gate means nothing ever blocks.
: "${CODEX_REVIEW_BLOCK_PRIORITIES:=P1 P2}"
_bp_valid=1
_bp_count=0
# Unquoted on purpose: the value is a space-separated list to be split.
# shellcheck disable=SC2086
for _bp in $CODEX_REVIEW_BLOCK_PRIORITIES; do
  _bp_count=$((_bp_count + 1))
  case "$_bp" in
    P0|P1|P2|P3) ;;
    *) _bp_valid=0 ;;
  esac
done
if [ "$_bp_count" -eq 0 ] || [ "$_bp_valid" -eq 0 ]; then
  CODEX_REVIEW_BLOCK_PRIORITIES="P1 P2"
fi
# Canonicalize to single-space separation. The loop above splits on IFS (so a
# tab or newline between tokens validates fine), but the jq expressions below
# use split(" ") and would see one unmatched string -- BLOCKING_COUNT would be
# 0 and NOTHING would block. Unquoted on purpose: word-splitting collapses it.
# shellcheck disable=SC2086
CODEX_REVIEW_BLOCK_PRIORITIES=$(echo $CODEX_REVIEW_BLOCK_PRIORITIES)
unset _bp _bp_valid _bp_count
# Clamp user values below the harness ceiling, keeping headroom to parse
# output and write the verdict/history before the harness kills the hook.
# The ceiling mirrors hooks.json; the env override exists for tests.
HOOK_CEILING="${CODEX_REVIEW_HOOK_CEILING:-900}"
case "$HOOK_CEILING" in
  ''|*[!0-9]*) HOOK_CEILING=900 ;;
esac
HOOK_CEILING=$((10#$HOOK_CEILING))
MAX_TIMEOUT=$((HOOK_CEILING - 20))
if [ "$MAX_TIMEOUT" -lt 1 ]; then
  MAX_TIMEOUT=1
fi
if [ "$CODEX_REVIEW_TIMEOUT" -gt "$MAX_TIMEOUT" ]; then
  CODEX_REVIEW_TIMEOUT=$MAX_TIMEOUT
fi
CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"
# Sandbox mode may be selected two ways: via configure-sandbox-mode.sh's
# state file (works for every install channel, including sideloads), or via
# a pluginConfigs entry in settings.json that Claude Code translates to
# CLAUDE_PLUGIN_OPTION_SANDBOX_MODE (marketplace installs, where the key
# matches). The state file is authoritative when present, so
# /codex-review-sandbox-mode can override an earlier pluginConfigs opt-in.
# Env-var fallback applies only when no state file exists.
SANDBOX_STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/codex-review/sandbox-mode"
SANDBOX_MODE=""
if [ -f "$SANDBOX_STATE_FILE" ]; then
  SANDBOX_MODE=$(cat "$SANDBOX_STATE_FILE" 2>/dev/null || true)
else
  SANDBOX_MODE="${CLAUDE_PLUGIN_OPTION_SANDBOX_MODE:-}"
fi
# LOCAL PATCH: codex CLI 0.153.x rejects --full-auto ("unexpected argument"),
# exiting 2 with no verdict on every commit. workspace-write is its sandbox.
CODEX_REVIEW_MODE_ARGS=(--sandbox workspace-write)
case "$SANDBOX_MODE" in
  workspace-write) CODEX_REVIEW_MODE_ARGS=(--sandbox workspace-write) ;;
  danger-full-access) CODEX_REVIEW_MODE_ARGS=(--sandbox danger-full-access) ;;
  bypass) CODEX_REVIEW_MODE_ARGS=(--dangerously-bypass-approvals-and-sandbox) ;;
esac

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
# Session that made this commit. Keys the state files (".<session-id>"
# suffix) and is recorded in the FAIL state, so the Stop hook holds only
# THIS session in the fix loop -- a second session sharing the repo must
# never be told to amend a commit it did not make.
#
# Derive the state-file key for a session id. Ids that are already
# filename-safe and short pass through verbatim (harness ids are UUIDs, so
# this is the normal case); anything else keeps a safe prefix and appends
# cksum+length of the raw id, so distinct raw ids cannot collapse to the
# same key the way plain strip-and-truncate sanitization would. Must stay
# identical to stop-review-loop.sh so file names and ownership comparisons
# agree.
derive_session_key() {
  raw_id="$1"
  safe_id=$(printf '%s' "$raw_id" | tr -cd 'A-Za-z0-9._-')
  if [ -z "$raw_id" ]; then
    printf ''
  elif [ "$safe_id" = "$raw_id" ] && [ "${#raw_id}" -le 64 ]; then
    printf '%s' "$raw_id"
  else
    # The "=" prefix is a character the safe set strips, so no literal id
    # can ever occupy a derived key's name: the two namespaces are disjoint
    # by construction and a crafted literal id cannot alias a derived one.
    # SHA-1 via git (a hard dependency) rather than cksum: 32-bit checksums
    # of same-prefix, same-length ids collide readily.
    printf '=%s.%s' "$(printf '%s' "$safe_id" | cut -c1-40)" \
      "$(printf '%s' "$raw_id" | git hash-object --stdin 2>/dev/null || true)"
  fi
}
# The raw id is kept alongside the derived key: pre-1.7.0 state recorded
# the raw id verbatim, and legacy ownership/adoption compares raw ids ONLY
# (1.7.0+ writes bare state solely for session-less commits, with an empty
# owner field, so a populated bare owner field is always a raw legacy id).
RAW_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
SESSION_ID=$(derive_session_key "$RAW_SESSION_ID")
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
  REPO_ROOT=$(cd "$CANDIDATE_DIR" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
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
GITDIR=$(cd "$REPO_ROOT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || GITDIR=""
if [ -z "$GITDIR" ]; then
  GITDIR="$REPO_ROOT/.git"
elif [ "${GITDIR#/}" = "$GITDIR" ]; then
  # Relative path -- anchor it to the repo root.
  GITDIR="$REPO_ROOT/$GITDIR"
fi

# State is keyed by session so concurrent fix loops (linked worktrees,
# parallel sessions) cannot overwrite each other's verdicts or counters.
# No session id -> the bare legacy/anonymous names, same as pre-1.7.0.
STATE_SUFFIX=""
if [ -n "$SESSION_ID" ]; then
  STATE_SUFFIX=".$SESSION_ID"
fi
STATE_FILE="$GITDIR/codex-review-state$STATE_SUFFIX"
LOOP_COUNTER="$GITDIR/codex-review-loop-count$STATE_SUFFIX"
ROUND_COUNTER="$GITDIR/codex-review-round-count$STATE_SUFFIX"
HISTORY_FILE="$GITDIR/codex-reviews.jsonl"

# File-based kill switch (works mid-session, unlike the env var, which hooks
# only inherit from Claude Code's launch environment).
if [ -e "$GITDIR/codex-review-skip" ]; then
  echo '{}'; exit 0
fi

# One-time migration: pre-1.4.0 releases kept state markers in the working
# tree, where the fix loop could accidentally commit them.
rm -f "$REPO_ROOT/.codex-review-state" "$REPO_ROOT/.codex-review-loop-count" 2>/dev/null || true

# Adopt a legacy saga: pre-1.7.0 state lives in the bare (unsuffixed) files.
# If the bare FAIL belongs to THIS session, rename the whole trio to the
# suffixed names so the loop and round counts survive the upgrade --
# otherwise the Stop hook's corruption guard would meet a fresh suffixed
# state with no suffixed counter and release a live fix loop.
if [ -n "$STATE_SUFFIX" ] && [ -f "$GITDIR/codex-review-state" ]; then
  read -r _ _ _ LEGACY_SESSION _ < "$GITDIR/codex-review-state" 2>/dev/null || true
  # A populated bare owner field is always a RAW pre-1.7.0 id (1.7.0+
  # writes bare state only for session-less commits, with no owner field),
  # so adopt on a raw match ONLY -- matching the derived key would let a
  # session whose key happens to equal a legacy raw id adopt a foreign saga.
  if [ -n "${LEGACY_SESSION:-}" ] && [ "$LEGACY_SESSION" = "$RAW_SESSION_ID" ]; then
    for legacy_base in codex-review-state codex-review-loop-count codex-review-round-count; do
      if [ -f "$GITDIR/$legacy_base" ] && [ ! -f "$GITDIR/$legacy_base$STATE_SUFFIX" ]; then
        mv -f "$GITDIR/$legacy_base" "$GITDIR/$legacy_base$STATE_SUFFIX" 2>/dev/null || true
      fi
    done
  fi
fi

# Positive gate: HEAD must have been committed just now. A just-made commit
# (including --amend, which refreshes the committer date) always has a
# committer timestamp within seconds of the hook firing; `git log`-ish
# commands that slipped past the command regex never do.
COMMIT_TS=$(git -C "$REPO_ROOT" log -1 --format=%ct HEAD 2>/dev/null || echo 0)
case "$COMMIT_TS" in
  ''|*[!0-9]*) COMMIT_TS=0 ;;
esac
COMMIT_TS=$((10#$COMMIT_TS))
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
# True only for a FAIL demoted to advisory at the round cap -- lets history
# consumers tell a capped FAIL (did not block) from a blocking one.
CAPPED=false

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
    --argjson capped "$CAPPED" \
    --arg bp "$CODEX_REVIEW_BLOCK_PRIORITIES" \
    '($bp | split(" ")) as $set |
     {timestamp:$ts, sha:$sha, short_sha:$short, branch:$branch,
      author_name:$author_name, author_email:$author_email,
      verdict:$verdict, capped:$capped,
      blocking_priorities:$set,
      finding_count:($findings|length),
      blocking_count:([$findings[] | select((.priority | IN($set[])) and (.waived != true))] | length),
      waived_count:([$findings[] | select(.waived == true)] | length),
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
# Sandbox/approval flags belong on `codex exec`, not on the `review`
# subcommand -- codex CLI rejects `--sandbox` after `review` with
# "unexpected argument". `--dangerously-bypass-approvals-and-sandbox` and
# the deprecated `--full-auto` currently accept either position, so all
# variants go before `review` for uniformity.
if [ -n "$TIMEOUT_BIN" ]; then
  REVIEW_JSONL=$(cd "$REPO_ROOT" && "$TIMEOUT_BIN" "$CODEX_REVIEW_TIMEOUT" \
    "$CODEX_BIN" exec "${CODEX_REVIEW_MODE_ARGS[@]}" review --json \
    --commit "$HEAD_SHA" \
    2>"$STDERR_FILE") || REVIEW_EXIT=$?
else
  REVIEW_JSONL=$(cd "$REPO_ROOT" && "$CODEX_BIN" exec "${CODEX_REVIEW_MODE_ARGS[@]}" review --json \
    --commit "$HEAD_SHA" \
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

# Extract structured findings (priority + verbatim title-line). Title retains
# the " — file:line" suffix as emitted by Codex. The [^=[:space:]] tail
# rejects rubric legend lines ("[P1] = critical") so they never count as
# findings. Line-anchored, so prose mentions don't match either.
FINDINGS_JSON=$(printf '%s\n' "$REVIEW_PROSE" \
  | grep -E '^[[:space:]]*([-*>][[:space:]]+)?\[P[0-3]\][[:space:]]+[^=[:space:]]' \
  | jq -Rn '[inputs | capture("^[[:space:]]*([-*>][[:space:]]+)?\\[(?<priority>P[0-3])\\][[:space:]]+(?<title>[^=[:space:]].*)$")]' \
  2>/dev/null || true)
if ! printf '%s' "$FINDINGS_JSON" | jq -e . >/dev/null 2>&1; then
  FINDINGS_JSON="[]"
fi

# Annotate each finding with a normalized waive key and whether the user has
# waived it (via /codex-review-waive -> $GITDIR/codex-review-waived, one key
# per line, #-comments allowed). The key strips line numbers -- which shift
# between reviews -- plus case and whitespace, so a re-reported finding still
# matches its waiver. Waivers suppress blocking, not logging: waived findings
# stay in the history with "waived": true.
WAIVE_FILE="$GITDIR/codex-review-waived"
WAIVED_KEYS="[]"
if [ -f "$WAIVE_FILE" ]; then
  WAIVED_KEYS=$(grep -vE '^[[:space:]]*(#|$)' "$WAIVE_FILE" 2>/dev/null \
    | jq -Rn '[inputs]' 2>/dev/null) || WAIVED_KEYS="[]"
  if ! printf '%s' "$WAIVED_KEYS" | jq -e . >/dev/null 2>&1; then
    WAIVED_KEYS="[]"
  fi
fi
FINDINGS_JSON=$(printf '%s' "$FINDINGS_JSON" | jq --argjson waived "$WAIVED_KEYS" '
  def wkey: ascii_downcase
    | gsub(":[0-9]+(-[0-9]+)?"; "")
    | gsub("[[:space:]]+"; " ")
    | sub("^ "; "") | sub(" $"; "");
  map(. + {waive_key: (.title | wkey)}
    | . + {waived: (.waive_key as $k | $waived | index($k) != null)})' \
  2>/dev/null) || FINDINGS_JSON="[]"

# Blocking = unwaived findings at a blocking priority (CODEX_REVIEW_BLOCK_PRIORITIES).
# Only evaluated on exit-zero output.
BLOCKING_COUNT=$(printf '%s' "$FINDINGS_JSON" \
  | jq --arg bp "$CODEX_REVIEW_BLOCK_PRIORITIES" \
    '($bp | split(" ")) as $set | [.[] | select((.priority | IN($set[])) and (.waived | not))] | length' \
  2>/dev/null) || BLOCKING_COUNT=0
WAIVED_BLOCKING=$(printf '%s' "$FINDINGS_JSON" \
  | jq --arg bp "$CODEX_REVIEW_BLOCK_PRIORITIES" \
    '($bp | split(" ")) as $set | [.[] | select((.priority | IN($set[])) and .waived)] | length' \
  2>/dev/null) || WAIVED_BLOCKING=0
HAS_ISSUES=false
if [ "$REVIEW_EXIT" -eq 0 ] && [ "${BLOCKING_COUNT:-0}" -gt 0 ]; then
  HAS_ISSUES=true
fi

# Phantom-pass detector, deliberately minimal. The one empirically
# observed failure mode (nested sandbox refuses to initialize; codex
# returns exit-zero with no findings, having never run anything) leaves a
# JSONL stream with NO successfully completed execution activity at all.
# That absence -- no command_execution item that exited 0, no code-mode
# dynamic_tool_call item -- is the only fact the event stream states
# reliably, and it is what this check tests. Structural, never prose
# matching: review text that merely DISCUSSES sandbox failures (every
# review of this repo does) must not trip it.
#
# Deliberately NOT attempted: verifying that the activity actually read
# this repository. Aggregated shell output under-determines that --
# compound commands, pipelines, `|| echo` fallbacks, quoting, and output
# that legitimately contains error-like text each defeat any command-text
# or output predicate short of a real shell parser (a previous, far
# stricter version of this check grew seven layers of such forensics and
# every layer minted a new counterexample). Partial sandboxes that permit
# some execution while denying repo reads are therefore an accepted
# residual, as is a reviewer that runs commands but ignores their output:
# both are indistinguishable from legitimate reviews at this layer.
# Failure direction is asymmetric by design -- when the stream shape is
# unrecognized (schema drift, no items), reviews go INCONCLUSIVE
# (visible, non-blocking) rather than phantom-passing. Only meaningful in
# JSONL mode; the legacy text parser has no event stream.
IS_INCONCLUSIVE=false
if [ "$REVIEW_EXIT" -eq 0 ] && [ "$HAS_ISSUES" = "false" ] \
   && [ "$JSONL_MODE" = "true" ]; then
  # Counted types are grounded in codex's exec JSONL serializer (verified
  # against codex-rs/exec/src/event_processor_with_jsonl_output.rs): it
  # emits command_execution, mcp_tool_call, file_change, web_search,
  # reasoning, and agent_message items; every other thread-item variant --
  # including code-mode dynamic tool calls -- is dropped (`_ => None`), so
  # no selector here could ever observe them. Activity = a
  # command_execution that exited 0 (declined/never-started items carry a
  # null exit code and are not activity) or a completed mcp_tool_call
  # (MCP tools are a legitimate emitted inspection channel). Known
  # residual until codex serializes them: a review that inspected the
  # repo exclusively through code-mode nested tools emits no activity
  # items and reads INCONCLUSIVE -- the safe, visible direction.
  EXEC_ACTIVITY=$(printf '%s\n' "$REVIEW_JSONL" \
    | jq -cR 'try (fromjson
        | select(.type=="item.completed"
            and ((.item.type=="command_execution" and (.item.exit_code // 1) == 0)
                 or (.item.type=="mcp_tool_call"
                     and (.item.status // "") == "completed")))
        | 1) catch empty' \
    2>/dev/null | wc -l | tr -d '[:space:]')
  case "$EXEC_ACTIVITY" in
    ''|*[!0-9]*) EXEC_ACTIVITY=0 ;;
  esac
  if [ "$EXEC_ACTIVITY" -eq 0 ]; then
    IS_INCONCLUSIVE=true
  fi
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
# Commands quoted for guidance the agent runs verbatim (INCONCLUSIVE retry,
# FAIL amend re-check). Anchored to the reviewed repo -- the commit may have
# come from `cd subrepo && git commit`, and a bare retry from the session
# directory would target the wrong repo. Single-quote-escaped the POSIX way
# so paths carrying spaces, quotes, `$()`, or backticks stay one inert word,
# and the strings survive the jq encoding literally.
REPO_ROOT_Q="'$(printf '%s' "$REPO_ROOT" | sed "s/'/'\\\\''/g")'"
CODEX_BIN_Q="'$(printf '%s' "$CODEX_BIN" | sed "s/'/'\\\\''/g")'"
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
elif [ "$IS_INCONCLUSIVE" = "true" ]; then
  echo "INCONCLUSIVE $HEAD_SHA $(date +%s)" > "$STATE_FILE"
  append_history "INCONCLUSIVE"
  # Same remote-containment rule as the FAIL branch: amending is only a
  # valid retry while the commit is unpushed. A pushed commit gets a
  # direct elevated one-off instead -- the flags carry the elevation, so
  # no persistent mode switch is required for it.
  if [ -z "$(git -C "$REPO_ROOT" branch -r --contains "$HEAD_SHA" 2>/dev/null)" ]; then
    # The unpushed check is POINT-IN-TIME and this advice is acted on
    # later, so it carries the same fail-closed re-check as the FAIL arm
    # (see the comment there): AMEND-OK is the only permission to amend.
    RETRY_INSTRUCTION="Tell the user the result was inconclusive and suggest two steps: (1) /codex-review-sandbox-mode danger-full-access to fix the sandbox failure, then (2) re-trigger the review of this same code with: git -C $REPO_ROOT_Q commit --amend --no-edit -- the amend mints a new sha, so the hook re-reviews it under the new mode (a re-run on the current sha is dedup-skipped, and manual /codex-review uses the sandboxed default, so it would hit the same wall). The commit was on no remote when this review ran, but that was a point-in-time check, so BEFORE you amend run this and obey what it prints: git -C $REPO_ROOT_Q fetch --all --quiet && amend_check=\$(git -C $REPO_ROOT_Q branch -r --contains $HEAD_SHA) && [ -z \"\$amend_check\" ] && echo AMEND-OK || echo DO-NOT-AMEND -- on DO-NOT-AMEND, never amend; use the one-off elevated review instead: cd $REPO_ROOT_Q && $CODEX_BIN_Q exec --sandbox danger-full-access review --commit $HEAD_SHA."
  else
    RETRY_INSTRUCTION="Tell the user the result was inconclusive. This commit is already on a remote -- do NOT amend it. To review it with the sandbox failure worked around, run the one-off: cd $REPO_ROOT_Q && $CODEX_BIN_Q exec --sandbox danger-full-access review --commit $HEAD_SHA (the flags carry the elevation; manual /codex-review uses the sandboxed default and would hit the same wall). Suggest /codex-review-sandbox-mode danger-full-access so future automatic reviews do not hit this again."
  fi
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg retry "$RETRY_INSTRUCTION" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " was INCONCLUSIVE: it returned no findings but its event stream shows no successful execution activity at all, so the code was never actually inspected -- typically the review sandbox failed to initialize (a known nested-sandboxing failure when Codex runs inside an already-sandboxed Claude session). This is NOT a clean pass. You are not blocked. " + $retry + " Do NOT tell them the code looks good.\n\nReview prose:\n" + $review)}}'
elif [ "$HAS_ISSUES" = "true" ]; then
  # Round cap: count consecutive FAIL verdicts since the last PASS (the
  # counter survives amends -- each amend is a new sha but the same saga).
  # At the cap, stop blocking: findings demote to advisory context, state
  # clears so the Stop hook releases too, and the counter resets for the
  # next saga.
  #
  # The counter is stamped with the time of the last FAIL ("<count> <epoch>");
  # a stamp older than an hour -- or a pre-stamp bare count -- reads as a
  # fresh saga. Without this, a count abandoned mid-saga (interrupt, kill
  # switch, manual fix outside a session) would leak into unrelated future
  # FAILs and trip the cap early. A stamp from the future (clock stepped
  # backward, e.g. a restored VM snapshot) also reads as stale, so it cannot
  # pin a count alive until the clock catches up.
  ROUND_MAX_AGE=3600
  ROUNDS=0
  if [ -f "$ROUND_COUNTER" ]; then
    read -r raw_rounds raw_round_ts _ < "$ROUND_COUNTER" 2>/dev/null || true
    case "${raw_round_ts:-}" in
      ''|*[!0-9]*) raw_round_ts=0 ;;
    esac
    raw_round_ts=$((10#$raw_round_ts))
    round_age=$(( $(date +%s) - raw_round_ts ))
    if [ "$raw_round_ts" -gt 0 ] \
       && [ "$round_age" -ge 0 ] && [ "$round_age" -le "$ROUND_MAX_AGE" ]; then
      case "${raw_rounds:-}" in
        ''|*[!0-9]*) ROUNDS=0 ;;
        *)           ROUNDS=$((10#$raw_rounds)) ;;
      esac
    fi
  fi
  ROUNDS=$((ROUNDS + 1))
  if [ "$ROUNDS" -ge "$CODEX_REVIEW_MAX_ROUNDS" ]; then
    rm -f "$STATE_FILE" "$LOOP_COUNTER" "$ROUND_COUNTER"
    CAPPED=true
    append_history "FAIL"
    jq -n \
      --arg sha "$SHORT_SHA" \
      --arg review "$REVIEW_SUMMARY" \
      --arg round "$ROUNDS" \
      --arg max "$CODEX_REVIEW_MAX_ROUNDS" \
      '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " still has findings, but this is review round " + $round + " of a max of " + $max + " since the last pass -- the review loop is CAPPED and no longer blocking. Treat the findings below as ADVISORY: fix any you judge real (no re-review will fire until the next natural commit), note the rest to the user, and proceed -- you may push.\n\n" + $review)}}'
  else
    echo "$ROUNDS $(date +%s)" > "$ROUND_COUNTER"
    echo "FAIL $HEAD_SHA $(date +%s) ${SESSION_ID:-}" > "$STATE_FILE"
    append_history "FAIL"
    WAIVE_NOTE=""
    if [ "${WAIVED_BLOCKING:-0}" -gt 0 ]; then
      WAIVE_NOTE=" ($WAIVED_BLOCKING additional waived finding(s) suppressed; see $WAIVE_FILE)"
    fi
    # Prefer folding fixes into the reviewed commit so the broken version
    # never survives in history -- but only while the commit is unpushed.
    # (A `git commit && git push` one-liner lands here with the commit
    # already on the remote; amending would diverge.)
    #
    # This check is POINT-IN-TIME, but the message it produces is acted on
    # much later: review latency plus however long the fix takes. Anything
    # that pushes on its own schedule (a sync daemon, a parallel session, an
    # IDE auto-push) can land inside that window, so "it has not been pushed"
    # can be false by the time it is read. The amend branch therefore says
    # when it was true and has the agent re-verify, rather than asserting a
    # fact with no expiry.
    #
    # The re-check has to FAIL CLOSED, and "no output" is the trap: an empty
    # result is exactly what means "safe to amend", so every way of producing
    # no output has to be told apart from a genuine empty answer. A failed
    # fetch, and a failed `branch -r --contains` (unknown or ambiguous sha),
    # both print nothing while meaning "I do not know". So the emitted command
    # requires each step to SUCCEED before the emptiness test is reached, and
    # prints its own verdict token: unreachable remote, failed query, and
    # already-pushed commit all come back DO-NOT-AMEND. It passes the full sha
    # (a short one can be ambiguous in a large repo) and uses --all, since a
    # bare fetch refreshes only the default remote and could miss a push to
    # another.
    if [ -z "$(git -C "$REPO_ROOT" branch -r --contains "$HEAD_SHA" 2>/dev/null)" ]; then
      FIX_INSTRUCTION="Fix the issues identified above. The reviewed commit was on no remote when this review ran, so folding the fixes in with git commit --amend is preferred -- it keeps the broken version out of history. But that was a point-in-time check and an automatic push may have landed since, so BEFORE you amend run this and obey what it prints: git -C $REPO_ROOT_Q fetch --all --quiet && amend_check=\$(git -C $REPO_ROOT_Q branch -r --contains $HEAD_SHA) && [ -z \"\$amend_check\" ] && echo AMEND-OK || echo DO-NOT-AMEND -- it fails closed, so an unreachable remote, a failed lookup and an already-pushed commit all print DO-NOT-AMEND. On DO-NOT-AMEND, create a new commit instead. Never amend a commit that is on a remote."
    else
      FIX_INSTRUCTION="Fix the issues identified above, then create a new commit (the reviewed commit is already on a remote -- do NOT amend it)."
    fi
    jq -n \
      --arg sha "$SHORT_SHA" \
      --arg review "$REVIEW_SUMMARY" \
      --arg waive_note "$WAIVE_NOTE" \
      --arg fix "$FIX_INSTRUCTION" \
      --arg round "$ROUNDS" \
      --arg max "$CODEX_REVIEW_MAX_ROUNDS" \
      '{"decision": "block", "reason": ("Codex review of commit " + $sha + " found issues (fix round " + $round + " of max " + $max + "):" + $waive_note + "\n\n" + $review + "\n\n" + $fix + " Do NOT re-run the codex review yourself -- this hook will trigger it automatically on your next commit. Do NOT push to GitHub until the review passes. If the user disagrees with a finding, they can suppress it with /codex-review-waive.")}'
  fi
else
  rm -f "$STATE_FILE" "$LOOP_COUNTER" "$ROUND_COUNTER"
  append_history "PASS"
  PASS_NOTE="no issues found"
  if [ "${WAIVED_BLOCKING:-0}" -gt 0 ]; then
    PASS_NOTE="$WAIVED_BLOCKING blocking finding(s) suppressed by waivers in $WAIVE_FILE"
  fi
  jq -n \
    --arg sha "$SHORT_SHA" \
    --arg review "$REVIEW_SUMMARY" \
    --arg note "$PASS_NOTE" \
    '{"hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": ("Codex review of commit " + $sha + " passed (" + $note + ").\n\n" + $review + "\n\nThe code looks good. Ask the user if they want to push to GitHub.")}}'
fi

# Clear the trap; we emitted a verdict cleanly.
trap - EXIT
