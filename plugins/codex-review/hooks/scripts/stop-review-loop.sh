#!/usr/bin/env bash
# Stop hook for codex-review plugin
# Keeps Claude iterating on fixes until a pending FAIL review clears, with
# a safety-valve cap on iterations and staleness checks so leftover state
# from a killed review or an abandoned session never blocks unrelated work.
set -euo pipefail

# All-digit values are additionally normalized with $((10#...)): a leading
# zero would otherwise read as octal inside $(( )) and abort on 08/09.
: "${CODEX_REVIEW_MAX_LOOPS:=5}"
case "$CODEX_REVIEW_MAX_LOOPS" in
  ''|*[!0-9]*) CODEX_REVIEW_MAX_LOOPS=5 ;;
esac
CODEX_REVIEW_MAX_LOOPS=$((10#$CODEX_REVIEW_MAX_LOOPS))

# A FAIL older than this (seconds) is treated as abandoned and cleared.
FAIL_MAX_AGE=3600
# A RUNNING marker older than this is a fossil from a review the harness
# killed at the hook timeout (the post-commit script never got to downgrade
# it) and is cleared. Sized past the 900s hook ceiling in hooks.json: a
# marker this old CANNOT be a live review, so neither this branch nor the
# GC sweep can eat an in-flight session's state or counters even with
# CODEX_REVIEW_TIMEOUT raised to its 880s maximum.
RUNNING_MAX_AGE=960

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
# Derive the state-file key for a session id. Ids that are already
# filename-safe and short pass through verbatim (harness ids are UUIDs, so
# this is the normal case); anything else keeps a safe prefix and appends
# cksum+length of the raw id, so distinct raw ids cannot collapse to the
# same key the way plain strip-and-truncate sanitization would. Must stay
# identical to post-commit-review.sh so file names and ownership
# comparisons agree.
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
# the raw id verbatim, and legacy ownership compares raw ids ONLY (1.7.0+
# writes bare state solely for session-less commits, with an empty owner
# field, so a populated bare owner field is always a raw legacy id).
RAW_SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
SESSION_ID=$(derive_session_key "$RAW_SESSION_ID")

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

NOW=$(date +%s)

# --- Global age cleanup (ownership-blind) ---
# State is per-session (see below), so abandoned sessions would otherwise
# leave files behind forever. Sweep every state file -- bare or suffixed --
# whose age exceeds its verdict's window, taking its same-suffix counters
# with it. Ownership never blocks this: age is the one rule that applies to
# everyone, which is what lets any session clean up after a dead one. A
# corrupt/unstamped timestamp or one from the future (clock stepped
# backward) reads as stale, matching the round-counter rule.
for gc_file in "$GITDIR"/codex-review-state "$GITDIR"/codex-review-state.*; do
  [ -f "$gc_file" ] || continue
  gc_line=$(head -c 256 "$gc_file" 2>/dev/null || true)
  read -r gc_verdict _ gc_ts _ <<<"$gc_line " || true
  case "${gc_verdict:-}" in
    RUNNING|FAIL|ERROR|TIMEOUT|INCONCLUSIVE) ;;
    # Unknown verdicts are corruption evidence: preserved for inspection,
    # never swept (mirrors the unknown-verdict branch below).
    *) continue ;;
  esac
  case "${gc_ts:-}" in
    ''|*[!0-9]*) gc_ts=0 ;;
  esac
  gc_ts=$((10#$gc_ts))
  gc_max=$FAIL_MAX_AGE
  if [ "${gc_verdict:-}" = "RUNNING" ]; then
    gc_max=$RUNNING_MAX_AGE
  fi
  gc_age=$((NOW - gc_ts))
  if [ "$gc_ts" -eq 0 ] || [ "$gc_age" -gt "$gc_max" ] || [ "$gc_age" -lt 0 ]; then
    gc_suffix="${gc_file#"$GITDIR"/codex-review-state}"
    rm -f "$gc_file" \
      "$GITDIR/codex-review-loop-count$gc_suffix" \
      "$GITDIR/codex-review-round-count$gc_suffix"
  fi
done

# --- Resolve THIS session's state ---
# State files are keyed by session (".<session-id>" suffix) so concurrent
# fix loops in linked worktrees cannot overwrite each other. The bare
# (unsuffixed) names are the legacy/anonymous bucket: pre-1.7.0 state and
# commits made without a session id. A session with an id falls back to the
# bare file only when it has no suffixed state of its own -- that is where
# its pre-upgrade loop (or a session-less commit's state) lives, and the
# ownership check below decides whether the bare state is actually its.
STATE_SUFFIX=""
if [ -n "$SESSION_ID" ]; then
  STATE_SUFFIX=".$SESSION_ID"
fi
STATE_FILE="$GITDIR/codex-review-state$STATE_SUFFIX"
LOOP_COUNTER="$GITDIR/codex-review-loop-count$STATE_SUFFIX"
STATE_IS_LEGACY=0
if [ -n "$STATE_SUFFIX" ] && [ ! -f "$STATE_FILE" ] \
   && [ -f "$GITDIR/codex-review-state" ]; then
  STATE_FILE="$GITDIR/codex-review-state"
  LOOP_COUNTER="$GITDIR/codex-review-loop-count"
  STATE_IS_LEGACY=1
fi

if [ ! -f "$STATE_FILE" ]; then
  # Clear this session's stray counter, plus a bare orphan: reaching here
  # with a suffix means no bare state exists either (the fallback above
  # would have taken it), so a bare counter has nothing it belongs to.
  rm -f "$LOOP_COUNTER" "$GITDIR/codex-review-loop-count"
  echo '{}'; exit 0
fi

# State format: "<VERDICT> <full-sha> <epoch> <session-id>". Pre-1.4.0 wrote
# fewer fields; missing sha/epoch reads as stale below, which is the safe
# interpretation. The session field matters only for the bare file (suffixed
# files belong to their session by construction); missing there means older
# state or a commit made outside a Claude session, which disables the
# ownership check and preserves prior behaviour.
STATE=$(head -c 256 "$STATE_FILE" 2>/dev/null || true)
read -r VERDICT STATE_SHA STATE_TS STATE_SESSION _ <<<"$STATE " || true
case "${STATE_TS:-}" in
  ''|*[!0-9]*) STATE_TS=0 ;;
esac
STATE_TS=$((10#$STATE_TS))

HEAD_SHA=$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)

case "${VERDICT:-}" in
  FAIL)
    # Order matters here, and it is: age -> ownership -> commit staleness.
    #
    # 1. Age/format staleness applies to anyone (backstop for the sweep
    #    above): old state format or an abandoned session's leftovers must
    #    never hijack an unrelated future turn.
    if [ -z "${STATE_SHA:-}" ] || [ "$STATE_TS" -eq 0 ] \
       || [ $((NOW - STATE_TS)) -gt "$FAIL_MAX_AGE" ] \
       || [ $((NOW - STATE_TS)) -lt 0 ]; then
      rm -f "$STATE_FILE" "$LOOP_COUNTER"
      echo '{}'; exit 0
    fi

    # 2. Ownership (bare file only): the fix loop belongs to the session
    #    that made the reviewed commit. Another session must not be told to
    #    amend it -- and must not touch the state or counter the owner is
    #    still using. This runs BEFORE the superseded-commit check because
    #    HEAD is per-worktree: in linked worktrees another session's HEAD
    #    never matches this saga's sha, and the old order let any bystander
    #    turn end clear a fresh FAIL through the staleness rule.
    #    This applies only when reading the bare legacy file: suffixed
    #    state belongs to this session by construction. A populated bare
    #    owner field is always a RAW pre-1.7.0 id (1.7.0+ writes bare state
    #    only for session-less commits, with no owner field), so compare
    #    raw ids ONLY -- matching the derived key here would let a session
    #    whose key happens to equal a legacy raw id claim a foreign saga.
    if [ "$STATE_IS_LEGACY" = "1" ] \
       && [ -n "${STATE_SESSION:-}" ] && [ -n "${RAW_SESSION_ID:-}" ] \
       && [ "$STATE_SESSION" != "$RAW_SESSION_ID" ]; then
      echo '{}'; exit 0
    fi

    # 3. Commit staleness, now known to be judged against the owner's (or
    #    the anonymous bucket's) own worktree: the offending commit is gone
    #    or superseded, so the saga is over.
    if [ "$HEAD_SHA" != "$STATE_SHA" ]; then
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
        *)           COUNT=$((10#$raw)) ;;
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

    jq -n '{"decision": "block", "reason": "Codex review found issues that need fixing. Fix the issues identified in the review and commit them -- amend the reviewed commit if it has not been pushed, otherwise create a new commit. Do NOT re-run the codex review yourself -- the post-commit hook will trigger it automatically when you commit. Do NOT stop until the review passes."}'
    ;;
  RUNNING)
    # Review mid-flight: nothing to block on. But a RUNNING marker that has
    # outlived the hook timeout is a fossil from a killed review -- clear it.
    if [ "$STATE_TS" -eq 0 ] || [ $((NOW - STATE_TS)) -gt "$RUNNING_MAX_AGE" ]; then
      rm -f "$STATE_FILE" "$LOOP_COUNTER"
    fi
    echo '{}'
    ;;
  ERROR|TIMEOUT|INCONCLUSIVE)
    rm -f "$STATE_FILE" "$LOOP_COUNTER"
    echo '{}'
    ;;
  *)
    # Unknown verdict — do NOT silently clear (that would hide a corruption bug).
    # Let Claude stop; leave the state file in place for the user to inspect.
    echo '{}'
    ;;
esac
