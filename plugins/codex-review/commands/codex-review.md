---
description: Run a Codex code review on commits, branches, or uncommitted changes
argument-hint: [--commit <sha>] [--uncommitted] [--base <branch>]
allowed-tools: [Bash, Read]
---

# Codex Code Review

Run an automated code review using OpenAI Codex CLI.

## Arguments

The user invoked this command with: $ARGUMENTS

## Instructions

Parse the arguments to determine review mode:

1. **No arguments or a commit SHA**: Review a specific commit
   - No args: review HEAD (`git rev-parse HEAD`)
   - SHA provided: review that commit

2. **`--uncommitted`**: Review working tree changes (staged + unstaged + untracked)

3. **`--base <branch>`**: Review current branch diff against the given base branch

## Execution

Run the appropriate codex review command:

```bash
# For commit review (default):
codex exec review --commit <SHA> --full-auto

# For uncommitted changes:
codex exec review --uncommitted --full-auto

# For branch diff:
codex exec review --base <branch> --full-auto
```

**Note:** `--commit`, `--uncommitted`, and `--base` are mutually exclusive with custom prompt arguments.

## After Review

Codex outputs structured comments with priority levels ([P1], [P2], [P3]).

- **No [P1]/[P2] issues**: Report success. Ask if the user wants to push to GitHub.
- **[P1]/[P2] issues found**: Present the issues. Offer to fix them and re-commit.
- **Error**: Show the raw output and ask the user what to do.

If fixing issues, create a new commit after fixes. The post-commit hook will automatically trigger another review cycle.
