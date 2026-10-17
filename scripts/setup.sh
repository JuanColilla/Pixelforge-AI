#!/bin/sh
# Prepares the local Pixelorama checkout with the AI Studio extension and the MCP server.
# Idempotent: safe to run again after pulling changes.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
PIXELORAMA_TAG="v1.2.3"
REQUIRED_GODOT="4.7"

command -v godot >/dev/null || { echo "Godot $REQUIRED_GODOT not found (brew install --cask godot)"; exit 1; }
command -v uv >/dev/null || { echo "uv not found (https://docs.astral.sh/uv/)"; exit 1; }
case "$(godot --version)" in
  "$REQUIRED_GODOT".*) ;;
  *) echo "Pixelorama $PIXELORAMA_TAG needs Godot $REQUIRED_GODOT.x, found $(godot --version)"; exit 1 ;;
esac

if [ ! -d "$ROOT/Pixelorama/.git" ]; then
  git clone --depth 1 --branch "$PIXELORAMA_TAG" https://github.com/Orama-Interactive/Pixelorama.git "$ROOT/Pixelorama"
  git -C "$ROOT/Pixelorama" switch -c ai-studio
fi

mkdir -p "$ROOT/Pixelorama/src/Extensions"
ln -sfn ../../../extension/AIStudio "$ROOT/Pixelorama/src/Extensions/AIStudio"

if ! grep -q '_load_extension("AIStudio", true)' "$ROOT/Pixelorama/src/HandleExtensions.gd"; then
  git -C "$ROOT/Pixelorama" apply "$ROOT/patches/pixelorama-load-aistudio.patch"
fi

echo "Importing Pixelorama assets (first run takes a moment)…"
godot --headless --path "$ROOT/Pixelorama" --import >/dev/null 2>&1 || true

uv sync --quiet --directory "$ROOT/mcp"
echo "Ready. Start Pixelorama with: $ROOT/scripts/run.sh"
