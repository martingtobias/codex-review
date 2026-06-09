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

2. Read the most recent FAIL entry:
   ```bash
   jq -s '[.[] | select(.verdict=="FAIL")] | last' "$GITDIR/codex-reviews.jsonl"
   ```
   If there is none (or the file is missing), tell the user there is no
   failed review to waive findings from, and stop.

3. List its blocking findings (priority `P1`/`P2` with `waived` false),
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

5. If every blocking finding in that entry is now waived, release the block:
   ```bash
   rm -f "$GITDIR/codex-review-state" "$GITDIR/codex-review-loop-count"
   ```

6. Confirm to the user: which finding(s) were waived, that future reviews
   will not block on them, and that un-waiving is editing or deleting lines
   in `$GITDIR/codex-review-waived` (`#` lines are comments).

## Notes

- Waivers match on a normalized title (case, whitespace, and line numbers
  stripped), so a finding re-reported at a shifted line stays waived. If
  Codex re-words a finding substantially, it will need waiving again.
- Waivers are per-repo and never committed (the file lives in `.git/`).
