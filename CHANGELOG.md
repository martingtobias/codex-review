# Changelog

All notable changes to the `codex-review` plugin, newest first.

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
