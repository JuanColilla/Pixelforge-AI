# PixelLab API v2 in AI Studio

Source: `https://api.pixellab.ai/v2/openapi.json` (OpenAPI 3.1). Only public, documented
endpoints are used; nothing from PixelLab's web editor or its websockets.

## Endpoints

| Tool | Endpoint | Response | Limits checked by the client |
|---|---|---|---|
| Text to image | `POST /create-image-pixflux` | 200 with `image` | 16–400 px (clamped) |
| 8 rotations | `POST /generate-8-rotations-v3` | 200 with `background_job_id` | ≤ 256×256 |
| Rotate | `POST /rotate` | 200 with `image` (synchronous) | 16–200 px per side; `Direction` and `CameraView` enums from the schema |
| Animate | `POST /animate-with-text-v3` | 200 with `background_job_id` | ≤ 256×256, even `frame_count` from 4 to 16, width × height × frames ≤ 524,288 |
| Interpolate | `POST /interpolation-v2` | **202** with `background_job_id` | 16–128 px per side, both keyframes the same size |
| Balance | `GET /balance` | `credits.usd`, `subscription.generations/total` | — |

- `Base64Image` has `additionalProperties: false`: exactly `{type: "base64", base64, format}`.
  Responses may carry `data:image/png;base64,…`; the client strips the prefix.
- The seed is only sent when ≥ 0 (in v3, 0 means random).
- `animate-with-text-v3` requires an even `frame_count` per its description, not its schema;
  the client rejects odd counts before sending.

## Background jobs

A job is detected by `background_job_id` in the body, not by the status code (200 or 202).
`GET /background-jobs/{id}` is polled every 3 s: `completed` → `last_response`; `failed` →
`last_response.detail`; while `processing`, `queue_position` / `estimated_wait_seconds` go to
the status line. Transport errors, 429 and 5xx are retried; any other code stops the wait.
Cancelling sends `DELETE /background-jobs/{id}`.

Reading the result (`extract_images`): `images` (a list, or a map keyed by direction) →
`image` → any `{base64}` found walking the JSON in order.

## Without a token

PixelLab is optional. With neither `PIXELLAB_API_TOKEN` nor a token in the settings
(`Settings.pixellab_connected`):

- The panel shows nothing of PixelLab except the token field: no engine entry, no tools
  section, no balance, no confirmation and no `/balance` calls. Saving a token brings the UI
  back without a restart (`StudioPanel._apply_pixellab_connection`).
- `generate` with `engine: pixellab`, `pixellab_tool` (also with `dry_run`) and
  `pixellab_balance` fail at once with "PixelLab is not connected (set a token in AI Studio
  settings)", with no network traffic. `scripts/test-pixellab.sh` checks this against the
  mock's request log.

## Cost

There is no public up-front price for these tools: `/pro-flash/cost` only accepts
`operation` = create, edit, inpaint, character or object (the Pro Flash family). So:

- With a token, the panel reads `/balance` and asks for confirmation before each run (tool,
  region, balance, and that the cost is shown when it finishes).
- `dry_run` (bridge and MCP) returns the request and the balance without spending.
- Results include `balance_before` and `usage` (`usd` or `generations`), taken from the finished
  job or the synchronous response.

## Placement in Pixelorama

- Source: the chosen cel (`frame`/`layer`, -1 = current) or all visible layers (`merged`).
- Region: the whole canvas when it fits the endpoint's limits; otherwise the union of the used
  rects (for interpolation, of both keyframes) grown by a quarter on each side. Results go back
  centred on that region and are never rescaled.
- Rotations: 8 frames after the source frame on the same layer, or 8 layers above the source
  layer (named by direction when the API returns a map; "rotation N" for a list, because the v3
  schema does not document the order).
- Animate and interpolate: consecutive frames after the source frame (or the start keyframe).
- Rotate: like `generate`'s target (new layer, current cel or new frame).
- Each batch is a single undo action (`CanvasOps.insert_frames` / `insert_layers`), which also
  shifts animation tags the way Pixelorama's own "Add Frame" does.

## Tests

`scripts/test-pixellab.sh` downloads the OpenAPI document, starts `tests/pixellab/mock_api.py`
(validates every body with jsonschema and answers 422 on a mismatch), runs Pixelorama headless
with a temporary `HOME` and `PIXELLAB_API_URL` pointing at the mock, and drives
`tests/pixellab/bridge_test.py` through the bridge. A second pass runs without a token and
checks that no request reaches the mock. `PIXELLAB_API_URL` only accepts https, or plain http
to 127.0.0.1/localhost. The mock accepts only the fake token `mock-token` and returns synthetic
solid-colour images and made-up balances.
