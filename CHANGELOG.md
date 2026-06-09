# Changelog

All notable changes to the `codex-review` plugin, newest first.

## 1.5.0

- **Finding waivers.** New `/codex-review-waive` command suppresses a disputed finding per-repo: keys live in `.git/codex-review-waived`, matched on normalized title (case, whitespace, and line numbers stripped, so shifted-line re-reports stay waived). Waivers suppress blocking only — waived findings remain in the history log with `"waived": true`, `blocking_count` excludes them, a new `waived_count` field and message notes keep suppression visible, and each finding now carries its `waive_key` so the command can copy it verbatim.
- **SessionStart health check.** A missing or unauthenticated codex CLI used to disable reviews silently. A new SessionStart hook emits one line of context when reviews won't run (`CODEX_REVIEW_SKIP` set, `.git/codex-review-skip` present, codex binary missing, `codex login status` failing) and stays silent when healthy.
- **Amend-aware fix guidance.** The fix loop now advises `git commit --amend` while the reviewed commit is unpushed, keeping broken intermediate versions out of history entirely; if the commit is already on a remote (e.g. a `git commit && git push` one-liner), it advises a new commit and never suggests rewriting published history.
- **Review timeout raised: default 280s → 600s, hook ceiling 300s → 900s.** A measured legitimate review of a small commit took 146s (reviews investigate the repo, not just the diff), so 280s produced false timeouts that silently skipped reviews. The higher hook ceiling also makes `CODEX_REVIEW_TIMEOUT` usable across its full range — previously, setting it above ~300s silently regressed to the harness-kill path that loses the TIMEOUT verdict. Values above 880s are now clamped so the script always observes the kill with headroom to write the verdict.

## 1.4.0

- **Reviews run under `timeout(1)`** (`CODEX_REVIEW_TIMEOUT`, default 280s, under the 300s harness hook limit). Previously a hung review was killed by the harness with a fatal signal, which skips bash EXIT traps: state stayed `RUNNING` forever and the advertised `TIMEOUT` history line was never written. The trap remains as a backstop for script failures and now records `ERROR` instead of mislabeling them as timeouts.
- **ERROR/TIMEOUT verdicts no longer block.** Codex infrastructure failures (auth, rate limits, hangs) surface as non-blocking context; only genuine `[P1]`/`[P2]` findings block.
- **State moved into `.git/`** (`codex-review-state`, `codex-review-loop-count`), resolved via `git rev-parse --git-common-dir` like the history log. The fix loop can no longer commit its own markers via `git add -A`, and per-project `.gitignore` entries are obsolete. Legacy working-tree markers are removed automatically on the first hook run.
- **Stale-state self-healing.** State records `<verdict> <sha> <epoch>`. The Stop hook clears a `FAIL` whose commit no longer matches HEAD or that is over an hour old (an abandoned session can't hijack later turns), clears `RUNNING` fossils older than 10 minutes, and honors `stop_hook_active` as a corruption guard when the loop counter vanishes mid-loop.
- **Commit success decided by git, not stdout prose.** HEAD freshness (committer timestamp within 15s) plus history dedup replace the "N files changed" sniffing, which missed `git commit -q` and non-English locales and false-positived on commands like `git log --grep commit --stat`. Dedup also stops re-paying for a re-review of an already-reviewed sha.
- **File-based kill switch** `.git/codex-review-skip` — works mid-session, unlike `CODEX_REVIEW_SKIP`, which hooks only inherit from Claude Code's launch environment.
- **Findings/verdict consistency.** Rubric legend lines (`[P1] = critical`) are excluded from history findings, so `blocking_count` can no longer read >0 on a `PASS`.
- **`plugin_version` in history entries read from `plugin.json`** (was hardcoded and had drifted).
- **Portability.** POSIX character-class regexes replace GNU `\b` (absent from BSD grep); the base64 round-trip is replaced with a pure-jq JSON-literal round-trip (macOS `base64` decode flags differ).
- **Repo resolution.** `cd` chains in the command prefix apply cumulatively (`cd a && cd b && git commit` resolves `a/b`); `git -C` is extracted from the commit segment only, so a `-C` on another command in the same line can't redirect the review to the wrong repo.
- **Skill/command dedup.** `SKILL.md` is the single source of the review workflow; `/codex-review` delegates to it. Skill frontmatter fixed to use `allowed-tools` (`tools` was silently ignored, leaving the skill unrestricted).
- **Numeric env knobs validated** (`CODEX_REVIEW_MAX_OUTPUT`, `CODEX_REVIEW_TIMEOUT`, `CODEX_REVIEW_MAX_LOOPS`); garbage values fall back to defaults instead of tripping `set -e`.
- **Test suite + CI.** 35 bats tests cover both hooks end to end with a stub codex CLI; GitHub Actions runs shellcheck and the suite on ubuntu-latest and macos-latest.

## 1.3.0

- **New slash command** `/codex-review-plan [path]` — runs a Codex review on a Claude Code plan file in `~/.claude/plans/` before the user approves execution. No git state required; uses `codex exec` with `--skip-git-repo-check` so it works from any directory. Honors `$CODEX_BIN` (matches the post-commit hook's pattern).

## 1.2.0

- **Structured parsing via `codex exec review --json`.** Post-commit hook now parses Codex's JSONL event stream instead of scraping prose. Eliminates the false-positive class produced by the earlier sed-marker + grep-regex approach (where `[P1]`/`[P2]` mentions in Codex's own priority-rubric preamble would incorrectly trigger FAIL verdicts).
- **Per-repo review history log** at `.git/codex-reviews.jsonl` (resolved via `git rev-parse --git-common-dir` so worktrees and submodules work). One line per review: timestamp, SHA, branch, author, verdict, structured findings (priority + title), blocking count, truncated prose, duration, plugin version.
- **Agent_message deduplication.** Codex can emit multiple `agent_message` items per review (streaming partial + final); take the last one, not the concatenation.
- **Malformed-JSONL tolerance.** Per-line `try fromjson catch empty` parsing with base64 round-trip survives trailing garbage lines without silently downgrading to the fallback parser.
- **stderr/stdout separation.** Codex startup warnings no longer contaminate the JSONL stream and defeat mode detection.
- **Timeout history recording.** The EXIT trap now calls the history-log append on the `TIMEOUT` branch so hook-kill outcomes appear in the log alongside PASS / FAIL / ERROR.
- **Legacy text-parser fallback** retained (one release) for older Codex CLIs that ignore `--json`.

## 1.1.0

- **False-positive detection fix.** Scoped `[P1]`/`[P2]` detection to the extracted review summary (not the full Codex output), anchored the pattern to line start, and only evaluated findings on exit-zero output.
- **Quote-aware segmenter for CWD resolution.** Replaced the three overlapping heuristics with `git rev-parse --show-toplevel` rooted at the session CWD, plus a quote-aware awk parser for `cd`/`git -C` that handles `cd subrepo && git commit`, `cd "path with sep"`, `(git commit -m x)`, `GIT_AUTHOR_NAME=x git commit`, `sudo git commit`, and `/usr/bin/git commit`.
- **Broader commit-detection regex.** `git commit` is now recognised even when preceded by env assignments, `sudo`, `env`, or an absolute path.
- **`codex` not found → silent skip** (was: block with a self-contradictory "skipped" reason).
- **`CODEX_REVIEW_SKIP` env var** as a per-session bypass.
- **`CODEX_REVIEW_MAX_LOOPS` env var** overrides the default Stop-hook safety-valve iteration cap (5).
- **Timeout trap** writes `TIMEOUT` to the state file so killed reviews aren't indefinitely stuck as `FAIL`.
- **Stop hook safety-valve message** emitted via `hookSpecificOutput` when `MAX_LOOPS` is reached, instead of silently clearing state.
- **Marketplace rename** `codex-review@codex-review` → `codex-review@andreidavid` with documented migration steps.
- **Expanded README** with prerequisites (Codex CLI auth), cost and latency section, configuration env var table, troubleshooting.

## 1.0.0

- Initial release. Post-commit Codex reviews via PostToolUse hook; Stop hook fix-loop; `/codex-review` slash command and `codex-review` skill for on-demand reviews.
