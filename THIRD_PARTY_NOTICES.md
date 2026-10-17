# Third-party notices

Pixelforge AI does not bundle third-party binaries or model weights. The components below are
downloaded by the setup scripts or installed by the user, and each keeps its own license.

| Component | How it is used | License |
|---|---|---|
| [Pixelorama](https://github.com/Orama-Interactive/Pixelorama) v1.2.3 | Cloned by `scripts/setup.sh`; `patches/pixelorama-load-aistudio.patch` modifies one function | MIT, © 2019-present Orama Interactive and contributors (full text below) |
| [Godot Engine](https://godotengine.org) 4.7 | Runtime installed by the user | MIT, © Godot Engine contributors |
| [MCP Python SDK](https://github.com/modelcontextprotocol/python-sdk) (`mcp`) | Dependency of `mcp/`, installed by `uv` with its own dependencies | MIT, © Anthropic, PBC |
| [Z-Image Turbo](https://huggingface.co/Comfy-Org/z_image_turbo) | Default ComfyUI model, downloaded by the user | See the model card |
| [ComfyUI](https://github.com/comfyanonymous/ComfyUI) | Optional local engine, installed by the user | GPL-3.0; used over its HTTP API only |

Remote engines (PixelLab API, Grok CLI, Claude CLI) are third-party services used under their
providers' terms with the user's own accounts. No code from those services is included.

## Pixelorama license

MIT License

Copyright (c) 2019-present Orama Interactive and contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
