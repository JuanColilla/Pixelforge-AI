# PixelLab (local) — AGENTS.md

Type: personal
Architecture: godot-extension + python-mcp

Editor de pixel art local: **Pixelorama** (código abierto, MIT, Godot 4.7) con una extensión
propia, **AI Studio**, que genera sprites con cuatro motores y expone el lienzo a asistentes
mediante MCP. No contiene código de pixellab.ai: es una reimplementación limpia contra APIs
públicas.

## STACK

- Pixelorama `v1.2.3` (clon en `Pixelorama/`, rama local `ai-studio`, ignorado por este repo).
- Godot `4.7.x` (`brew install --cask godot`).
- Extensión GDScript en `extension/AIStudio/` (enlazada por symlink a
  `Pixelorama/src/Extensions/AIStudio`).
- Servidor MCP en Python ≥ 3.11 con `mcp` 2.x (`MCPServer`, no `FastMCP`), gestionado con `uv`.
- Motores: ComfyUI local (Z-Image Turbo por defecto), Grok CLI (`image_gen`), API v2 de
  PixelLab (pixflux) y Claude CLI (modo píxeles con `--json-schema` y modo agente vía MCP).

## COMMANDS

```bash
scripts/setup.sh          # clona Pixelorama, aplica el parche, symlink, import, uv sync
scripts/run.sh            # arranca Pixelorama desde el código fuente
scripts/package.sh        # dist/AIStudio.zip para un Pixelorama de serie
scripts/register-mcp.sh   # registra pixelorama-mcp en Claude Code / Grok (scope user)
godot --headless --path Pixelorama --quit-after 300   # comprobación de carga sin ventana
```

## ARCHITECTURE

Ver `knowledge/architecture.md`. Resumen:

- `core/Generator.gd` orquesta: motor → `Pixelize.gd` → `CanvasOps.gd` (capa/cel/frame).
- `core/CanvasOps.gd` es la única puerta de escritura al lienzo; toda escritura pasa por
  `ExtensionsApi.project.set_pixelcel_image` → una entrada de deshacer por operación.
- `bridge/BridgeServer.gd`: TCP JSON-lines en `127.0.0.1:47821`, token aleatorio en
  `~/Library/Application Support/pixelorama/ai_studio/bridge.json` (permisos 600).
- `mcp/src/pixelorama_mcp/server.py`: traductor fino MCP (stdio) → puente.

### Invariantes

- INV-1: el puente solo escucha en `127.0.0.1` y exige el token en cada petición.
- INV-2: ninguna escritura al lienzo esquiva `CanvasOps.write_cel` (deshacer siempre íntegro).
- INV-3: los nodos de la extensión usan `PROCESS_MODE_ALWAYS`; Pixelorama pausa el árbol al
  perder el foco y el puente debe seguir respondiendo.
- INV-4: los CLIs se lanzan con `ProcessRunner` (no bloquea, permite cancelar y timeout);
  nunca `OS.execute` en el hilo principal.
- INV-5: secretos (token de PixelLab, token del puente) solo en `user://ai_studio/`, nunca
  en el repo ni en logs.

## LEARNED CORRECTIONS

- `godot --check-only -s` no registra autoloads ni compila clases de Pixelorama: da falsos
  errores en scripts que las usan. La verificación válida es arrancar Pixelorama
  (`--headless --quit-after N`) y leer el log.
- Matar Pixelorama con `pkill` deja `.running` y `extensions/Monitoring.ini`; en el siguiente
  arranque marca la extensión como sospechosa. Cerrar con `osascript -e 'quit app "Godot"'`.
- macOS no repinta la ventana de Godot si está totalmente tapada; los cambios por MCP sí se
  aplican y aparecen al volver a verla.
- En `await`, nunca usar un ternario con dos corutinas: usar `if/else` con `await` en cada rama.

## DESIGN SYSTEM

La UI vive dentro de Pixelorama: se usan solo sus controles y su tema. Textos de la UI con
`tr()`; las traducciones al español están en `core/Translations.gd`. Los mensajes de error de
motores van en inglés porque también llegan tal cual a los clientes MCP.
