#!/usr/bin/env bats

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

run_stop_hook() {
  bash "$STOP_HOOK"
}

fresh_fail_state() {
  echo "FAIL $(git -C "$REPO" rev-parse HEAD) $(date +%s)" > "$(state_file)"
}

@test "no state file: passes through and clears stray counter" {
  echo "2" > "$(counter_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(counter_file)" ]
}

@test "fresh FAIL for current HEAD blocks and increments counter" {
  fresh_fail_state
  out=$(stop_input | run_stop_hook)
  [ "$(echo "$out" | jq -r '.decision')" = "block" ]
  [ "$(cat "$(counter_file)")" = "1" ]
}

@test "loop cap reached: stops with explanation and clears state" {
  fresh_fail_state
  echo "1" > "$(counter_file)"
  out=$(stop_input | CODEX_REVIEW_MAX_LOOPS=2 run_stop_hook)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"max of 2"* ]]
  [ ! -f "$(state_file)" ]
  [ ! -f "$(counter_file)" ]
}

@test "FAIL for a superseded commit is stale: cleared, no block" {
  echo "FAIL 0000000000000000000000000000000000000000 $(date +%s)" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(state_file)" ]
}

@test "FAIL older than an hour is stale: cleared, no block" {
  echo "FAIL $(git -C "$REPO" rev-parse HEAD) $(( $(date +%s) - 4000 ))" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(state_file)" ]
}

@test "pre-1.4.0 bare FAIL state is treated as stale" {
  echo "FAIL" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(state_file)" ]
}

@test "fresh RUNNING passes through and is preserved" {
  echo "RUNNING $(git -C "$REPO" rev-parse HEAD) $(date +%s)" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ -f "$(state_file)" ]
}

@test "RUNNING fossil from a killed review is cleared" {
  echo "RUNNING $(git -C "$REPO" rev-parse HEAD) $(( $(date +%s) - 9999 ))" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(state_file)" ]
}

@test "ERROR and TIMEOUT states are cleared silently" {
  for v in ERROR TIMEOUT; do
    echo "$v $(git -C "$REPO" rev-parse HEAD) $(date +%s)" > "$(state_file)"
    out=$(stop_input | run_stop_hook)
    [ "$out" = "{}" ]
    [ ! -f "$(state_file)" ]
  done
}

@test "unknown verdict passes through but is preserved for inspection" {
  echo "BOGUS" > "$(state_file)"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
  [ -f "$(state_file)" ]
}

@test "stop_hook_active with vanished counter clears state instead of looping" {
  fresh_fail_state
  out=$(stop_input "$REPO" true | run_stop_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(state_file)" ]
}

@test "CODEX_REVIEW_SKIP env bypasses" {
  fresh_fail_state
  out=$(stop_input | CODEX_REVIEW_SKIP=1 run_stop_hook)
  [ "$out" = "{}" ]
}

@test "kill-switch file bypasses" {
  fresh_fail_state
  touch "$REPO/.git/codex-review-skip"
  out=$(stop_input | run_stop_hook)
  [ "$out" = "{}" ]
}

@test "legacy working-tree markers are migrated away" {
  touch "$REPO/.codex-review-state" "$REPO/.codex-review-loop-count"
  stop_input | run_stop_hook > /dev/null
  [ ! -e "$REPO/.codex-review-state" ]
  [ ! -e "$REPO/.codex-review-loop-count" ]
}

@test "non-repo cwd passes through" {
  out=$(stop_input "$TESTDIR/nonrepo-$$-missing" | run_stop_hook)
  [ "$out" = "{}" ]
}
