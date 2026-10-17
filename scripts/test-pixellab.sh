#!/bin/sh
# Exercises the PixelLab tools end to end without a token or credits: a local mock of the API
# checks every request body against the published OpenAPI schema, and Pixelorama runs headless
# with an isolated HOME, so the user's settings and any running bridge are never touched.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
MOCK_PORT=${MOCK_PORT:-47878}
BRIDGE_PORT=${BRIDGE_PORT:-47877}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pixellab-test.XXXXXX")
DATA="$WORK/home/Library/Application Support/pixelorama"
MOCK_PID=""
GODOT_PID=""
cleanup() { kill $MOCK_PID $GODOT_PID 2>/dev/null || true; }
trap cleanup EXIT

[ -d "$ROOT/Pixelorama" ] || { echo "Run scripts/setup.sh first"; exit 1; }
curl -sSf -o "$WORK/openapi.json" https://api.pixellab.ai/v2/openapi.json
mkdir -p "$DATA/ai_studio"
printf '[ai_studio]\n\nbridge_port=%s\npanel_introduced=true\n' "$BRIDGE_PORT" > "$DATA/ai_studio/settings.cfg"

uv run --quiet --no-project --with jsonschema python -I "$ROOT/tests/pixellab/mock_api.py" \
  "$WORK/openapi.json" "$WORK/mock.log" "$MOCK_PORT" > "$WORK/mock.out" 2>&1 &
MOCK_PID=$!
tries=0
until curl -sf -o /dev/null -H 'Authorization: Bearer mock-token' "http://127.0.0.1:$MOCK_PORT/v2/balance"; do
  tries=$((tries + 1))
  [ $tries -lt 60 ] || { echo "Mock API did not start (see $WORK/mock.out)"; exit 1; }
  sleep 0.5
done

HOME="$WORK/home" PIXELLAB_API_URL="http://127.0.0.1:$MOCK_PORT/v2" PIXELLAB_API_TOKEN=mock-token \
  godot --headless --path "$ROOT/Pixelorama" --quit-after 1000000 > "$WORK/godot.log" 2>&1 &
GODOT_PID=$!

status=0
python3 -I "$ROOT/tests/pixellab/bridge_test.py" "$DATA/ai_studio/bridge.json" "$WORK/requests.jsonl" || status=1
uv run --quiet --no-project --with jsonschema python -I "$ROOT/tests/pixellab/validate_requests.py" \
  "$WORK/openapi.json" "$WORK/requests.jsonl" || status=1
kill $GODOT_PID
wait $GODOT_PID 2>/dev/null || true

# Without a token nothing may reach the network: the mock must not log a single request.
echo "Without a PixelLab token:"
rm -f "$DATA/ai_studio/bridge.json" "$DATA/.running" "$DATA/extensions/Monitoring.ini"
requests_before=$(wc -l < "$WORK/mock.log")
env -u PIXELLAB_API_TOKEN HOME="$WORK/home" PIXELLAB_API_URL="http://127.0.0.1:$MOCK_PORT/v2" \
  godot --headless --path "$ROOT/Pixelorama" --quit-after 1000000 > "$WORK/godot-offline.log" 2>&1 &
GODOT_PID=$!
python3 -I "$ROOT/tests/pixellab/bridge_test.py" "$DATA/ai_studio/bridge.json" /dev/null no-token || status=1
if [ "$(wc -l < "$WORK/mock.log")" -ne "$requests_before" ]; then
  echo "FAIL the mock API received requests without a token"
  status=1
else
  echo "PASS no request reached the API without a token"
fi
if grep -q 'SCRIPT ERROR' "$WORK/godot.log" "$WORK/godot-offline.log"; then
  grep -A3 'SCRIPT ERROR' "$WORK/godot.log" "$WORK/godot-offline.log"
  status=1
fi
echo "Logs in $WORK"
exit $status
