#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  CHECK="$BATS_TEST_DIRNAME/../plugins/codex-review/hooks/scripts/session-start-check.sh"
}
teardown() { teardown_repo; }

session_input() {
  jq -nc --arg cwd "${1:-$REPO}" '{cwd: $cwd, source: "startup"}'
}

run_check() {
  CODEX_BIN="$STUB_DIR/codex" bash "$CHECK"
}

@test "healthy setup is silent" {
  out=$(session_input | run_check)
  [ "$out" = "{}" ]
}

@test "missing codex binary warns that reviews are OFF" {
  out=$(session_input | CODEX_BIN="$TESTDIR/no-such-codex" bash "$CHECK")
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"codex CLI not found"* ]]
}

@test "CODEX_REVIEW_SKIP warns reviews are OFF for the session" {
  out=$(session_input | CODEX_REVIEW_SKIP=1 run_check)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"OFF for this session"* ]]
}

@test "kill-switch file warns reviews are OFF for the repo" {
  touch "$REPO/.git/codex-review-skip"
  out=$(session_input | run_check)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"OFF for this repo"* ]]
}

@test "failed login status warns about authentication" {
  out=$(session_input | CODEX_STUB_LOGIN_EXIT=1 run_check)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"login status"* ]]
}

@test "non-repo cwd with healthy codex is silent" {
  out=$(session_input "$TESTDIR" | run_check)
  [ "$out" = "{}" ]
}
