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

## What this plugin adds

- **Slash command** `/codex-review` — on-demand review of a specific commit, uncommitted changes, or a branch diff. Arguments: `[--commit <sha>] [--uncommitted] [--base <branch>]`.
- **Skill** `codex-review` — invoked when you ask Claude to "review my changes", "run a codex review", etc.
- **PostToolUse hook** — after every successful `git commit` made via the Bash tool, Codex reviews the new commit. `[P1]`/`[P2]` findings block Claude and instruct it to fix and re-commit.
- **Stop hook** — keeps Claude iterating through the fix/re-commit cycle until the review passes, capped at `CODEX_REVIEW_MAX_LOOPS` iterations (default 5).

> **Scope:** only commits that Claude itself makes via the Bash tool trigger the review. Commits you run in your own terminal (outside a Claude Code session) are not reviewed — the hook has no visibility into them. Use the `/codex-review` slash command or the skill to review those on demand.
>
> The PostToolUse hook is registered for every Bash tool call; a fast filter inside the script lets unrelated calls fall through in milliseconds, and only successful `git commit` commands escalate to running Codex.

## Cost and latency

Each triggered review is one Codex API call billed to your OpenAI account. The Stop-hook fix loop can run up to `CODEX_REVIEW_MAX_LOOPS` reviews per blocked session (default 5). The hook has a 300-second timeout per review; very large commits may hit it — use `/codex-review` on smaller slices in that case.

If you're about to do a run of experimental or throwaway commits, bypass the plugin with `export CODEX_REVIEW_SKIP=1` for that session.

## Configuration

Environment variables:

| Variable | Default | Effect |
|---|---|---|
| `CODEX_REVIEW_SKIP` | *unset* | If set to any non-empty value, both hooks no-op. Per-session kill switch. |
| `CODEX_REVIEW_MAX_LOOPS` | `5` | Max iterations of the fix-and-recommit loop before the Stop hook lets Claude end the turn. |
| `CODEX_BIN` | `$(command -v codex)` | Override path to the Codex binary. |
| `CODEX_REVIEW_MAX_OUTPUT` | `8000` | Max characters of review output surfaced back to Claude. |

To disable the plugin for a whole session without uninstalling, use `/plugin disable codex-review@andreidavid`.

## State files

The hooks write small markers into the repo's working tree during a review cycle:

- `.codex-review-state` — current verdict (`RUNNING` / `FAIL` / `ERROR` / `TIMEOUT`)
- `.codex-review-loop-count` — fix-loop counter

Add them to the `.gitignore` of any project you use the plugin in:

```
.codex-review-state
.codex-review-loop-count
```

## Troubleshooting

- **Stuck in a fix loop / Stop hook keeps blocking** — interrupt Claude (Ctrl-C), then `rm -f .codex-review-state .codex-review-loop-count` in the repo root. Or set `CODEX_REVIEW_SKIP=1` for the rest of the session.
- **"Hook timed out" message** — Codex exceeded the 300-second limit. Try `/codex-review` on a smaller slice, or break the commit up.
- **Codex not found** — `command -v codex` returns empty. Install with `npm install -g @openai/codex`, or set `CODEX_BIN=/path/to/codex`.
- **Codex auth failure on review** — run `codex login` or export `OPENAI_API_KEY`.
- **Review keeps failing on obviously clean commits** — file an issue with the verbatim Codex output. As a workaround, `rm .codex-review-state` and set `CODEX_REVIEW_SKIP=1`.

## Uninstall

```text
/plugin uninstall codex-review@andreidavid
/plugin marketplace remove andreidavid
```

If any stale state markers remain in projects you used the plugin in:

```
rm -f .codex-review-state .codex-review-loop-count
```
