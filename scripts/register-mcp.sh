#!/bin/sh
# Registers pixelorama-mcp (user scope) with Claude Code and/or Grok CLI.
# Usage: scripts/register-mcp.sh [claude] [grok]   (no arguments = both that are installed)
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
UV=$(command -v uv)
TARGETS=${*:-"claude grok"}

for target in $TARGETS; do
  case "$target" in
    claude)
      command -v claude >/dev/null || { echo "claude not installed, skipping"; continue; }
      claude mcp add --scope user pixelorama -- "$UV" run --quiet --directory "$ROOT/mcp" pixelorama-mcp
      ;;
    grok)
      command -v grok >/dev/null || { echo "grok not installed, skipping"; continue; }
      grok mcp add --scope user pixelorama "$UV" -- run --quiet --directory "$ROOT/mcp" pixelorama-mcp
      ;;
    *) echo "unknown target: $target"; exit 1 ;;
  esac
done
