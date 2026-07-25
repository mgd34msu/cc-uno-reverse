# cc-uno-reverse

Claude Code can end its own session. When it does, the conversation becomes unresumable —
`/resume` refuses to open it, and whatever was in flight is stranded.

This puts it back. Automatically, in about a second and a half, in the same terminal pane,
with the full history intact.

```
20:47:52.505  model ends the session, marker written
20:47:52      marker cleared
20:47:54      /resume <session-id> typed back into pane %140
```

## What actually happens when a session ends

Each session is an append-only JSONL transcript at
`~/.claude/projects/<project>/<session-id>.jsonl`. Ending it appends exactly **one**
record:

```json
{"type":"ended-by-model","timestamp":"...","sessionId":"..."}
```

116 bytes. That single record is the entire lock — nothing is deleted, nothing is
truncated, the whole conversation is still sitting there. `/resume` just refuses to open a
file containing it.

Subagents are not killed either. They keep writing to `<session-id>/subagents/agent-*.jsonl`.
The thing that actually destroys in-flight work is killing the CLI process to "clean up".
Don't.

## How this fixes it

Two `PostToolUse` hooks:

| Hook | Mode | Job |
|---|---|---|
| `record-session-pane.sh` | synchronous, ~10ms | records `session id → tmux pane` |
| `restore-ended-session.sh` | async | clears the marker, types `/resume <id>` |

The watcher polls for a marker, overwrites it **in place** with an equal-length inert
record (`x-cleared-mark`), then looks up which pane that session lives in and sends the
resume command with `tmux send-keys`.

## Four things that are easy to get wrong

**Blocking does not work.** The obvious fix is a `PreToolUse` hook that denies the tool.
It never fires — `EndConversation` is not routed through `PreToolUse`, and permission
`deny` rules do not apply to it either. A `PreToolUse` deny on an ordinary tool (tested
with `Read`) works fine, so the hook system is not at fault; this tool simply bypasses that
layer. `PostToolUse` **does** fire for it, which is the whole basis of this approach: the
end call schedules the very watcher that undoes it.

**Do not delete the marker line.** The CLI reopens the transcript in append mode. Removing
bytes shifts every later offset, and the next append lands in the wrong place and corrupts
the file. The record is overwritten in place at a fixed offset with a byte-identical
length, so the file size never changes. The self test asserts this.

**Async hooks get a stripped environment.** `CLAUDE_CODE_SESSION_ID` is unset there, so the
watcher cannot know its own identity. That is why a synchronous hook records the pane
mapping to disk and the watcher acts on what it cleared — the transcript filename *is* the
session id.

**Pane ids get reused.** Before typing anything, the watcher checks the pane still exists
*and* still carries the tty it was recorded with. If a pane was closed and its id handed to
something else, it logs and refuses rather than typing into a stranger's shell.

## Install

```bash
git clone <this repo> ~/Projects/cc-uno-reverse
cd ~/Projects/cc-uno-reverse
./install.sh          # or --dry-run first
./selftest.sh         # proves the whole chain, ends nothing
```

**Required:** `python3`, `flock`, `awk`. **Optional:** `tmux`.

Recovery — the part that makes an ended session resumable again — is a file operation and
needs nothing but python3. tmux is only needed for the convenience half: typing the resume
command back into your terminal for you. Without it the installer says so and runs in
recovery-only mode; ended sessions are still repaired and you run `/resume <id>` yourself.
Force that mode anywhere with `CCUNO_DISABLE_TMUX=1`.

Settings changes are picked up live — no restart. Installs to `~/.claude/cc-uno-reverse`,
backs up `settings.json` first.

Removal: `./uninstall.sh` (add `--purge` to drop state too).

## Configuration

Everything tunable lives in `lib/config.sh`. Nothing is hardcoded — session ids, panes,
ttys, pids and paths are all resolved at runtime.

| Setting | Default | Meaning |
|---|---|---|
| `CCUNO_POLL_WINDOW` | `15` | how long a watcher polls after a tool call |
| `CCUNO_POLL_INTERVAL` | `0.5` | how often it looks |
| `CCUNO_SETTLE` | `2` | pause before typing, so the prompt is ready |
| `CCUNO_RATE_LIMIT` | `60` | min seconds between resumes of one session |
| `CCUNO_FRESH` | `180` | ignore transcripts untouched longer than this |
| `CCUNO_TAIL_BYTES` | `262144` | how much of the file tail to scan |
| `CCUNO_REGISTRY_REFRESH` | `300` | how often a session re-records its pane |
| `CCUNO_RESUME_CMD` | `/resume %s` | the command typed back in |
| `CCUNO_DISABLE_TMUX` | `0` | `1` = repair only, never type into a terminal |

`CCUNO_SETTLE` is the one to leave alone. Too short and the keystrokes arrive before the
prompt exists.

## Cost

The synchronous hook is a stat and an exit on the common path — 10ms, measured. The async
watcher holds a lock so watchers cannot pile up, reads only the last 256 KB of transcripts
touched in the last few minutes, and exits silently when there is nothing to clear, which
is almost always.

## Limits

- **Auto-resume needs tmux; recovery does not.** `send-keys` is the only way to inject
  into a running TUI, so without tmux you get a repaired, resumable session and type
  `/resume <id>` yourself. The two halves are independent by design.
- **The end still happens.** Nothing here prevents it. The session is restored after the
  fact, not protected from ending.
- **`x-cleared-mark`** is an unrecognised record type, chosen because it is exactly the
  same length as `ended-by-model`. It is skipped by the parser.
- This reads and writes an undocumented on-disk format. A future Claude Code release could
  change the record shape, at which point the self test is how you find out.

## Verifying

```bash
./selftest.sh                        # full chain, including auto-resume
CCUNO_DISABLE_TMUX=1 ./selftest.sh   # recovery-only path, as on a machine without tmux
```

It proves the chain without ending a real session and without touching real state: a
throwaway state directory, a throwaway transcript directory, and a uniquely-named tmux
session, all removed afterwards. It asserts the marker was cleared, the file size is
unchanged, the records either side survived, and the resume command actually reached the
target pane.

The isolation is load-bearing, not tidiness: the watcher takes a lock so concurrent copies
cannot pile up, so a test sharing live state gets locked out by whatever watcher your real
session just scheduled — and silently proves nothing while appearing to pass.

Activity is logged to `~/.local/state/cc-uno-reverse/activity.log` — every clear, every
send, and every refusal with its reason.
