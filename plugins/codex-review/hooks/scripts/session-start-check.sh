#!/usr/bin/env bash
# SessionStart hook for codex-review plugin
# Warn once, at session start, when post-commit reviews are not going to
# run -- a missing or unauthenticated codex CLI must not silently disable
# the protection the user believes they have. Healthy setups emit nothing.
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-$(command -v codex || true)}"

INPUT=$(cat)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null) || CWD=""
if [ -z "$CWD" ]; then
  CWD="${CLAUDE_PROJECT_DIR:-$PWD}"
fi

emit() {
  jq -n --arg msg "$1" \
    '{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": $msg}}'
  exit 0
}

if [ -n "${CODEX_REVIEW_SKIP:-}" ]; then
  emit "codex-review plugin: CODEX_REVIEW_SKIP is set -- post-commit reviews are OFF for this session."
fi

# Per-repo kill-switch file (resolved like the other hooks: cwd -> repo root
# -> git common dir).
GITDIR=""
if [ -d "$CWD" ]; then
  REPO_ROOT=$(cd "$CWD" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=""
  if [ -n "$REPO_ROOT" ]; then
    GITDIR=$(cd "$REPO_ROOT" 2>/dev/null && git rev-parse --git-common-dir 2>/dev/null) || GITDIR=""
    case "$GITDIR" in
      ''|/*) ;;
      *) GITDIR="$REPO_ROOT/$GITDIR" ;;
    esac
  fi
fi
if [ -n "$GITDIR" ] && [ -e "$GITDIR/codex-review-skip" ]; then
  emit "codex-review plugin: $GITDIR/codex-review-skip exists -- post-commit reviews are OFF for this repo. Delete the file to re-enable."
fi

if [ -z "$CODEX_BIN" ] || [ ! -x "$CODEX_BIN" ]; then
  emit "codex-review plugin: codex CLI not found -- post-commit reviews are OFF. Install with: npm install -g @openai/codex (or set CODEX_BIN)."
fi

if ! "$CODEX_BIN" login status >/dev/null 2>&1; then
  emit "codex-review plugin: codex CLI found but 'codex login status' did not succeed -- reviews will likely error until you run 'codex login' or export OPENAI_API_KEY. (Ignore if your codex version predates 'login status'.)"
fi

SANDBOX_STATE_FILE="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/codex-review/sandbox-mode"
SANDBOX_MODE=""
if [ -f "$SANDBOX_STATE_FILE" ]; then
  SANDBOX_MODE=$(cat "$SANDBOX_STATE_FILE" 2>/dev/null || true)
else
  SANDBOX_MODE="${CLAUDE_PLUGIN_OPTION_SANDBOX_MODE:-}"
fi
case "$SANDBOX_MODE" in
  danger-full-access|bypass)
    emit "codex-review plugin: sandbox_mode=$SANDBOX_MODE -- automatic reviews run with elevated access."
    ;;
esac

# Healthy: stay silent -- no per-session noise.
echo '{}'
