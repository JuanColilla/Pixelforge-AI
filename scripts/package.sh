#!/bin/sh
# Builds dist/AIStudio.zip for a stock Pixelorama build (Preferences > Extensions > Add).
# Packaged installs cannot follow the dev symlink, so set the pixelorama-mcp folder in
# AI Studio > Settings if you use Claude's agent mode.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$STAGE/src/Extensions"
cp -R "$ROOT/extension/AIStudio" "$STAGE/src/Extensions/AIStudio"
find "$STAGE" -name '.DS_Store' -delete
mkdir -p "$ROOT/dist"
rm -f "$ROOT/dist/AIStudio.zip"
(cd "$STAGE" && zip -qr "$ROOT/dist/AIStudio.zip" src)
echo "Built $ROOT/dist/AIStudio.zip"
