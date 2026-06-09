---
description: Run a Codex code review on commits, branches, or uncommitted changes
argument-hint: [--commit <sha>] [--uncommitted] [--base <branch>]
allowed-tools: [Bash, Read]
---

# Codex Code Review

The user invoked this command with: $ARGUMENTS

Read `${CLAUDE_PLUGIN_ROOT}/skills/codex-review/SKILL.md` (this plugin's
`codex-review` skill — the single source of truth for the review workflow)
and follow it, mapping `$ARGUMENTS` per its "Argument Mapping" section.

Quick reference if the skill file is unavailable: run
`"${CODEX_BIN:-codex}" exec review --full-auto` with exactly one of
`--commit <sha>` (default: HEAD), `--uncommitted`, or `--base <branch>`,
then report [P1]/[P2] findings and offer to fix; on a clean review offer
to push.
