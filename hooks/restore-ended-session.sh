#!/usr/bin/env bash
# cc-uno-reverse -- PostToolUse hook, ASYNC. The part that does the work.
#
#   1. polls briefly for an "ended-by-model" record in any recent transcript
#   2. overwrites that record in place, so the session stays resumable
#   3. types /resume <id> back into the exact tmux pane that session lives in
#
# Why after the fact rather than blocking: EndConversation is not routed through
# PreToolUse, and permission deny rules do not apply to it -- a PreToolUse deny hook on
# it never fires. PostToolUse DOES fire for it, so the end call schedules the very
# watcher that undoes it.
#
# This runs with a stripped environment and cannot know its own session id. It acts on
# whatever it cleared: the transcript filename IS the session id, and the synchronous
# recorder maintains the id -> pane registry.
#
# The marker is overwritten with an equal-length inert record so the file length never
# changes. The CLI reopens the transcript in append mode; shifting bytes would corrupt
# its write offset.

. "$(dirname "$(readlink -f "$0")")/../lib/config.sh"

PANES="$CCUNO_STATE_DIR/panes"
LOCK="$CCUNO_STATE_DIR/watcher.lock"
mkdir -p "$CCUNO_STATE_DIR" "$PANES"

note() { printf '%s %s\n' "$(date -Is)" "$1" >> "$CCUNO_LOG" 2>/dev/null || true; }

# Every tool call schedules a watcher; without this they would pile up. Whoever holds
# the lock is already polling, so a second one adds nothing.
exec 9>"$LOCK"
flock -n 9 || exit 0

# --- 1 + 2: poll, clear, print the session id of every transcript patched -------------
CLEARED=$(
  CCUNO_PROJECTS_GLOB="$CCUNO_PROJECTS_GLOB" \
  CCUNO_LOG="$CCUNO_LOG" \
  CCUNO_POLL_WINDOW="$CCUNO_POLL_WINDOW" \
  CCUNO_POLL_INTERVAL="$CCUNO_POLL_INTERVAL" \
  CCUNO_FRESH="$CCUNO_FRESH" \
  CCUNO_TAIL_BYTES="$CCUNO_TAIL_BYTES" \
  python3 - <<'PY'
import glob, os, time

OLD = b'"type":"ended-by-model"'
NEW = b'"type":"x-cleared-mark"'
assert len(OLD) == len(NEW), "replacement must be byte-identical in length"

GLOB     = os.path.expanduser(os.environ["CCUNO_PROJECTS_GLOB"])
LOG      = os.environ["CCUNO_LOG"]
WINDOW   = float(os.environ["CCUNO_POLL_WINDOW"])
INTERVAL = float(os.environ["CCUNO_POLL_INTERVAL"])
FRESH    = float(os.environ["CCUNO_FRESH"])
TAIL     = int(os.environ["CCUNO_TAIL_BYTES"])

def note(msg):
    try:
        with open(LOG, "a") as h:
            h.write(time.strftime("%Y-%m-%dT%H:%M:%S") + " " + msg + "\n")
    except Exception:
        pass

def sweep():
    hits = []
    now = time.time()
    for f in glob.glob(GLOB):
        try:
            if now - os.path.getmtime(f) > FRESH:
                continue
            size  = os.path.getsize(f)
            start = max(0, size - TAIL)
            with open(f, "rb") as h:
                h.seek(start)
                tail = h.read()
            if OLD not in tail:
                continue

            idx = tail.find(OLD)
            while idx != -1:
                off = start + idx
                with open(f, "r+b") as h:
                    h.seek(off)
                    if h.read(len(OLD)) == OLD:      # re-verify before writing
                        h.seek(off)
                        h.write(NEW)
                        h.flush()
                        os.fsync(h.fileno())
                        note("cleared %s @%d" % (f, off))
                        if f not in hits:
                            hits.append(f)
                idx = tail.find(OLD, idx + 1)
        except Exception as e:
            note("error on %s: %s" % (f, e))
    return hits

deadline = time.time() + WINDOW
while True:
    found = sweep()
    if found:
        for f in found:
            print(os.path.basename(f)[:-len(".jsonl")])
        break
    if time.time() >= deadline:
        break
    time.sleep(INTERVAL)
PY
)

[ -n "$CLEARED" ] || exit 0

# --- 3: put each ended session back, in its own pane ----------------------------------
# Everything above this line is the actual recovery and needs nothing but python3.
# What follows is the convenience half: typing the resume command back for you, which
# requires tmux. Without it the sessions are already repaired and resumable by hand.
if [ "$CCUNO_DISABLE_TMUX" = 1 ] || ! command -v tmux >/dev/null 2>&1; then
  while read -r SID; do
    [ -n "$SID" ] && note "recovered $SID (recovery-only mode: resume by hand)"
  done <<< "$CLEARED"
  exit 0
fi

while read -r SID; do
  [ -n "$SID" ] || continue

  REG="$PANES/$SID"
  if [ ! -f "$REG" ]; then
    note "resume skipped for $SID: no pane recorded"
    continue
  fi

  STAMP="$PANES/$SID.last-resume"
  NOW=$(date +%s)
  LAST=$(cat "$STAMP" 2>/dev/null || echo 0)
  if [ $((NOW - LAST)) -lt "$CCUNO_RATE_LIMIT" ]; then
    note "resume suppressed for $SID ($((NOW - LAST))s since last)"
    continue
  fi

  read -r PANE TTY _ < "$REG"

  # The pane must still exist AND still carry the tty we recorded. Pane ids are reused
  # after a pane closes; without the tty check we could type into a stranger's shell.
  LIVE=$(tmux list-panes -a -F '#{pane_id} #{pane_tty}' 2>/dev/null \
         | awk -v p="$PANE" '$1==p {print $2; exit}')
  if [ -z "$LIVE" ]; then
    note "resume skipped for $SID: pane $PANE no longer exists"
    continue
  fi
  if [ "$LIVE" != "/dev/$TTY" ]; then
    note "resume skipped for $SID: pane $PANE now $LIVE, expected /dev/$TTY"
    continue
  fi

  echo "$NOW" > "$STAMP"
  sleep "$CCUNO_SETTLE"
  CMD=$(printf "$CCUNO_RESUME_CMD" "$SID")
  if tmux send-keys -t "$PANE" "$CMD" Enter 2>/dev/null; then
    note "resume sent: $CMD -> pane $PANE ($LIVE)"
  else
    note "resume FAILED sending to pane $PANE for $SID"
  fi
done <<< "$CLEARED"
