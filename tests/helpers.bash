# Shared helpers for the codex-review hook test suite.

setup_repo() {
  TESTDIR=$(mktemp -d)
  STUB_DIR="$TESTDIR/bin"
  mkdir -p "$STUB_DIR"
  write_stub

  REPO="$TESTDIR/repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email test@example.com
  git -C "$REPO" config user.name Test
  echo one > "$REPO/file"
  git -C "$REPO" add file
  git -C "$REPO" commit -qm initial

  HOOK="$BATS_TEST_DIRNAME/../plugins/codex-review/hooks/scripts/post-commit-review.sh"
  STOP_HOOK="$BATS_TEST_DIRNAME/../plugins/codex-review/hooks/scripts/stop-review-loop.sh"
}

teardown_repo() {
  rm -rf "$TESTDIR"
}

# Stub codex CLI; behavior selected via CODEX_STUB_MODE.
write_stub() {
  cat > "$STUB_DIR/codex" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "login" ]; then
  exit "${CODEX_STUB_LOGIN_EXIT:-0}"
fi
case "${CODEX_STUB_MODE:-pass}" in
  pass)
    echo '{"type":"thread.started"}'
    echo '{"type":"item.completed","item":{"type":"agent_message","text":"Looks good. No issues found."}}'
    ;;
  fail)
    echo '{"type":"thread.started"}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Found problems.\n\n- [P1] Null deref — src/a.c:3\n- [P3] Naming nit — src/b.c:9"}}'
    ;;
  fail_two)
    echo '{"type":"thread.started"}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Found problems.\n\n- [P1] Null deref — src/a.c:3\n- [P2] Off-by-one — src/c.c:14-15"}}'
    ;;
  legend_only)
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Rubric:\n[P1] = critical\n[P2] = important\nNo issues found."}}'
    ;;
  malformed)
    echo '{"type":"thread.started"}'
    echo 'not json at all {{{'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"- [P1] Real bug — x.c:1"}}'
    ;;
  multi_message)
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"partial draft with [P1] noise"}}'
    printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"final verdict: no issues"}}'
    ;;
  text)
    printf 'some banner\ncodex\nLegacy prose review. No issues.\n'
    ;;
  error)
    echo "auth failure" >&2
    exit 2
    ;;
  hang)
    sleep 60
    ;;
esac
STUB
  chmod +x "$STUB_DIR/codex"
}

# hook_input <command> [stdout] [cwd]
hook_input() {
  jq -nc --arg cwd "${3:-$REPO}" --arg cmd "$1" --arg out "${2:-}" \
    '{cwd:$cwd, tool_input:{command:$cmd}, tool_response:{stdout:$out}}'
}

# stop_input [cwd] [stop_hook_active]
stop_input() {
  jq -nc --arg cwd "${1:-$REPO}" --argjson active "${2:-false}" \
    '{cwd:$cwd, stop_hook_active:$active}'
}

run_post_hook() {
  CODEX_BIN="$STUB_DIR/codex" bash "$HOOK"
}

history_file() {
  echo "$REPO/.git/codex-reviews.jsonl"
}

state_file() {
  echo "$REPO/.git/codex-review-state"
}

counter_file() {
  echo "$REPO/.git/codex-review-loop-count"
}

round_counter_file() {
  echo "$REPO/.git/codex-review-round-count"
}
