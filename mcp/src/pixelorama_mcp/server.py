"""MCP server that lets an assistant draw pixel art in a running Pixelorama.

It is a thin translator: every tool becomes one JSON-lines request to the AI Studio
extension's bridge on 127.0.0.1, authenticated with the token in bridge.json.
"""

from __future__ import annotations

import asyncio
import base64
import json
import os
import sys
from pathlib import Path
from typing import Annotated, Any, Literal, Union

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError
from pydantic import BaseModel, Field

GENERATION_TIMEOUT_SEC = 900
DEFAULT_TIMEOUT_SEC = 30
VIEW_TARGET_SIDE = 512

Engine = Literal["comfyui", "grok", "pixellab", "claude_pixels"]
Target = Literal["new_layer", "current_cel", "new_frame"]
Direction = Literal["south", "south-east", "east", "north-east", "north", "north-west", "west", "south-west"]
CameraView = Literal["side", "low top-down", "high top-down"]
Merged = Annotated[bool, Field(description="Use all visible layers blended as the source instead of one layer.")]
Seed = Annotated[int, Field(description="-1 lets PixelLab pick.")]
DryRun = Annotated[
    bool,
    Field(description="Return the API request and the account balance without calling the tool (no credits spent)."),
]
PIXELLAB_NOTE = (
    "Only works when a PixelLab API token is set in AI Studio; otherwise it returns "
    "'PixelLab is not connected'. Uses PixelLab credits: the result reports balance_before and usage, "
    "and dry_run=true returns the request and balance without running. "
)
Frame = Annotated[int, Field(description="Frame index from 0; -1 means the current frame.")]
Layer = Annotated[int, Field(description="Layer index from 0 (bottom); -1 means the current layer.")]
ColorText = Annotated[str, Field(description='Hex color "#rrggbb" or "#rrggbbaa", or a color name.')]

mcp = MCPServer(
    name="pixelorama",
    instructions=(
        "Draw pixel art in the user's running Pixelorama editor. Coordinates are pixels with "
        "(0,0) at the top-left. Call get_project_info first, then view_canvas to see the work. "
        "paint_grid is the fastest way to draw a sprite: a palette plus rows of base62 palette "
        "indices ('.' leaves a pixel untouched). Use batch to send many drawing ops at once: one "
        "call, one undo step. generate_image creates whole sprites with an image model, can return "
        "several variants, and includes a preview image in its result. "
        "The pixellab_* tools turn an existing sprite into directions or animation frames and work only "
        "when a PixelLab API token is set in AI Studio."
    ),
)


class Pixel(BaseModel):
    x: int
    y: int
    color: ColorText


class PixelsOp(BaseModel):
    op: Literal["pixels"]
    pixels: list[Pixel]


class LineOp(BaseModel):
    op: Literal["line"]
    x0: int
    y0: int
    x1: int
    y1: int
    color: ColorText


class RectOp(BaseModel):
    op: Literal["rect"]
    x: int
    y: int
    width: int
    height: int
    color: ColorText
    filled: bool = True


class FillOp(BaseModel):
    op: Literal["fill"]
    x: int
    y: int
    color: ColorText


class GridOp(BaseModel):
    op: Literal["grid"]
    palette: list[ColorText]
    rows: list[str]
    x: int = 0
    y: int = 0


class ClearOp(BaseModel):
    op: Literal["clear"]


DrawOp = Annotated[Union[PixelsOp, LineOp, RectOp, FillOp, GridOp, ClearOp], Field(discriminator="op")]


def bridge_file() -> Path:
    override = os.environ.get("PIXELORAMA_BRIDGE_FILE")
    if override:
        return Path(override)
    if sys.platform == "darwin":
        base = Path.home() / "Library" / "Application Support"
    elif sys.platform == "win32":
        base = Path(os.environ.get("APPDATA", Path.home()))
    else:
        base = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share"))
    return base / "pixelorama" / "ai_studio" / "bridge.json"


async def call(method: str, params: dict[str, Any] | None = None, timeout: float = DEFAULT_TIMEOUT_SEC) -> dict[str, Any]:
    path = bridge_file()
    try:
        info = json.loads(path.read_text())
    except FileNotFoundError:
        raise ToolError(
            f"Pixelorama with the AI Studio extension is not running (no bridge file at {path})."
        ) from None
    try:
        reader, writer = await asyncio.wait_for(asyncio.open_connection(info["host"], info["port"]), 5)
    except (OSError, asyncio.TimeoutError) as error:
        raise ToolError(f"Cannot reach the Pixelorama bridge on port {info['port']}: {error}") from None
    try:
        request = {"id": 1, "token": info["token"], "method": method, "params": params or {}}
        writer.write((json.dumps(request) + "\n").encode())
        await writer.drain()
        line = await asyncio.wait_for(reader.readline(), timeout)
    except asyncio.TimeoutError:
        raise ToolError(f"Pixelorama did not answer '{method}' within {timeout:.0f} s") from None
    finally:
        writer.close()
    if not line:
        raise ToolError("Pixelorama closed the connection")
    response = json.loads(line)
    if "error" in response:
        raise ToolError(response["error"])
    return response["result"]


@mcp.tool()
async def get_project_info() -> dict[str, Any]:
    """Canvas size, frames, layers (index, name, type, visibility), current cel and active palette."""
    return await call("get_project_info")


@mcp.tool()
async def view_canvas(
    frame: Frame = -1,
    layer: Annotated[int, Field(description="Layer index, or -1 for all visible layers blended.")] = -1,
    scale: Annotated[int, Field(description="Integer zoom; 0 picks one that makes the image ~512px.")] = 0,
) -> Image:
    """Render the canvas (or one layer) as a PNG so you can look at the artwork."""
    if scale <= 0:
        info = await call("get_project_info")
        scale = max(1, VIEW_TARGET_SIDE // max(info["width"], info["height"]))
    result = await call("view_canvas", {"frame": frame, "layer": layer, "scale": scale})
    return Image(data=base64.b64decode(result["png_base64"]), format="png")


@mcp.tool()
async def read_pixels(
    x: int = 0,
    y: int = 0,
    width: Annotated[int, Field(description="0 reads the whole canvas.")] = 0,
    height: Annotated[int, Field(description="0 reads the whole canvas.")] = 0,
    frame: Frame = -1,
    layer: Layer = -1,
) -> dict[str, Any]:
    """Exact pixels of a region as a palette plus base62 index rows (max 62 colors per region)."""
    return await call(
        "read_pixels", {"x": x, "y": y, "width": width, "height": height, "frame": frame, "layer": layer}
    )


@mcp.tool()
async def paint_grid(
    palette: Annotated[list[ColorText], Field(description="Up to 62 colors; position = index.")],
    rows: Annotated[
        list[str],
        Field(description="One string per row; each char is a base62 palette index (0-9a-zA-Z), '.' skips."),
    ],
    x: Annotated[int, Field(description="Left edge of the grid on the canvas.")] = 0,
    y: Annotated[int, Field(description="Top edge of the grid on the canvas.")] = 0,
    frame: Frame = -1,
    layer: Layer = -1,
) -> dict[str, Any]:
    """Paint a block of pixels from a palette and index rows. Use '#00000000' to erase."""
    return await call(
        "paint_grid", {"palette": palette, "rows": rows, "x": x, "y": y, "frame": frame, "layer": layer}
    )


@mcp.tool()
async def draw_pixels(pixels: list[Pixel], frame: Frame = -1, layer: Layer = -1) -> dict[str, Any]:
    """Set individual pixels; best for small touch-ups."""
    return await call(
        "draw_pixels", {"pixels": [p.model_dump() for p in pixels], "frame": frame, "layer": layer}
    )


@mcp.tool()
async def draw_line(
    x0: int, y0: int, x1: int, y1: int, color: ColorText, frame: Frame = -1, layer: Layer = -1
) -> dict[str, Any]:
    """Draw a 1px pixel-perfect line (Bresenham)."""
    return await call(
        "draw_line", {"x0": x0, "y0": y0, "x1": x1, "y1": y1, "color": color, "frame": frame, "layer": layer}
    )


@mcp.tool()
async def draw_rect(
    x: int,
    y: int,
    width: int,
    height: int,
    color: ColorText,
    filled: bool = True,
    frame: Frame = -1,
    layer: Layer = -1,
) -> dict[str, Any]:
    """Draw a filled or 1px-outlined rectangle."""
    return await call(
        "draw_rect",
        {"x": x, "y": y, "width": width, "height": height, "color": color, "filled": filled,
         "frame": frame, "layer": layer},
    )


@mcp.tool()
async def fill(x: int, y: int, color: ColorText, frame: Frame = -1, layer: Layer = -1) -> dict[str, Any]:
    """Bucket fill: replace the contiguous area of the exact color at (x, y)."""
    return await call("fill", {"x": x, "y": y, "color": color, "frame": frame, "layer": layer})


@mcp.tool()
async def clear_cel(frame: Frame = -1, layer: Layer = -1) -> dict[str, Any]:
    """Erase every pixel of one cel."""
    return await call("clear_cel", {"frame": frame, "layer": layer})


@mcp.tool()
async def batch(ops: list[DrawOp], frame: Frame = -1, layer: Layer = -1) -> dict[str, Any]:
    """Apply many drawing ops to one cel in a single call and a single undo step.

    Prefer this over separate calls: e.g. a grid for the base shape, then lines and pixels
    for details. Ops are validated first; if one is invalid nothing is drawn.
    """
    return await call(
        "batch",
        {"ops": [o.model_dump() for o in ops], "frame": frame, "layer": layer},
    )


@mcp.tool()
async def add_layer(name: str = "Layer") -> dict[str, Any]:
    """Add a pixel layer above the current one and make it current."""
    return await call("add_layer", {"name": name})


@mcp.tool()
async def add_frame(after: Annotated[int, Field(description="-1 means after the current frame.")] = -1) -> dict[str, Any]:
    """Add an animation frame."""
    return await call("add_frame", {"after": after})


@mcp.tool()
async def select_cel(frame: Frame = -1, layer: Layer = -1) -> dict[str, Any]:
    """Make a frame/layer the current cel (where calls with -1 draw)."""
    return await call("select_cel", {"frame": frame, "layer": layer})


@mcp.tool()
async def new_project(width: int = 64, height: int = 64, name: str = "untitled") -> dict[str, Any]:
    """Open a new empty project in a new tab."""
    return await call("new_project", {"width": width, "height": height, "name": name})


@mcp.tool()
async def undo() -> dict[str, Any]:
    """Undo the last action in Pixelorama."""
    return await call("undo")


@mcp.tool()
async def redo() -> dict[str, Any]:
    """Redo the last undone action."""
    return await call("redo")


@mcp.tool(structured_output=False)
async def generate_image(
    prompt: str,
    engine: Annotated[
        Engine,
        Field(description="comfyui runs locally (free, ~3 s per sprite); grok and pixellab are remote "
                          "and cost credits (pixellab only works with a PixelLab token set in AI Studio); "
                          "claude_pixels draws small sprites (<=128px) as data."),
    ] = "comfyui",
    width: Annotated[int, Field(description="0 uses the canvas width.")] = 0,
    height: Annotated[int, Field(description="0 uses the canvas height.")] = 0,
    colors: Annotated[int, Field(description="Max colors after quantization; 0 keeps all.")] = 16,
    use_palette: Annotated[bool, Field(description="Quantize to the active Pixelorama palette.")] = False,
    remove_background: bool = True,
    target: Target = "new_layer",
    seed: Annotated[int, Field(description="-1 picks a random seed.")] = -1,
    variants: Annotated[
        int,
        Field(ge=1, le=4, description="Images to generate with consecutive seeds. With new_layer, the "
                                      "first stays visible and the rest are hidden layers to choose from."),
    ] = 1,
) -> list[Any]:
    """Generate sprites with an image engine, pixelize them to the canvas and place them.

    Returns the placement details plus a preview image of every variant side by side, so no
    extra view_canvas call is needed to judge the result.
    """
    params: dict[str, Any] = {
        "prompt": prompt, "engine": engine, "colors": colors, "use_palette": use_palette,
        "remove_background": remove_background, "target": target, "seed": seed,
        "variants": variants, "preview": True,
    }
    if width > 0:
        params["width"] = width
    if height > 0:
        params["height"] = height
    result = await call("generate", params, timeout=GENERATION_TIMEOUT_SEC * variants)
    preview = result.pop("preview_png_base64", None)
    content: list[Any] = [result]
    if preview:
        content.append(Image(data=base64.b64decode(preview), format="png"))
    return content


def summarize_images(value: Any) -> Any:
    """Replaces base64 image payloads with their size so dry runs stay readable."""
    if isinstance(value, dict):
        if isinstance(value.get("base64"), str):
            return {**value, "base64": f"<{len(value['base64']) * 3 // 4} bytes>"}
        return {key: summarize_images(item) for key, item in value.items()}
    if isinstance(value, list):
        return [summarize_images(item) for item in value]
    return value


async def pixellab_tool(params: dict[str, Any]) -> dict[str, Any]:
    result = await call("pixellab_tool", params, timeout=GENERATION_TIMEOUT_SEC)
    if result.get("dry_run"):
        result["body"] = summarize_images(result.get("body"))
    return result


@mcp.tool()
async def pixellab_balance() -> dict[str, Any]:
    """PixelLab account balance: USD credits and remaining subscription generations.

    Only works when a PixelLab API token is set in AI Studio.
    """
    return await call("pixellab_balance")


@mcp.tool(description=PIXELLAB_NOTE + (
    "Generate the 8 directional views of the sprite in a cel with PixelLab (generate-8-rotations-v3, "
    "max 256x256) and place them as 8 new frames after the source frame, or as 8 new layers."
))
async def pixellab_rotations(
    description: Annotated[str, Field(description="Optional hint describing the subject.")] = "",
    placement: Annotated[
        Literal["frames", "layers"], Field(description="frames: 8 frames on the source layer; layers: 8 layers.")
    ] = "frames",
    frame: Frame = -1,
    layer: Layer = -1,
    merged: Merged = False,
    remove_background: bool = True,
    seed: Seed = -1,
    dry_run: DryRun = False,
) -> dict[str, Any]:
    return await pixellab_tool({
        "tool": "rotations", "description": description, "placement": placement, "frame": frame,
        "layer": layer, "merged": merged, "remove_background": remove_background, "seed": seed,
        "dry_run": dry_run,
    })


@mcp.tool(description=PIXELLAB_NOTE + (
    "Rotate the sprite in a cel to one direction and/or camera view with PixelLab (rotate, 16-200 px "
    "per side) and place the result like generate_image's target."
))
async def pixellab_rotate(
    to_direction: Direction = "east",
    from_direction: Annotated[Direction, Field(description="Direction the source sprite faces.")] = "south",
    from_view: CameraView = "side",
    to_view: Annotated[CameraView | None, Field(description="Defaults to from_view.")] = None,
    target: Target = "new_layer",
    frame: Frame = -1,
    layer: Layer = -1,
    merged: Merged = False,
    use_palette: Annotated[bool, Field(description="Force the active Pixelorama palette.")] = False,
    seed: Seed = -1,
    dry_run: DryRun = False,
) -> dict[str, Any]:
    return await pixellab_tool({
        "tool": "rotate", "to_direction": to_direction, "from_direction": from_direction,
        "from_view": from_view, "to_view": to_view or from_view, "target": target, "frame": frame,
        "layer": layer, "merged": merged, "use_palette": use_palette, "seed": seed, "dry_run": dry_run,
    })


@mcp.tool(description=PIXELLAB_NOTE + (
    "Animate the sprite in a cel from a text action with PixelLab (animate-with-text-v3, max 256x256, "
    "width*height*frame_count <= 524288) and insert the frames after the source frame."
))
async def pixellab_animate(
    action: Annotated[str, Field(description="The motion, e.g. 'walking', 'swinging a sword'.")],
    frame_count: Annotated[int, Field(description="Even number from 4 to 16.")] = 8,
    frame: Frame = -1,
    layer: Layer = -1,
    merged: Merged = False,
    remove_background: bool = True,
    seed: Seed = -1,
    dry_run: DryRun = False,
) -> dict[str, Any]:
    return await pixellab_tool({
        "tool": "animate", "description": action, "frame_count": frame_count, "frame": frame,
        "layer": layer, "merged": merged, "remove_background": remove_background, "seed": seed,
        "dry_run": dry_run,
    })


@mcp.tool(description=PIXELLAB_NOTE + (
    "Generate the in-between frames from one keyframe to another with PixelLab (interpolation-v2, "
    "16-128 px per side) and insert them right after the start frame."
))
async def pixellab_interpolate(
    action: Annotated[str, Field(description="The transition, e.g. 'powering up', 'morphing'.")],
    end_frame: Annotated[int, Field(description="End keyframe index; -1 means the frame after the start.")] = -1,
    frame: Annotated[int, Field(description="Start keyframe index; -1 means the current frame.")] = -1,
    layer: Layer = -1,
    merged: Merged = False,
    remove_background: bool = True,
    use_palette: Annotated[bool, Field(description="Force the active Pixelorama palette.")] = False,
    seed: Seed = -1,
    dry_run: DryRun = False,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "tool": "interpolate", "description": action, "frame": frame, "layer": layer, "merged": merged,
        "remove_background": remove_background, "use_palette": use_palette, "seed": seed, "dry_run": dry_run,
    }
    if end_frame >= 0:
        params["end_frame"] = end_frame
    return await pixellab_tool(params)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
