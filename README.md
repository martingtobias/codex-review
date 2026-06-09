# codex-review

A Claude Code plugin that runs an automatic code review with OpenAI Codex CLI after every `git commit` made via the Bash tool. On `[P1]`/`[P2]` findings, Claude is blocked and asked to fix and re-commit; on a clean review, you're prompted to push.

## Prerequisites

- **OpenAI Codex CLI on `$PATH`** — install via `npm install -g @openai/codex` (see https://github.com/openai/codex). Verify with `command -v codex`.
- **Codex authenticated** — run `codex login` (interactive) or export `OPENAI_API_KEY`. Verify with `codex exec 'hello'`.
- `jq`, `git`, `bash` on `$PATH` (standard on macOS/Linux).
- Claude Code with plugins enabled.

## Install

```text
/plugin marketplace add andreidavid/codex-review
/plugin install codex-review@andreidavid
/reload-plugins
```

The `@andreidavid` suffix is the marketplace name, not a typo: `codex-review@andreidavid` reads as "the `codex-review` plugin from the `andreidavid` marketplace". `/reload-plugins` is required after install — Claude Code won't pick up the hooks until you run it.

Pull updates later with:

```text
/plugin marketplace update andreidavid
/reload-plugins
```

### Migrating from a pre-rename install

The marketplace was renamed from `codex-review` to `andreidavid` in an early iteration. Claude Code keys marketplaces by the name they were first added under, so if you installed before the rename your local ID is still `codex-review`, and the management commands above won't find it. Remove the old registration and re-add fresh:

```text
/plugin uninstall codex-review@codex-review
/plugin marketplace remove codex-review
/plugin marketplace add andreidavid/codex-review
/plugin install codex-review@andreidavid
/reload-plugins
```

## What this plugin adds

- **Slash command** `/codex-review` — on-demand review of a specific commit, uncommitted changes, or a branch diff. Arguments: `[--commit <sha>] [--uncommitted] [--base <branch>]`.
- **Slash command** `/codex-review-plan` — run a Codex review on a Claude Code plan file in `~/.claude/plans/` before committing to implementation. Arguments: `[path-to-plan.md]`.
- **Slash command** `/codex-review-waive` — suppress a disputed finding so it stops blocking commits (see [Waiving findings](#waiving-findings)).
- **Skill** `codex-review` — invoked when you ask Claude to "review my changes", "run a codex review", etc.
- **PostToolUse hook** — after every successful `git commit` made via the Bash tool, Codex reviews the new commit. `[P1]`/`[P2]` findings block Claude and instruct it to fix and re-commit. Codex errors and timeouts do **not** block — only findings do.
- **Stop hook** — keeps Claude iterating through the fix/re-commit cycle until the review passes, capped at `CODEX_REVIEW_MAX_LOOPS` iterations (default 5). While the reviewed commit is unpushed, the loop folds fixes in with `git commit --amend`, so broken intermediate versions never survive in history.
- **SessionStart hook** — warns at session start if reviews are not going to run (codex missing or unauthenticated, kill switch active). Silent when everything is healthy.

> **Scope:** only commits that Claude itself makes via the Bash tool trigger the review. Commits you run in your own terminal (outside a Claude Code session) are not reviewed — the hook has no visibility into them. Use the `/codex-review` slash command or the skill to review those on demand.
>
> The PostToolUse hook is registered for every Bash tool call; a fast filter inside the script lets unrelated calls fall through in milliseconds, and only successful `git commit` commands escalate to running Codex.

## Reviewing Claude Code plans

Claude Code's plan mode writes an implementation plan to `~/.claude/plans/<name>.md` before you approve execution. `/codex-review-plan` asks Codex to critique that plan (missing steps, design flaws, scope/risk, verification gaps) so you catch problems before they ship as code.

```text
# Review the most recently modified plan in ~/.claude/plans/
/codex-review-plan

# Review a specific file (absolute or relative path)
/codex-review-plan /home/andrei/.claude/plans/my-plan.md
/codex-review-plan my-plan.md          # resolves against ~/.claude/plans/
```

Unlike the commit review, this uses `codex exec` (ad-hoc prose review) rather than `codex exec review` (which is diff-oriented). No git state is required. Findings use the same `[P1]`/`[P2]`/`[P3]` priority scheme; `[P1]` / `[P2]` issues suggest revising the plan before implementation.

## Waiving findings

If you disagree with a finding (false positive, accepted trade-off), waive it instead of fighting the loop:

```text
/codex-review-waive            # one blocking finding -> waives it
/codex-review-waive 2          # waive finding #2 from the last failed review
/codex-review-waive all        # waive every blocking finding
```

Waivers live in `.git/codex-review-waived`, one normalized key per line (`#` comments allowed). They match on title with case, whitespace, and line numbers stripped, so a finding re-reported at a shifted line stays waived; a substantially re-worded finding needs waiving again. Waivers suppress *blocking only* — waived findings still appear in the history log marked `"waived": true`, and PASS/FAIL messages note how many findings were suppressed. Un-waive by editing or deleting lines from the file.

## Cost and latency

Each triggered review is one Codex API call billed to your OpenAI account. The Stop-hook fix loop can run up to `CODEX_REVIEW_MAX_LOOPS` reviews per blocked session (default 5). Reviews run under a 600-second timeout (`CODEX_REVIEW_TIMEOUT`, raisable up to the 900s hook ceiling); a review that exceeds it is recorded as `TIMEOUT` and does **not** block — use `/codex-review` on smaller slices for very large commits.

If you're about to do a run of experimental or throwaway commits, bypass the plugin with `touch .git/codex-review-skip` in the repo (delete the file to re-enable). Setting `CODEX_REVIEW_SKIP=1` does the same, but only if exported **before launching Claude Code** — hooks inherit the launch environment, so exporting it mid-session has no effect.

## Configuration

Environment variables:

| Variable | Default | Effect |
|---|---|---|
| `CODEX_REVIEW_SKIP` | *unset* | If set to any non-empty value **at Claude Code launch**, both hooks no-op. For a mid-session switch, use the kill-switch file below. |
| `CODEX_REVIEW_MAX_LOOPS` | `5` | Max iterations of the fix-and-recommit loop before the Stop hook lets Claude end the turn. |
| `CODEX_REVIEW_TIMEOUT` | `600` | Seconds before an in-flight review is killed and recorded as `TIMEOUT` (non-blocking). Must stay under the 900s hook ceiling in `hooks.json` so the script observes the kill itself. |
| `CODEX_BIN` | `$(command -v codex)` | Override path to the Codex binary. |
| `CODEX_REVIEW_MAX_OUTPUT` | `8000` | Max characters of review output surfaced back to Claude. |

Per-repo kill switch: `touch .git/codex-review-skip` disables both hooks for that repo until the file is removed. To disable the plugin everywhere without uninstalling, use `/plugin disable codex-review@andreidavid`.

## State files

The hooks keep their working state inside the repo's `.git` directory — never the working tree, so nothing can be accidentally committed and no `.gitignore` edits are needed:

- `.git/codex-review-state` — current verdict (`RUNNING` / `FAIL` / `ERROR` / `TIMEOUT`) plus the commit SHA and a timestamp used for staleness detection
- `.git/codex-review-loop-count` — fix-loop counter
- `.git/codex-review-skip` — create this file to disable the hooks for the repo
- `.git/codex-review-waived` — waived finding keys (see [Waiving findings](#waiving-findings))

Stale state heals itself: the Stop hook clears a `FAIL` whose commit no longer matches HEAD or that is over an hour old, and clears `RUNNING` markers older than 10 minutes (fossils of a killed review).

Upgrading from a pre-1.4.0 install: the old working-tree markers (`.codex-review-state`, `.codex-review-loop-count`) are removed automatically the first time a hook runs, and the `.gitignore` entries they required can be deleted.

## Review history

Every review (pass or fail) appends one JSON line to `.git/codex-reviews.jsonl` in the repo where the commit was made. The file lives inside `.git/` so it is never committed and is scoped per-repo.

Each entry contains:

- `timestamp` (ISO-8601 UTC), `sha` / `short_sha`, `branch`, `author_name`, `author_email`
- `verdict` — `PASS` / `FAIL` / `ERROR` / `TIMEOUT`
- `findings[]` — structured `{priority, title, waive_key, waived}` per `[P1]`/`[P2]`/`[P3]` line Codex reported, plus `finding_count`, `blocking_count` (unwaived P1/P2 only), and `waived_count`
- `review_prose` — the full Codex review text (truncated to 2000 chars)
- `codex_exit`, `duration_seconds`, `plugin_version`

Inspect with `jq`:

```bash
# Last 5 verdicts + finding counts in the current repo
tail -5 .git/codex-reviews.jsonl | jq -c '{short_sha, verdict, blocking_count}'

# Find when a specific commit was reviewed
jq -c 'select(.short_sha == "abc12345")' .git/codex-reviews.jsonl

# All FAIL verdicts with their blocking titles
jq 'select(.verdict == "FAIL") | {short_sha, titles: [.findings[].title]}' .git/codex-reviews.jsonl
```

To reset history, `rm .git/codex-reviews.jsonl`. Nothing in the plugin relies on this file — it's write-only from the hook's perspective.

## Parser: structured JSONL

Under the hood, the post-commit hook invokes `codex exec review --json` and parses the `agent_message` event from Codex's JSONL event stream. This replaces the earlier sed/grep text-scraping that produced false positives. If your Codex CLI is older and ignores `--json`, the hook falls back to the legacy text parser and still works — upgrade when convenient.

## Development

`bats tests` runs the test suite (35 tests, stub Codex CLI — no API calls). CI runs shellcheck plus the suite on Linux and macOS.

## Troubleshooting

- **Stuck in a fix loop / Stop hook keeps blocking** — interrupt Claude (Ctrl-C), then `rm -f .git/codex-review-state .git/codex-review-loop-count` in the repo, or `touch .git/codex-review-skip`. (Stale state from an abandoned loop also clears itself: see State files.)
- **Review timed out** — Codex exceeded `CODEX_REVIEW_TIMEOUT` (600s). The commit is not blocked; the timeout is logged to the history file. Re-check with `/codex-review`, break the commit up, or raise the variable (up to the 900s hook ceiling).
- **Codex not found** — `command -v codex` returns empty. Install with `npm install -g @openai/codex`, or set `CODEX_BIN=/path/to/codex`.
- **Codex auth failure on review** — run `codex login` or export `OPENAI_API_KEY`. Auth failures don't block commits; they're logged as `ERROR`.
- **Review keeps blocking on a finding you disagree with** — `/codex-review-waive` suppresses it permanently for the repo (see Waiving findings). For a systematic false-positive pattern, file an issue with the verbatim Codex output.
- **Review keeps failing on obviously clean commits** — file an issue with the verbatim Codex output. As a workaround, `touch .git/codex-review-skip`.
- **Every review times out** — check for a misbehaving Codex MCP server. Run `codex exec review --json --commit HEAD --full-auto 2>/dev/null | jq -c 'select(((.type // "") + "/" + (.item.type // "")) | test("mcp"; "i"))'` — the filter scopes to event/item type fields (ignores prose or diff text that merely mentions MCP) and tolerates schema variation across Codex versions. Look for an event that starts but never completes. If you spot one, temporarily comment out the offending `[mcp_servers.<name>]` block in `~/.codex/config.toml` and retry.
- **Reset review history** — `rm .git/codex-reviews.jsonl` in the affected repo.

## Uninstall

```text
/plugin uninstall codex-review@andreidavid
/plugin marketplace remove andreidavid
```

If any stale state markers remain in projects you used the plugin in:

```
rm -f .git/codex-review-state .git/codex-review-loop-count .git/codex-review-skip .git/codex-review-waived
rm -f .codex-review-state .codex-review-loop-count   # pre-1.4.0 locations
```
