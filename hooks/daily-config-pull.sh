#!/usr/bin/env bash
# Pull ~/.claude from origin once per calendar day, on the first session that starts.
# Wired up as a SessionStart hook in settings.json.
#
# Deliberate choices:
#   - The stamp lives in cache/ so it stays machine-local (git-ignored, never synced).
#   - Dirty tree or failed pull does NOT stamp, so the next session retries instead of
#     silently skipping until tomorrow.
#   - --ff-only: never invents a merge commit behind your back.

CONFIG_DIR="$HOME/.claude"
STAMP="$CONFIG_DIR/cache/.last-config-pull"
TODAY=$(date +%F)

# Only act on a real checkout.
[ -d "$CONFIG_DIR/.git" ] || exit 0

# Already pulled today.
[ "$(cat "$STAMP" 2>/dev/null)" = "$TODAY" ] && exit 0

msg() {
  clean=$(printf '%s' "$1" | tr '\n\r"\\' '    ' | cut -c1-300)
  printf '{"systemMessage":"%s","suppressOutput":true}\n' "$clean"
}

# Never clobber work in progress.
if ! git -C "$CONFIG_DIR" diff --quiet HEAD 2>/dev/null; then
  msg "~/.claude has uncommitted changes - skipped the daily config pull."
  exit 0
fi

before=$(git -C "$CONFIG_DIR" rev-parse --short HEAD 2>/dev/null)
out=$(GIT_TERMINAL_PROMPT=0 git -C "$CONFIG_DIR" pull --ff-only --quiet origin main 2>&1)
status=$?
after=$(git -C "$CONFIG_DIR" rev-parse --short HEAD 2>/dev/null)

if [ $status -ne 0 ]; then
  # Offline, diverged, or auth needed. No stamp: try again next session.
  msg "Daily ~/.claude config pull failed: $out"
  exit 0
fi

mkdir -p "$(dirname "$STAMP")"
printf '%s\n' "$TODAY" > "$STAMP"

if [ "$before" != "$after" ]; then
  msg "Pulled ~/.claude config updates ($before..$after). Restart Claude Code to apply settings changes."
fi

exit 0
