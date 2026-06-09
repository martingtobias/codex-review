# Contributing

Issues and pull requests are welcome.

## Development setup

Everything is bash + `jq`; no build step. You'll want:

- `jq`, `git`, `bash` (the hooks support macOS and Linux)
- [bats](https://github.com/bats-core/bats-core) for tests — `npx --yes bats tests` works without installing
- [shellcheck](https://www.shellcheck.net/) — `npx --yes shellcheck plugins/codex-review/hooks/scripts/*.sh`

Tests use a stub `codex` binary, so they run offline and make no API calls.

## Before opening a PR

- `npx --yes bats tests` passes (CI runs the suite on Linux and macOS)
- `shellcheck` is clean on the hook scripts (CI uses the distro shellcheck, which can be older and stricter than the latest release)
- Behavior changes come with a test and a `CHANGELOG.md` entry
- Keep the hook scripts dependency-free (bash + git + jq only) and portable across GNU/BSD userlands — no GNU-only regex or flag extensions

## Testing against the real Codex CLI

Install the plugin from your working copy with `claude --plugin-dir plugins/codex-review` (session-only), or point a test marketplace at your fork. This repo dogfoods itself: commits made via Claude Code in this repo are reviewed by the released version of the plugin.

## Reporting bugs

Include the plugin version (`jq .version plugins/codex-review/.claude-plugin/plugin.json`), your `codex --version`, the verbatim hook output, and — if relevant — the matching line from `.git/codex-reviews.jsonl`.
