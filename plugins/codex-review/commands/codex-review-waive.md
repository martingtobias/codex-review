---
description: Waive a disputed Codex review finding so it stops blocking commits
argument-hint: "[finding number | all | text snippet]"
allowed-tools: [Bash, Read]
---

# Waive a Codex Review Finding

The user invoked this command with: $ARGUMENTS

Waivers are per-repo suppressions for review findings the user has decided to
accept. Waived findings no longer block the post-commit hook; they still
appear in the review history, marked `"waived": true`.

## Steps

1. Resolve the git dir and history file:
   ```bash
   GITDIR=$(git rev-parse --git-common-dir)
   ```
   History: `$GITDIR/codex-reviews.jsonl`. Waive file: `$GITDIR/codex-review-waived`.

2. Read the most recent FAIL entry **for the current commit**. History is
   repo-wide and another session may have failed more recently, so resolve
   your own failure via your worktree's HEAD — never take the latest FAIL
   alone:
   ```bash
   WAIVED_SHA=$(git rev-parse HEAD)
   jq -s --arg sha "$WAIVED_SHA" \
     '[.[] | select(.verdict=="FAIL" and .sha==$sha)] | last' \
     "$GITDIR/codex-reviews.jsonl"
   ```
   If there is none (or the file is missing), tell the user there is no
   failed review of the current commit (`HEAD`) to waive findings from,
   and stop.

3. Determine which priorities blocked **that** review. Prefer the entry's own
   `blocking_priorities` array — it records the set in force when the review
   ran, which is what the user is actually blocked by. Fall back to
   `CODEX_REVIEW_BLOCK_PRIORITIES` (space-separated) if the field is absent
   (entries written before 1.7.1), and to `P1 P2` if that is unset too.

   List its blocking findings (priority in that set, with `waived` false),
   numbered, showing priority and title. Select per `$ARGUMENTS`:
   - a number → that finding
   - `all` → every blocking finding
   - a text snippet → the finding whose title matches it unambiguously
   - no arguments and exactly one blocking finding → that finding
   - otherwise → ask the user which finding(s) to waive

4. For each selected finding, append its `waive_key` field VERBATIM as one
   line to `$GITDIR/codex-review-waived` (create the file if needed; skip
   keys already present). Never derive the key from the title yourself —
   always copy the `waive_key` value from the history entry, since the hook
   computes it with a specific normalization.

5. Release the block only if every finding at a blocking priority (the set from
   step 3 — so a `P0` must be waived explicitly, never left dangling) in that
   entry is now waived — and only for the review you just waived. State files are per-session
   (`.<session-id>` suffixes) and other sessions may have unrelated failing
   reviews that must stay blocked, so remove only state whose recorded sha
   matches `$WAIVED_SHA` from step 2, plus its loop counter:
   ```bash
   for f in "$GITDIR"/codex-review-state*; do
     [ -f "$f" ] || continue
     read -r _ state_sha _ _ < "$f"
     if [ "$state_sha" = "$WAIVED_SHA" ]; then
       rm -f "$f" "$GITDIR/codex-review-loop-count${f#"$GITDIR"/codex-review-state}"
     fi
   done
   ```

6. Confirm to the user: which finding(s) were waived, that future reviews
   will not block on them, and that un-waiving is editing or deleting lines
   in `$GITDIR/codex-review-waived` (`#` lines are comments).

## Notes

- Waivers match on a normalized title (case, whitespace, and line numbers
  stripped), so a finding re-reported at a shifted line stays waived. If
  Codex re-words a finding substantially, it will need waiving again.
- Waivers are per-repo and never committed (the file lives in `.git/`).
