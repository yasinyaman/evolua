#!/usr/bin/env bash
# Reset EvoLua to a fresh, never-lived state: wipe all evolved organs, reports
# and memory. The organism regrows everything on next run.
#
#   ./clean.sh            # clean the OS data dir (binary mode) + local lua/ dir
#   EVOLUA_HOME=/path ./clean.sh   # clean a custom home
set -e
cd "$(dirname "$0")"

# resolve the same data home the binary uses
if [ -n "$EVOLUA_HOME" ]; then
  HOME_DIR="$EVOLUA_HOME"
elif [ "$(uname)" = "Darwin" ]; then
  HOME_DIR="$HOME/Library/Application Support/EvoLua"
else
  HOME_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/evolua"
fi

for base in "$HOME_DIR" "lua"; do
  [ -d "$base" ] || continue
  rm -f  "$base"/plugins/gen_*.lua 2>/dev/null || true
  rm -f  "$base"/reports/*.md       2>/dev/null || true
  rm -f  "$base"/state/*.lua "$base"/state/*.log 2>/dev/null || true
done
rm -rf evolua 2>/dev/null || true   # stray nested dir
echo "EvoLua reset — cleared organs/reports/memory in: $HOME_DIR and ./lua"
