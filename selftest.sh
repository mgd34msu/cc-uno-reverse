#!/usr/bin/env bash
# cc-uno-reverse -- end-to-end self test.
#
# Proves the whole chain without ending a real session, and without touching any real
# state: it runs the installed watcher against a throwaway state directory, a throwaway
# transcript directory, and its own uniquely-named tmux session, all removed afterwards.
#
# Isolation matters for more than tidiness -- the watcher takes a lock so concurrent
# copies cannot pile up, so a test sharing live state gets locked out by whatever watcher
# your real session just scheduled, and silently proves nothing.
#
#   ./selftest.sh                     full test, including auto-resume
#   CCUNO_DISABLE_TMUX=1 ./selftest.sh   recovery-only path (what a machine without tmux does)
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CCUNO_INSTALL_DIR:-$HOME/.claude/cc-uno-reverse}"
WATCHER="$INSTALL_DIR/hooks/restore-ended-session.sh"
[ -x "$WATCHER" ] || WATCHER="$SRC/hooks/restore-ended-session.sh"

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ccuno-selftest-XXXXXX")"
FAKE="ccuno-selftest-$$"
TMUXSESS="ccuno-selftest-$$"

# Point every path at the sandbox. The watcher sources config.sh, which honours these.
export CCUNO_STATE_DIR="$SANDBOX/state"
export CCUNO_LOG="$SANDBOX/state/activity.log"
export CCUNO_PROJECTS_GLOB="$SANDBOX/projects/*/*.jsonl"
export CCUNO_SETTLE="${CCUNO_SETTLE:-2}"
export CCUNO_DISABLE_TMUX="${CCUNO_DISABLE_TMUX:-0}"

PROJDIR="$SANDBOX/projects/selftest"
TRANSCRIPT="$PROJDIR/$FAKE.jsonl"
FAIL=0
ok()   { printf '  PASS  %s\n' "$1"; }
bad()  { printf '  FAIL  %s\n' "$1"; FAIL=1; }
skip() { printf '  SKIP  %s\n' "$1"; }

cleanup() { rm -rf "$SANDBOX"; tmux kill-session -t "$TMUXSESS" 2>/dev/null; }
trap cleanup EXIT

echo "cc-uno-reverse self test"
echo "  watcher : $WATCHER"
echo "  sandbox : $SANDBOX"
echo

mkdir -p "$PROJDIR" "$CCUNO_STATE_DIR/panes"

# --- 1. optional throwaway pane (auto-resume half only) --------------------------------
HAVE_TMUX=0; PANE=""; PTY=""
if [ "$CCUNO_DISABLE_TMUX" != 1 ] && command -v tmux >/dev/null 2>&1 \
   && tmux new-session -d -s "$TMUXSESS" 2>/dev/null; then
  read -r PANE PTY <<< "$(tmux list-panes -t "$TMUXSESS" -F '#{pane_id} #{pane_tty}')"
  if [ -n "$PANE" ]; then
    HAVE_TMUX=1
    printf '%s %s 0\n' "$PANE" "${PTY#/dev/}" > "$CCUNO_STATE_DIR/panes/$FAKE"
    ok "created throwaway pane $PANE ($PTY)"
  fi
fi
[ "$HAVE_TMUX" = 1 ] || skip "auto-resume half not exercised (recovery-only mode)"

# --- 2. plant a genuine marker ---------------------------------------------------------
printf '{"type":"assistant","note":"before"}\n{"type":"ended-by-model","timestamp":"2000-01-01T00:00:00.000Z","sessionId":"%s"}\n{"type":"system","note":"after"}\n' "$FAKE" > "$TRANSCRIPT"
BEFORE=$(stat -c%s "$TRANSCRIPT")
ok "planted marker ($BEFORE bytes)"

# --- 3. run the watcher ----------------------------------------------------------------
START=$(date +%s)
timeout 60 bash "$WATCHER"
ELAPSED=$(( $(date +%s) - START ))

# --- 4. assertions ---------------------------------------------------------------------
AFTER=$(stat -c%s "$TRANSCRIPT")
[ "$AFTER" = "$BEFORE" ] && ok "file size unchanged ($AFTER bytes)" \
                         || bad "file size changed: $BEFORE -> $AFTER"

grep -q '"ended-by-model"' "$TRANSCRIPT" && bad "marker still present" \
                                         || ok "marker cleared"
grep -q 'x-cleared-mark'   "$TRANSCRIPT" && ok "replaced with inert record" \
                                         || bad "no replacement record"
grep -q '"note":"before"'  "$TRANSCRIPT" && grep -q '"note":"after"' "$TRANSCRIPT" \
  && ok "records either side intact" || bad "surrounding records damaged"

if [ "$HAVE_TMUX" = 1 ]; then
  sleep 1
  if tmux capture-pane -p -t "$PANE" 2>/dev/null | grep -q "$FAKE"; then
    ok "resume command landed in the target pane (${ELAPSED}s)"
  else
    bad "resume command never reached the pane"
  fi
else
  grep -q "recovered $FAKE" "$CCUNO_LOG" 2>/dev/null \
    && ok "logged as recovered, resume left to the operator" \
    || bad "recovery-only path did not log the recovery"
fi

echo
if [ "$FAIL" = 0 ]; then echo "all checks passed"; else echo "SOME CHECKS FAILED"; fi
exit $FAIL
