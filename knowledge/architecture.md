# Arquitectura de AI Studio

## Flujo

```
Panel AI Studio ─┐                         ┌─ ComfyUIProvider ── HTTP ── ComfyUI :8188
                 ├─ Generator.generate() ──┼─ GrokProvider ───── ProcessRunner ── grok -p
MCP ─ Bridge ────┘        │                ├─ PixelLabProvider ─ HTTPS ── api.pixellab.ai/v2
                          │                └─ ClaudeProvider ─── ProcessRunner ── claude -p
                          ▼
                   Pixelize.to_pixel_art ──► CanvasOps.write_cel ──► set_pixelcel_image (undo)
```

Claude en modo agente cierra el círculo: `claude -p --mcp-config` lanza `pixelorama-mcp`, que
habla con el puente y dibuja con las mismas `CanvasOps`. Por eso `Generator` separa
`agent_busy` de `image_busy`: un agente en curso puede pedir generaciones de imagen.

## Ficheros

| Fichero | Responsabilidad |
|---|---|
| `Main.gd` | Monta todo, registra la traducción y la pestaña; lo desmonta al desactivar. |
| `core/Settings.gd` | `user://ai_studio/settings.cfg`; resuelve ejecutables y la carpeta MCP siguiendo el symlink. |
| `core/CanvasOps.gd` | Lectura/escritura del lienzo, capas, frames, deshacer. Única puerta de escritura. |
| `core/PixelGrid.gd` | Formato texto: paleta hex + filas base62 (`.` = no tocar). |
| `core/Pixelize.gd` | Encaje, quitar fondo por inundación desde el borde, alfa binaria, k-means / paleta. |
| `core/Generator.gd` | Normaliza la petición, elige motor, pixeliza y coloca. |
| `core/Http.gd` | `HTTPRequest` con `await`; decodifica PNG/JPEG/WebP por firma. |
| `core/Translations.gd` | Cadenas en español para `tr()`. |
| `providers/*.gd` | Un fichero por motor; todos exponen `generate()` y `cancel()`. |
| `providers/ProcessRunner.gd` | `/bin/sh -c exec …` con salida a ficheros, sondeo de PID, kill. |
| `bridge/BridgeServer.gd` | Servidor TCP JSON-lines con token. |
| `ui/StudioPanel.gd` | Pestaña del dock, construida por código. |

## Protocolo del puente

Una línea JSON por petición y por respuesta:

```json
{"id": 1, "token": "<bridge.json>", "method": "paint_grid", "params": {"x": 0, "y": 0, "palette": ["#00000000", "#ffcc00"], "rows": ["0110"]}}
{"id": 1, "result": {"frame": 0, "layer": 1, "pixels": 2}}
```

Métodos: `ping`, `get_project_info`, `view_canvas`, `read_pixels`, `draw_pixels`, `draw_line`,
`draw_rect`, `fill`, `paint_grid`, `clear_cel`, `batch`, `set_image`, `add_layer`, `add_frame`,
`select_cel`, `new_project`, `undo`, `redo`, `generate`, `cancel`.

Todas las operaciones de dibujo pasan por `CanvasOps.apply_ops`: cada operación (`pixels`,
`line`, `rect`, `fill`, `grid`, `clear`) se valida y compila a un `Callable`, y el lote se
aplica sobre una copia del cel que se escribe una sola vez. Una operación inválida aborta el
lote sin dibujar nada. `batch` expone esto al MCP, que manda N operaciones en una llamada y
un solo paso de deshacer.

`generate` acepta `variants` (1–4, semillas consecutivas) y `preview` (devuelve una hoja de
contacto PNG). Con `new_layer`, la primera variante queda visible y el resto en capas ocultas.

`frame`/`layer` = -1 usa el cel actual; en `view_canvas`, `layer` = -1 mezcla todas las capas
visibles.

## Motores

- **ComfyUI**: grafo Z-Image Turbo en formato API (8 pasos, `res_multistep`, cfg 1). El área
  de generación depende del destino: 512² hasta 128 px, 768² hasta 256 px y 1024² por encima.
  Benchmark en M5 Max: 13,4 s a 1024 px frente a 3,3 s a 512 px; un lote de 4 a 512 px tarda
  15,2 s, así que agrupar en lote no ahorra tiempo en MPS. La salida es `PreviewImage` (carpeta
  temp de ComfyUI). La primera generación tras arrancar ComfyUI añade la carga del modelo
  (~60 s). Se puede sustituir por un workflow propio con `{{prompt}}`, `{{width}}`,
  `{{height}}` y `{{seed}}`.
- **Grok CLI**: `grok -p … --always-approve --output-format json --max-turns 8`, con la orden
  de guardar el PNG en la carpeta del trabajo. Unos 30 s y unos 0,08 $ por imagen; casi todo
  el coste es el bucle del agente.
- **PixelLab**: `POST /v2/create-image-pixflux` (16–400 px, pixel art nativo); soporta
  `color_image` para forzar la paleta y sondea `/background-jobs` si la respuesta es 202.
  Token: `PIXELLAB_API_TOKEN` o los ajustes. Sin probar con token real.
- **Claude, píxeles**: `--json-schema` con paleta + filas base62, hasta 128×128. 16×16 en unos
  17 s con `sonnet`.
- **Claude, agente**: `--mcp-config` temporal + `--allowedTools mcp__pixelorama`.

## Limitaciones conocidas

- Pixelorama solo repinta cuando su ventana es visible (macOS). Para ver dibujar a Claude,
  deja la ventana visible al lado.
- `dist/AIStudio.zip` para un Pixelorama de serie no está probado con la app oficial.
- Los errores de los motores se muestran en inglés.
