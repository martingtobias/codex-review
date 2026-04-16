# codex-review

A Claude Code plugin that runs an automatic code review with OpenAI Codex CLI after every `git commit`. On `[P1]`/`[P2]` issues, Claude fixes and re-commits; on a clean review, you're prompted to push.

## Prerequisites

- **OpenAI Codex CLI** on `$PATH` — install via `npm install -g @openai/codex` (see https://github.com/openai/codex). Verify with `command -v codex`.
- `jq`, `git`, and `bash` available on `$PATH` (standard on macOS/Linux).
- Claude Code with plugins enabled.

## Install

```text
/plugin marketplace add <github-owner>/codex-review
/plugin install codex-review@codex-review
```

Replace `<github-owner>` with the GitHub user or org this repo is hosted under.

To pull updates after the repo changes:

```text
/plugin marketplace update codex-review
```

## What this plugin adds

- **Slash command** `/codex-review` — on-demand review of a specific commit, uncommitted changes, or a branch diff. Arguments: `[--commit <sha>] [--uncommitted] [--base <branch>]`.
- **Skill** `codex-review` — invoked when you ask Claude to "review my changes", "run a codex review", etc.
- **PostToolUse hook** — after any successful `git commit` made via the Bash tool, runs `codex exec review` on the new commit. If `[P1]`/`[P2]` issues are found, Claude is blocked and instructed to fix and re-commit.
- **Stop hook** — prevents Claude from stopping while a review failure is pending, with a safety valve capping the fix/commit loop at 5 iterations.

## State files

The hooks write small state files in the working directory of the project Claude is operating in:

- `.codex-review-state` — current review verdict (`FAIL` / `ERROR`)
- `.codex-review-loop-count` — fix-loop counter

Add these to your project's `.gitignore`:

```
.codex-review-state
.codex-review-loop-count
```

## Uninstall

```text
/plugin uninstall codex-review@codex-review
/plugin marketplace remove codex-review
```
