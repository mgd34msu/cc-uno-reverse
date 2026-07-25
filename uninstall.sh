#!/usr/bin/env bash
# cc-uno-reverse -- uninstaller. Removes the hooks from settings.json and the installed
# scripts. Leaves state (registry + log) unless you pass --purge.
set -euo pipefail

INSTALL_DIR="${CCUNO_INSTALL_DIR:-$HOME/.claude/cc-uno-reverse}"
SETTINGS="${CLAUDE_SETTINGS:-$HOME/.claude/settings.json}"
STATE_DIR="${CCUNO_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/cc-uno-reverse}"
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

if [ -f "$SETTINGS" ]; then
  python3 - "$SETTINGS" <<'PY'
import json, shutil, sys, time
p = sys.argv[1]
shutil.copy2(p, p + ".bak-ccuno-uninstall-" + time.strftime("%Y%m%d%H%M%S"))
with open(p) as h:
    d = json.load(h)
hooks = d.get("hooks", {})
before = len(hooks.get("PostToolUse", []))
hooks["PostToolUse"] = [e for e in hooks.get("PostToolUse", [])
                        if "cc-uno-reverse" not in json.dumps(e)]
after = len(hooks["PostToolUse"])
if not hooks["PostToolUse"]:
    hooks.pop("PostToolUse")
if not hooks:
    d.pop("hooks", None)
with open(p, "w") as h:
    json.dump(d, h, indent=2)
    h.write("\n")
print("  removed %d hook entries from settings.json" % (before - after))
PY
fi

rm -rf "$INSTALL_DIR" && echo "  removed $INSTALL_DIR"

if [ "$PURGE" = 1 ]; then
  rm -rf "$STATE_DIR" && echo "  purged state at $STATE_DIR"
else
  echo "  state kept at $STATE_DIR (use --purge to remove)"
fi

echo "done."
