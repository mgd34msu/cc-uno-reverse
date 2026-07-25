#!/usr/bin/env bash
# cc-uno-reverse -- tunables. Sourced by both hooks.
#
# Edit these in the installed copy (see INSTALL_DIR in install.sh); the hooks read this
# file from their own directory, so async hooks pick it up despite a stripped environment.

# Where transcripts live. The session id is the filename stem.
CCUNO_PROJECTS_GLOB="${CCUNO_PROJECTS_GLOB:-$HOME/.claude/projects/*/*.jsonl}"

# State: session -> pane registry, resume stamps, watcher lock, log.
CCUNO_STATE_DIR="${CCUNO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-uno-reverse}"
CCUNO_LOG="${CCUNO_LOG:-$CCUNO_STATE_DIR/activity.log}"

# How long the watcher polls for a marker after a tool call, and how often it looks.
# The end call schedules its own watcher, so detection is normally sub-second.
CCUNO_POLL_WINDOW="${CCUNO_POLL_WINDOW:-15}"
CCUNO_POLL_INTERVAL="${CCUNO_POLL_INTERVAL:-0.5}"

# Pause between clearing the marker and typing, so the CLI is ready to receive input.
# Lower this at your own risk: too short and the keystrokes land before the prompt exists.
CCUNO_SETTLE="${CCUNO_SETTLE:-2}"

# Never re-resume the same session twice inside this window (anti-spin).
CCUNO_RATE_LIMIT="${CCUNO_RATE_LIMIT:-60}"

# Ignore transcripts untouched for longer than this.
CCUNO_FRESH="${CCUNO_FRESH:-180}"

# How much of the file tail to inspect. The marker is appended at the end.
CCUNO_TAIL_BYTES="${CCUNO_TAIL_BYTES:-262144}"

# How often the synchronous recorder refreshes a session's pane mapping.
CCUNO_REGISTRY_REFRESH="${CCUNO_REGISTRY_REFRESH:-300}"

# The command typed back into the pane. %s is replaced with the session id.
CCUNO_RESUME_CMD="${CCUNO_RESUME_CMD:-/resume %s}"

# Recovery-only mode. Set to 1 to repair ended sessions but never type anything into a
# terminal -- you run /resume <id> yourself. Also what happens automatically when tmux
# is not installed. Recovery itself never needs tmux.
CCUNO_DISABLE_TMUX="${CCUNO_DISABLE_TMUX:-0}"
