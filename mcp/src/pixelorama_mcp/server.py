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
EditTarget = Annotated[
    Target,
    Field(description="current_cel edits in place; new_layer/new_frame put the result in a new cel."),
]
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
        "several variants, and includes a preview image in its result. edit_image reworks existing "
        "pixels (img2img) and inpaint regenerates only a masked area, both locally with ComfyUI."
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
                          "and cost credits; claude_pixels draws small sprites (<=128px) as data."),
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


@mcp.tool()
async def select_rect(x: int, y: int, width: int, height: int) -> dict[str, Any]:
    """Replace Pixelorama's selection with a rectangle (clipped to the canvas)."""
    return await call("select_rect", {"x": x, "y": y, "width": width, "height": height})


@mcp.tool()
async def clear_selection() -> dict[str, Any]:
    """Remove the selection."""
    return await call("clear_selection")


def edit_params(
    prompt: str, strength: float, x: int, y: int, width: int, height: int, keep_palette: bool,
    colors: int, use_palette: bool, remove_background: bool | None, target: str, seed: int,
    frame: int, layer: int,
) -> dict[str, Any]:
    params: dict[str, Any] = {
        "prompt": prompt, "engine": "comfyui", "strength": strength, "x": x, "y": y, "width": width,
        "height": height, "keep_palette": keep_palette, "colors": colors, "use_palette": use_palette,
        "target": target, "seed": seed, "frame": frame, "layer": layer,
    }
    if remove_background is not None:
        params["remove_background"] = remove_background
    return params


KeepPalette = Annotated[
    bool, Field(description="Quantize to the source cel's own colors (when it has at most 64).")
]
RemoveBackground = Annotated[
    bool | None,
    Field(description="Clear the flat background around the result; null decides from the source's transparency."),
]


@mcp.tool()
async def edit_image(
    prompt: Annotated[str, Field(description="What the edited pixels should look like.")],
    strength: Annotated[
        float, Field(ge=0.05, le=1.0, description="0.3 refines details, 0.6 restyles, 0.85 repaints colors keeping the "
                                                "shapes, 1.0 ignores the original.")
    ] = 0.6,
    x: int = 0,
    y: int = 0,
    width: Annotated[int, Field(description="Region to edit; 0 uses the selection bounds or the whole cel.")] = 0,
    height: Annotated[int, Field(description="Region to edit; 0 uses the selection bounds or the whole cel.")] = 0,
    keep_palette: KeepPalette = True,
    colors: Annotated[int, Field(description="Max colors when the palette is not kept; 0 keeps all.")] = 16,
    use_palette: Annotated[bool, Field(description="Quantize to the active Pixelorama palette.")] = False,
    remove_background: RemoveBackground = None,
    target: EditTarget = "current_cel",
    seed: Annotated[int, Field(description="-1 picks a random seed.")] = -1,
    frame: Frame = -1,
    layer: Layer = -1,
) -> dict[str, Any]:
    """Image-to-image on existing pixel art with local ComfyUI (free): the cel region is
    upscaled, partially re-noised and redrawn following the prompt, then pixelized back to the
    same size and palette. With a selection, only selected pixels change."""
    params = edit_params(prompt, strength, x, y, width, height, keep_palette, colors, use_palette,
                         remove_background, target, seed, frame, layer)
    return await call("edit_image", params, timeout=GENERATION_TIMEOUT_SEC)


@mcp.tool()
async def inpaint(
    prompt: Annotated[str, Field(description="What to paint inside the masked area.")],
    x: int = 0,
    y: int = 0,
    width: Annotated[int, Field(description="Mask rectangle; 0 uses Pixelorama's current selection.")] = 0,
    height: Annotated[int, Field(description="Mask rectangle; 0 uses Pixelorama's current selection.")] = 0,
    strength: Annotated[
        float, Field(ge=0.05, le=1.0, description="1.0 repaints the area from scratch; lower keeps more of it.")
    ] = 1.0,
    keep_palette: KeepPalette = True,
    colors: Annotated[int, Field(description="Max colors when the palette is not kept; 0 keeps all.")] = 16,
    use_palette: Annotated[bool, Field(description="Quantize to the active Pixelorama palette.")] = False,
    remove_background: RemoveBackground = None,
    target: EditTarget = "current_cel",
    seed: Annotated[int, Field(description="-1 picks a random seed.")] = -1,
    frame: Frame = -1,
    layer: Layer = -1,
) -> dict[str, Any]:
    """Regenerate only the masked pixels of a cel with local ComfyUI (free), using the rest of
    the cel as context. The mask is the rectangle given, else the current selection."""
    params = edit_params(prompt, strength, x, y, width, height, keep_palette, colors, use_palette,
                         remove_background, target, seed, frame, layer)
    return await call("inpaint", params, timeout=GENERATION_TIMEOUT_SEC)


def main() -> None:
    mcp.run()


if __name__ == "__main__":
    main()
