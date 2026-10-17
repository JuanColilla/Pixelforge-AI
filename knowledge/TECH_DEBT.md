# Deuda técnica

- PixelLab: probado solo el error sin token; falta una generación real y confirmar la forma de
  la respuesta 202 (`background_job_id`).
- `dist/AIStudio.zip`: sin probar en Pixelorama.app oficial. En instalaciones empaquetadas hay
  que fijar la carpeta MCP a mano.
- Grok: el coste por imagen lo domina el bucle del agente (~265k tokens). Limitar herramientas
  con `--tools` cuando se confirmen sus IDs internos (`image_gen` + la herramienta de shell).
- Pixelize: el quitado de fondo es por inundación desde el borde con tolerancia fija (0,12);
  falla con fondos degradados. Valorar un paso de segmentación en ComfyUI.
- Sin tests automatizados de GDScript (ni GUT ni gdUnit). Hoy se verifica arrancando Pixelorama
  headless y hablando con el puente.
- `user://ai_studio/jobs/<id>/` guarda una carpeta por ejecución de Grok/Claude (con stdout)
  y nunca se poda.
- `scripts/register-mcp.sh` no cubre Claude Desktop: su `claude_desktop_config.json` es JSON
  curado por el usuario y se edita a mano (entrada `pixelorama` con la ruta absoluta de `uv`).
- Las cuatro primeras imágenes de prueba quedaron en `~/ComfyUI-Shared/output/pixelorama-ai/`
  (antes del cambio a `PreviewImage`); se pueden borrar a mano.
