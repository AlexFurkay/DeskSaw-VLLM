extends Node

## Autoload: LLMManager
##
## Every `screenshotInterval` seconds, grabs the desktop via ScreenCapture (C#),
## sends it to a locally running Ollama vision model, and emits `llmReaction`
## with the model's short reply. behavior.gd (or anything else) can connect
## to this signal and pipe the text into dialogueSys.setDia(...).
##
## Requires Ollama running locally with a vision model pulled, e.g.:
##   ollama pull moondream

signal llmReaction(text: String)

const OLLAMA_URL := "http://localhost:11434/api/generate"

## Switch to "moondream" if you want the smaller/faster model once it's
## behaving - llava is more reliable out of the box for now.
var modelName := "llava:7b"
var screenshotInterval := 5.0
var systemPrompt := "You are a tiny, slightly unhinged desktop creature glancing at the user's screen. React in ONE short sentence (max ~12 words), in character, playful or blunt. Output ONLY the line, no quotes, no explanation."

var http: HTTPRequest
var timer: Timer
var busy := false


func _ready() -> void:
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_request_completed)

	timer = Timer.new()
	timer.wait_time = screenshotInterval
	timer.one_shot = false
	add_child(timer)
	timer.timeout.connect(_on_tick)
	timer.start()


func _on_tick() -> void:
	if busy:
		return
	if not gbData.settings.get("llmVisionEnabled", false):
		return

	var png_bytes: PackedByteArray = ScreenCapture.GetScreenshotPng()
	if png_bytes.is_empty():
		return

	busy = true
	var b64 := Marshalls.raw_to_base64(png_bytes)

	var payload := {
		"model": modelName,
		"prompt": systemPrompt,
		"images": [b64],
		"stream": false,
		# repeat_penalty guards against the model looping the same phrase
		# forever, which some small vision models (moondream especially)
		# are prone to on Ollama.
		"options": {
			"repeat_penalty": 1.3,
			"temperature": 0.7,
			"num_predict": 40
		}
	}

	var headers := ["Content-Type: application/json"]
	var err := http.request(OLLAMA_URL, headers, HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		print("LLMManager: failed to start request: ", err)
		busy = false


func _on_request_completed(_result: int, response_code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	busy = false

	if response_code != 200:
		print("LLMManager: Ollama returned code ", response_code, " - is `ollama serve` running with the model pulled?")
		return

	var parsed = JSON.parse_string(body.get_string_from_utf8())
	if not (parsed is Dictionary) or not parsed.has("response"):
		print("LLMManager: unexpected response shape from Ollama")
		return

	var text: String = String(parsed["response"]).strip_edges()
	# Ollama sometimes wraps output in quotes despite the prompt - strip them.
	text = text.trim_prefix("\"").trim_suffix("\"")

	if text != "":
		llmReaction.emit(text)


## Lets the console/settings UI turn this on or off at runtime.
func setEnabled(enabled: bool) -> void:
	gbData.settings["llmVisionEnabled"] = enabled
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
