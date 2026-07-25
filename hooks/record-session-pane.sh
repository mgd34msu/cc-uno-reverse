#!/usr/bin/env bash
# cc-uno-reverse -- PostToolUse hook, SYNCHRONOUS. Must stay fast (~10ms).
#
# Records which tmux pane this session lives in, so the async watcher can type into the
# right one later. This has to happen here: async hooks run with a stripped environment
# where CLAUDE_CODE_SESSION_ID is unset, so identity is captured here and handed over
# on disk.
#
# Refreshes at most once per CCUNO_REGISTRY_REFRESH seconds, so the common path is a
# single stat and an exit.

. "$(dirname "$(readlink -f "$0")")/../lib/config.sh"

SID="${CLAUDE_CODE_SESSION_ID:-}"
[ -n "$SID" ] || exit 0

DIR="$CCUNO_STATE_DIR/panes"
F="$DIR/$SID"

if [ -f "$F" ]; then
  AGE=$(( $(date +%s) - $(stat -c %Y "$F" 2>/dev/null || echo 0) ))
  [ "$AGE" -lt "$CCUNO_REGISTRY_REFRESH" ] && exit 0
fi

# tmux is the only supported target today; without it there is nothing to record.
[ "$CCUNO_DISABLE_TMUX" = 1 ] && exit 0
command -v tmux >/dev/null 2>&1 || exit 0

TTY=$(ps -o tty= -p "${CLAUDE_PID:-0}" 2>/dev/null | tr -d ' ')
[ -n "$TTY" ] && [ "$TTY" != "?" ] || exit 0

PANE=$(tmux list-panes -a -F '#{pane_tty} #{pane_id}' 2>/dev/null \
       | awk -v t="/dev/$TTY" '$1==t {print $2; exit}')
[ -n "$PANE" ] || exit 0

mkdir -p "$DIR"
printf '%s %s %s\n' "$PANE" "$TTY" "${CLAUDE_PID:-}" > "$F"
exit 0
