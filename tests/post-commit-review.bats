#!/usr/bin/env bats

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

@test "quiet commit (no stdout) is still reviewed and passes" {
  out=$(hook_input "git commit -qm initial" "" | run_post_hook)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"passed"* ]]
  [ ! -f "$(state_file)" ]
  [ "$(jq -r '.verdict' "$(history_file)")" = "PASS" ]
}

@test "P1 findings block with FAIL state carrying sha and epoch" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook)
  [ "$(echo "$out" | jq -r '.decision')" = "block" ]
  [[ $(echo "$out" | jq -r '.reason') == *"[P1] Null deref"* ]]
  read -r verdict sha epoch < "$(state_file)"
  [ "$verdict" = "FAIL" ]
  [ "$sha" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [[ "$epoch" =~ ^[0-9]+$ ]]
}

@test "FAIL state records the session that made the commit" {
  hook_input "git commit -m initial" "" "$REPO" sess-abc | CODEX_STUB_MODE=fail run_post_hook > /dev/null
  read -r _ _ _ session < "$(state_file)"
  [ "$session" = "sess-abc" ]
}

@test "FAIL state omits the session field when the harness supplies none" {
  hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook > /dev/null
  read -r verdict sha epoch session < "$(state_file)"
  [ "$verdict" = "FAIL" ]
  [ -z "$session" ]
}

@test "findings exclude rubric legend lines; counts agree with verdict" {
  hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook > /dev/null
  line=$(tail -1 "$(history_file)")
  [ "$(echo "$line" | jq -r '.verdict')" = "FAIL" ]
  [ "$(echo "$line" | jq -r '.finding_count')" = "2" ]
  [ "$(echo "$line" | jq -r '.blocking_count')" = "1" ]
}

@test "rubric-legend-only review passes" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=legend_only run_post_hook)
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
  [ "$(jq -r '.verdict' "$(history_file)")" = "PASS" ]
  [ "$(jq -r '.blocking_count' "$(history_file)")" = "0" ]
}

@test "malformed JSONL line does not mask findings" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=malformed run_post_hook)
  [ "$(echo "$out" | jq -r '.decision')" = "block" ]
}

@test "last agent_message wins over streaming partials" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=multi_message run_post_hook)
  ctx=$(echo "$out" | jq -r '.hookSpecificOutput.additionalContext')
  [[ "$ctx" == *"final verdict"* ]]
  [[ "$ctx" != *"partial draft"* ]]
}

@test "legacy plain-text output falls back to text parser" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=text run_post_hook)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"Legacy prose review"* ]]
  [ "$(jq -r '.verdict' "$(history_file)")" = "PASS" ]
}

@test "codex error is non-blocking and recorded as ERROR" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=error run_post_hook)
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"errored"* ]]
  [ "$(jq -r '.verdict' "$(history_file)")" = "ERROR" ]
  [ "$(jq -r '.codex_exit' "$(history_file)")" = "2" ]
}

@test "hung review times out in-script, non-blocking, logged as TIMEOUT" {
  command -v timeout >/dev/null || skip "coreutils timeout not available"
  start=$(date +%s)
  out=$(hook_input "git commit -m initial" "" \
    | CODEX_STUB_MODE=hang CODEX_REVIEW_TIMEOUT=2 run_post_hook)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 30 ]
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"timed out"* ]]
  [ "$(jq -r '.verdict' "$(history_file)")" = "TIMEOUT" ]
  read -r verdict _ < "$(state_file)"
  [ "$verdict" = "TIMEOUT" ]
}

@test "non-commit git command is ignored" {
  out=$(hook_input "git log --oneline | head" "" | run_post_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(history_file)" ]
}

@test "git log --grep commit with changed-files-looking output does not review stale HEAD" {
  echo two >> "$REPO/file"
  GIT_COMMITTER_DATE="2020-01-01T00:00:00" git -C "$REPO" commit -qam old
  out=$(hook_input "git log --grep commit --stat" "3 files changed" | run_post_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(history_file)" ]
}

@test "same sha is not reviewed twice (dedup via history)" {
  hook_input "git commit -m initial" "" | run_post_hook > /dev/null
  out=$(hook_input "git commit -m initial" "" | run_post_hook)
  [ "$out" = "{}" ]
  [ "$(wc -l < "$(history_file)")" -eq 1 ]
}

@test "failed commit output skips fast" {
  out=$(hook_input "git commit -am x" "nothing to commit, working tree clean" | run_post_hook)
  [ "$out" = "{}" ]
}

@test "cd chain plus git -C resolves the right repo" {
  mkdir -p "$REPO/sub"
  out=$(hook_input "cd repo && cd sub && git -C .. commit -m initial" "" "$TESTDIR" | run_post_hook)
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"passed"* ]]
  [ -f "$(history_file)" ]
}

@test "git -C on another segment does not redirect the review" {
  git init -q "$TESTDIR/other"
  git -C "$TESTDIR/other" config user.email t@t
  git -C "$TESTDIR/other" config user.name t
  git -C "$TESTDIR/other" commit --allow-empty -qm other
  hook_input "git -C ../other log; git commit -m initial" "" | run_post_hook > /dev/null
  [ -f "$(history_file)" ]
  [ "$(jq -r '.sha' "$(history_file)")" = "$(git -C "$REPO" rev-parse HEAD)" ]
  [ ! -f "$TESTDIR/other/.git/codex-reviews.jsonl" ]
}

@test "CODEX_REVIEW_SKIP env bypasses the hook" {
  out=$(hook_input "git commit -m initial" "" | CODEX_REVIEW_SKIP=1 run_post_hook)
  [ "$out" = "{}" ]
}

@test "kill-switch file bypasses the hook" {
  touch "$REPO/.git/codex-review-skip"
  out=$(hook_input "git commit -m initial" "" | run_post_hook)
  [ "$out" = "{}" ]
  [ ! -f "$(history_file)" ]
}

@test "legacy working-tree state markers are migrated away" {
  touch "$REPO/.codex-review-state" "$REPO/.codex-review-loop-count"
  hook_input "git commit -m initial" "" | run_post_hook > /dev/null
  [ ! -e "$REPO/.codex-review-state" ]
  [ ! -e "$REPO/.codex-review-loop-count" ]
}

@test "history records the manifest version" {
  hook_input "git commit -m initial" "" | run_post_hook > /dev/null
  manifest_ver=$(jq -r '.version' \
    "$BATS_TEST_DIRNAME/../plugins/codex-review/.claude-plugin/plugin.json")
  [ "$(jq -r '.plugin_version' "$(history_file)")" = "$manifest_ver" ]
}

@test "waived blocking finding does not block; logged with waived:true" {
  echo 'null deref — src/a.c' > "$REPO/.git/codex-review-waived"
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook)
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"suppressed by waivers"* ]]
  line=$(tail -1 "$(history_file)")
  [ "$(echo "$line" | jq -r '.verdict')" = "PASS" ]
  [ "$(echo "$line" | jq -r '.blocking_count')" = "0" ]
  [ "$(echo "$line" | jq -r '.waived_count')" = "1" ]
  [ "$(echo "$line" | jq -r '.findings[] | select(.priority=="P1") | .waived')" = "true" ]
}

@test "waiver matches across shifted line numbers (key strips them)" {
  # fail_two reports src/c.c:14-15; the key has no line numbers
  echo 'off-by-one — src/c.c' > "$REPO/.git/codex-review-waived"
  echo 'null deref — src/a.c' >> "$REPO/.git/codex-review-waived"
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail_two run_post_hook)
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
  [ "$(jq -r '.waived_count' "$(history_file)")" = "2" ]
}

@test "partial waiver still blocks on the remaining finding" {
  echo 'null deref — src/a.c' > "$REPO/.git/codex-review-waived"
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail_two run_post_hook)
  [ "$(echo "$out" | jq -r '.decision')" = "block" ]
  [[ $(echo "$out" | jq -r '.reason') == *"1 additional waived finding(s) suppressed"* ]]
  line=$(tail -1 "$(history_file)")
  [ "$(echo "$line" | jq -r '.blocking_count')" = "1" ]
  [ "$(echo "$line" | jq -r '.waived_count')" = "1" ]
}

@test "comments and blank lines in the waive file are ignored" {
  printf '# accepted 2026-06-09\n\nnull deref — src/a.c\n' > "$REPO/.git/codex-review-waived"
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook)
  [ "$(echo "$out" | jq -r '.decision // empty')" = "" ]
}

@test "findings carry a waive_key in the history log" {
  hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook > /dev/null
  key=$(jq -r '.findings[] | select(.priority=="P1") | .waive_key' "$(history_file)")
  [ "$key" = "null deref — src/a.c" ]
}

@test "oversized CODEX_REVIEW_TIMEOUT is clamped below the hook ceiling" {
  command -v timeout >/dev/null || skip "coreutils timeout not available"
  start=$(date +%s)
  out=$(hook_input "git commit -m initial" "" \
    | CODEX_STUB_MODE=hang CODEX_REVIEW_TIMEOUT=9999 CODEX_REVIEW_HOOK_CEILING=23 run_post_hook)
  elapsed=$(( $(date +%s) - start ))
  [ "$elapsed" -lt 20 ]
  [[ $(echo "$out" | jq -r '.hookSpecificOutput.additionalContext') == *"timed out after 3s"* ]]
  [ "$(jq -r '.verdict' "$(history_file)")" = "TIMEOUT" ]
}

@test "unpushed FAIL advises amending the reviewed commit" {
  out=$(hook_input "git commit -m initial" "" | CODEX_STUB_MODE=fail run_post_hook)
  [[ $(echo "$out" | jq -r '.reason') == *"git commit --amend"* ]]
}

@test "FAIL on a commit already on a remote advises a new commit" {
  git init -q --bare "$TESTDIR/remote.git"
  git -C "$REPO" remote add origin "$TESTDIR/remote.git"
  git -C "$REPO" push -q origin HEAD
  out=$(hook_input "git commit -m initial && git push" "" | CODEX_STUB_MODE=fail run_post_hook)
  reason=$(echo "$out" | jq -r '.reason')
  [[ "$reason" == *"create a new commit"* ]]
  [[ "$reason" != *"git commit --amend"* ]]
}

@test "PASS clears state and loop counter" {
  echo "FAIL deadbeef 123" > "$(state_file)"
  echo "3" > "$(counter_file)"
  hook_input "git commit -m initial" "" | run_post_hook > /dev/null
  [ ! -f "$(state_file)" ]
  [ ! -f "$(counter_file)" ]
}
