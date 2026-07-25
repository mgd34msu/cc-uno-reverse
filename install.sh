#!/usr/bin/env bash
# cc-uno-reverse -- installer. Idempotent: safe to re-run after editing anything.
#
#   ./install.sh              install into ~/.claude/cc-uno-reverse and wire the hooks
#   ./install.sh --dry-run    show what would change, touch nothing
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${CCUNO_INSTALL_DIR:-$HOME/.claude/cc-uno-reverse}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say() { printf '  %s\n' "$1"; }

echo "cc-uno-reverse installer"
say "source   : $SRC"
say "install  : $INSTALL_DIR"
say "settings : $SETTINGS"
echo

# --- preflight ------------------------------------------------------------------------
# Required: recovery itself is a file operation and needs nothing else.
MISSING=""
for c in python3 flock awk; do
  command -v "$c" >/dev/null 2>&1 || MISSING="$MISSING $c"
done
if [ -n "$MISSING" ]; then
  echo "missing required commands:$MISSING"
  [ "$DRY" = 1 ] || exit 1
fi

# Optional: tmux is only needed to type the resume command back for you.
if ! command -v tmux >/dev/null 2>&1; then
  say "tmux not found -- installing in RECOVERY-ONLY mode."
  say "  ended sessions are still repaired and stay resumable;"
  say "  you type /resume <session-id> yourself instead of it appearing."
elif [ -z "${TMUX:-}" ]; then
  say "note: tmux is installed but this shell is not inside it. Auto-resume applies"
  say "      per session -- only sessions running in a tmux pane get typed back in."
fi

if [ "$DRY" = 1 ]; then
  say "would copy hooks/ and lib/ to $INSTALL_DIR"
  say "would add 2 PostToolUse entries to $SETTINGS"
  exit 0
fi

# --- files ----------------------------------------------------------------------------
mkdir -p "$INSTALL_DIR"
cp -r "$SRC/hooks" "$SRC/lib" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR"/hooks/*.sh
say "installed scripts"

# --- settings -------------------------------------------------------------------------
python3 - "$SETTINGS" "$INSTALL_DIR" <<'PY'
import json, os, shutil, sys, time

settings, install_dir = sys.argv[1], sys.argv[2]

if os.path.exists(settings):
    shutil.copy2(settings, settings + ".bak-ccuno-" + time.strftime("%Y%m%d%H%M%S"))
    with open(settings) as h:
        data = json.load(h)
else:
    os.makedirs(os.path.dirname(settings), exist_ok=True)
    data = {}

hooks = data.setdefault("hooks", {})
post  = [e for e in hooks.get("PostToolUse", []) if "cc-uno-reverse" not in json.dumps(e)]

post.append({"hooks": [{"type": "command",
                        "command": install_dir + "/hooks/record-session-pane.sh",
                        "timeout": 10}]})
post.append({"hooks": [{"type": "command",
                        "command": install_dir + "/hooks/restore-ended-session.sh",
                        "async": True,
                        "timeout": 90}]})
hooks["PostToolUse"] = post

with open(settings, "w") as h:
    json.dump(data, h, indent=2)
    h.write("\n")
print("  wired 2 PostToolUse hooks (backup written alongside settings.json)")
PY

python3 -c "import json,sys; json.load(open('$SETTINGS'))" \
  && say "settings.json parses cleanly"

echo
echo "done. verify with:  $SRC/selftest.sh"
echo "settings changes are picked up live -- no restart needed."
