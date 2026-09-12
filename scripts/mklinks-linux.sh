#!/usr/bin/env bash
# Pre-create plugin symlinks on Linux hosts.
#
# Why: Flutter's _createPlatformPluginSymlinks calls link.createSync when
# link.existsSync() is false. On some setups that call fails intermittently and
# aborts `flutter build linux`. Creating the links here first makes existsSync()
# return true, so Flutter skips the create step.
#
# Usage:
#   ./scripts/mklinks-linux.sh [project-dir]

set -euo pipefail

PROJECT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DEPS="$PROJECT_DIR/.flutter-plugins-dependencies"

if [ ! -f "$DEPS" ]; then
  echo "missing $DEPS - run 'flutter pub get' first" >&2
  exit 1
fi

SL="$PROJECT_DIR/linux/flutter/ephemeral/.plugin_symlinks"
mkdir -p "$SL"

# Pull "name<TAB>path" pairs for the linux platform out of the JSON.
# python3 is the only portable way to parse JSON reliably here.
python3 - "$DEPS" "$SL" <<'PY'
import json
import os
import sys

deps_path, sl = sys.argv[1], sys.argv[2]

with open(deps_path, encoding="utf-8") as fh:
    data = json.load(fh)

plugins = (data.get("plugins") or {}).get("linux") or []
if not plugins:
    print("no linux plugins found")
    sys.exit(0)

for p in plugins:
    name = p["name"]
    target = p["path"].rstrip("/\\")
    link = os.path.join(sl, name)

    if not os.path.isdir(target):
        print(f"SKIP  {name} (no target)")
        continue
    if os.path.islink(link):
        print(f"KEEP  {name}")
        continue
    if os.path.exists(link):
        os.remove(link)

    os.symlink(target, link)
    print(f"LINK  {name}")

print(f"\n{len(plugins)} plugins -> {sl}")
PY
