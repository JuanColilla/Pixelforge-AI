extends RefCounted
## Spanish strings for the AI Studio UI, registered with the TranslationServer while the
## extension is enabled. Engine/provider error details stay in English (they also reach MCP
## clients verbatim).

const ES := {
	"Engine": "Motor",
	"ComfyUI (local)": "ComfyUI (local)",
	"Grok CLI": "Grok CLI",
	"PixelLab API": "API de PixelLab",
	"Claude CLI: pixels": "Claude CLI: píxeles",
	"Claude CLI: agent": "Claude CLI: agente",
	"Describe the sprite, tile or scene…": "Describe el sprite, tile o escena…",
	"Size": "Tamaño",
	"Canvas": "Lienzo",
	"Use the current canvas size": "Usar el tamaño del lienzo actual",
	"Colors": "Colores",
	"Maximum colors after quantization (0 keeps all colors)":
	"Máximo de colores tras cuantizar (0 conserva todos)",
	"Use current palette": "Usar la paleta actual",
	"Remove background": "Quitar fondo",
	"Place in": "Destino",
	"New layer": "Capa nueva",
	"Current cel": "Cel actual",
	"New frame": "Fotograma nuevo",
	"Seed": "Semilla",
	"-1 picks a random seed": "-1 elige una semilla aleatoria",
	"Generate": "Generar",
	"Cancel": "Cancelar",
	"Settings": "Ajustes",
	"Settings saved": "Ajustes guardados",
	"Save settings": "Guardar ajustes",
	"ComfyUI URL": "URL de ComfyUI",
	"Custom workflow (API JSON)": "Workflow propio (JSON de API)",
	"PixelLab API token": "Token de la API de PixelLab",
	"Grok CLI path": "Ruta de Grok CLI",
	"Claude CLI path": "Ruta de Claude CLI",
	"Claude model": "Modelo de Claude",
	"uv path": "Ruta de uv",
	"pixelorama-mcp folder": "Carpeta de pixelorama-mcp",
	"auto": "automático",
	"Enable MCP bridge": "Activar el puente MCP",
	"Bridge port": "Puerto del puente",
	"MCP bridge listening on 127.0.0.1:%d": "Puente MCP escuchando en 127.0.0.1:%d",
	"MCP bridge off": "Puente MCP desactivado",
	"MCP bridge stopped": "Puente MCP detenido",
	"Bridge could not listen on port %d (%s)": "El puente no pudo escuchar en el puerto %d (%s)",
	"Generating with %s…": "Generando con %s…",
	"Done in %s s": "Hecho en %s s",
	"Error: %s": "Error: %s",
}


static func spanish() -> Translation:
	var translation := Translation.new()
	translation.locale = "es"
	for message: String in ES:
		translation.add_message(message, ES[message])
	return translation
