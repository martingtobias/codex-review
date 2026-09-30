---
description: Set the sandbox policy for automatic Codex reviews
argument-hint: "[workspace-write|danger-full-access|bypass|status]"
allowed-tools: [Bash]
---

The user invoked this command with: $ARGUMENTS

Use `status` when no argument was given. Accept only `workspace-write`, `danger-full-access`, `bypass`, or `status`.

Run `${CLAUDE_PLUGIN_ROOT}/scripts/configure-sandbox-mode.sh` with the selected value as its only argument. Report its output. Do not change any other setting.
