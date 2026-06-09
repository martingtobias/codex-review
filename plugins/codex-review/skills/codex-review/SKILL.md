---
name: codex-review
description: Use when the user asks to "review code with codex", "run a codex review", "review my changes", "review this commit", "review my branch", or wants OpenAI Codex to review code changes. Provides automated code review using the Codex CLI.
allowed-tools: Bash, Read
---

# Codex Code Review

Run automated code reviews using OpenAI Codex CLI (`codex exec review`).

This skill is the single source of truth for the on-demand review workflow;
the `/codex-review` slash command delegates here.

## Codex Binary

Honor `$CODEX_BIN` if set; otherwise the `codex` binary must be on `$PATH`.
See the plugin README for installation. All invocations below use
`"${CODEX_BIN:-codex}"`.

## Review Modes

### Review a specific commit

```bash
"${CODEX_BIN:-codex}" exec review --commit <SHA> --full-auto
```

### Review uncommitted changes (staged + unstaged + untracked)

```bash
"${CODEX_BIN:-codex}" exec review --uncommitted --full-auto
```

### Review branch diff against a base branch

```bash
"${CODEX_BIN:-codex}" exec review --base <branch> --full-auto
```

**Note:** `--commit`, `--uncommitted`, and `--base` are mutually exclusive
with custom prompt arguments. Codex uses its own built-in review logic.

## Argument Mapping

Whether invoked via `/codex-review <args>` or natural language, map the
request to a mode like this:

- Nothing specified → review the latest commit: `--commit $(git rev-parse HEAD)`
- A commit SHA (bare or via `--commit <sha>`) → `--commit <sha>`
- `--uncommitted`, or the user says "working changes" / "uncommitted" → `--uncommitted`
- `--base <branch>`, or the user names a base branch → `--base <branch>`

## Workflow

1. Determine what to review (see Argument Mapping above)

2. Run the codex review command

3. Parse the output for issues:
   - **[P1]/[P2] issues found** - Present the issues. Offer to fix them.
   - **No issues** - Report that the review passed. Offer to push if appropriate.
   - **Error** - Show the raw output and let the user decide.

4. If issues are found and the user wants fixes:
   - Fix the identified issues
   - Create a new commit with the fixes
   - The post-commit hook will automatically trigger another Codex review
   - Repeat until PASS

## Output Format

Codex review outputs structured comments with priority levels:
- **[P1]** - Critical issues (bugs, crashes, security)
- **[P2]** - Important issues (edge cases, incorrect logic)
- **[P3]** - Minor issues (style, naming)

The hook considers [P1] and [P2] issues as failures requiring fixes.
