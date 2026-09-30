#!/usr/bin/env bash
set -euo pipefail

# Sandbox-mode toggle. Stores the user's choice in a plugin-owned file rather
# than pluginConfigs in settings.json, because pluginConfigs is keyed by the
# runtime plugin ID -- which differs per install channel (`<name>@<marketplace>`
# for marketplace installs, `<name>@inline`/`<name>-inline` for sideloads),
# is not exposed to hooks or commands as an env variable, and (per Claude
# Code docs) may not apply to --plugin-dir sideloads at all. A single state
# file works uniformly across every install channel.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/codex-review"
STATE_FILE="$CONFIG_DIR/sandbox-mode"

ACTION="${1:-status}"

case "$ACTION" in
  workspace-write|danger-full-access|bypass|status) ;;
  *)
    echo "Usage: configure-sandbox-mode.sh [workspace-write|danger-full-access|bypass|status]" >&2
    exit 2
    ;;
esac

# Mirror the precedence in post-commit-review.sh: state file wins when
# present; otherwise CLAUDE_PLUGIN_OPTION_SANDBOX_MODE from a marketplace-
# install pluginConfigs entry is honored; else default to workspace-write.
# Divergence here lets `status` lie -- reporting one mode while reviews
# actually run under another.
read_setting() {
  if [ -f "$STATE_FILE" ]; then
    cat "$STATE_FILE" 2>/dev/null
    return
  fi
  case "${CLAUDE_PLUGIN_OPTION_SANDBOX_MODE:-}" in
    workspace-write|danger-full-access|bypass)
      echo "$CLAUDE_PLUGIN_OPTION_SANDBOX_MODE"
      ;;
    *)
      echo workspace-write
      ;;
  esac
}

show_status() {
  MODE=$(read_setting)
  case "$MODE" in
    workspace-write)
      echo "Sandbox mode: workspace-write"
      echo "Codex arguments: --sandbox workspace-write"
      ;;
    danger-full-access)
      echo "Sandbox mode: danger-full-access"
      echo "Codex arguments: --sandbox danger-full-access"
      ;;
    bypass)
      echo "Sandbox mode: bypass"
      echo "Codex argument: --dangerously-bypass-approvals-and-sandbox"
      ;;
    *)
      echo "Sandbox mode: $MODE (invalid; using compatibility default)"
      echo "Codex arguments: --sandbox workspace-write"
      ;;
  esac
}

if [ "$ACTION" = "status" ]; then
  show_status
  echo "Available modes: workspace-write | danger-full-access | bypass"
  exit 0
fi

mkdir -p "$CONFIG_DIR"
printf '%s\n' "$ACTION" > "$STATE_FILE"

show_status
