---
description: Run a Codex review on a Claude Code plan file
argument-hint: "[path-to-plan.md]"
allowed-tools: [Bash, Read]
---

# Codex Plan Review

The user invoked this command with: $ARGUMENTS

## Instructions

Review a Claude Code plan file with OpenAI Codex. The flow is on-demand and non-blocking — unlike the post-commit hook, it operates on markdown prose in `~/.claude/plans/` rather than a git diff.

### 1. Resolve the plan path

Parse `$ARGUMENTS`:

- **No argument** — pick the most-recently-modified plan file:
  ```bash
  ls -t ~/.claude/plans/*.md 2>/dev/null | head -1
  ```
  If the directory is empty or missing, tell the user "No plan files in `~/.claude/plans/`." and stop.

- **Argument contains `/`** — treat as an absolute path (or relative to the current working directory). Expand `~` yourself.

- **Bare filename** (no `/`) — resolve against `~/.claude/plans/<arg>`. Append `.md` if no extension.

Before proceeding, verify the resolved path exists and is non-empty:
```bash
[ -s "<PATH>" ] || { echo "Plan file <PATH> does not exist or is empty"; exit 1; }
```

If the file doesn't exist, tell the user the path you checked and stop without running Codex.

### 2. Run Codex against the plan

Invoke (honor `$CODEX_BIN` the same way the post-commit hook does, and pass `--skip-git-repo-check` so reviewing a plan works from any directory — scratch folders, non-git trees, etc.):

```bash
"${CODEX_BIN:-codex}" exec --full-auto --skip-git-repo-check "Review the implementation plan at <PATH>. Read it fully, then critique from these angles: missing steps or gaps; design flaws or wrong-architecture choices; scope creep or under-scoping; risks and unhandled edge cases; verification that's insufficient or missing. Format findings using priorities: [P1] = critical (the plan will fail or produce wrong outcomes as written), [P2] = important (will cause rework), [P3] = advisory. If nothing material is wrong, say so explicitly."
```

Notes:

- Substitute the resolved `<PATH>` literally into the prompt so Codex can read the file from its sandbox.
- `--full-auto` runs sandboxed and non-interactive, matching the post-commit hook.
- `--skip-git-repo-check` is required because Codex aborts in non-repo / untrusted-dir contexts by default; plan review has no git dependency so always skip the check.
- Do **not** pass `--json` — this command is interactive; the user reads the prose directly.
- Expect 30–120 seconds for a moderate plan; complex plans can take longer.

### 3. Present the review

Report to the user in this order:

1. Which plan file was resolved (absolute path).
2. Codex's verbatim output.
3. A short summary line:
   - `[P1]`/`[P2]` findings present → recommend revising the plan before implementation begins.
   - Only `[P3]` findings → note them as advisory; the plan can proceed with these in mind.
   - No findings → report that Codex approved the plan.

Do **not** edit the plan file yourself. Revisions go through the user (who can re-enter plan mode or ask you to adjust the plan).

## Errors

- `codex` not on `$PATH` → tell the user to install it (`npm install -g @openai/codex`) or set `CODEX_BIN`, then retry.
- `codex exec` non-zero exit → show the raw output and let the user decide (likely a Codex auth or rate-limit issue).
