#!/bin/sh
# Starts Pixelorama from source with the AI Studio extension loaded.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
exec godot --path "$ROOT/Pixelorama" "$@"
