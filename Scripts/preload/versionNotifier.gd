extends Node

## Уведомление о новой версии (галочка «Уведомление об обновлениях», updNotif).
## 054.995: раньше смотрело на релизы ОРИГИНАЛЬНОГО DeskSaw (dee-dee-catorce),
## поэтому в форке было выключено. Теперь - на релизы этого форка.
## Номер сборки (GlobalVariable.BUILD, например "054.994Pru") сравнивается с
## тегом последнего релиза ("055", "v055", "055Pru" - буквы отбрасываются).
const RELEASES = "https://api.github.com/repos/AlexFurkay/DeskSaw-VLLM/releases"
const RELEASES_PAGE = "https://github.com/AlexFurkay/DeskSaw-VLLM/releases"

var http: HTTPRequest


func _ready():
	http = HTTPRequest.new()
	add_child(http)
	http.timeout = 15.0
	http.request_completed.connect(_request_done)
	http.request(RELEASES, ["User-Agent: DeskSaw-VLLM"], HTTPClient.METHOD_GET)
	_sendLaunchStat()


## 055.004: анонимная статистика запусков (идея и решение Alex 24.10).
## Раз в запуск - одна отметка в GoatCounter: путь /launch/<версия>/<модель>.
## Ни имени, ни номера компьютера - только версия игры и модель ИИ. Галочка
## «Отправлять анонимную статистику запусков» (sendStats, по умолчанию вкл);
## что именно уходит - написано в README. Запуски без окна (стенды, проверки
## сборки) не считаются.
const STATS_URL := "https://akfrk.goatcounter.com/count"

func _sendLaunchStat() -> void:
	if not gbData.settings.get("sendStats", true):
		return
	if DisplayServer.get_name() == "headless":
		return
	var model := String(LLMManager.modelName) if gbData.settings.get("llmVisionEnabled", true) else "ai-off"
	var path := "/launch/%s/%s" % [GlobalVariable.BUILD, model]
	var url := "%s?p=%s&t=%s&e=true&rnd=%d" % [STATS_URL, path.uri_encode(), "DeskSaw launch".uri_encode(), randi()]
	var stat := HTTPRequest.new()
	add_child(stat)
	stat.timeout = 15.0
	stat.request_completed.connect(func(_r, code, _h, _b):
		print("Stats: запуск отмечен (код %d)" % code)
		stat.queue_free())
	stat.request(url, ["User-Agent: DeskSawVLLM/%s (%s)" % [GlobalVariable.BUILD, OS.get_name()]], HTTPClient.METHOD_GET)


func _request_done(_result, code, _headers, body):
	if code != 200:
		print("VersionNotifier: нет ответа от GitHub (код %d) - пропускаем" % code)
		return # нет сети, нет репозитория или релизов - молча
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK or not (json.data is Array) or json.data.is_empty():
		return
	var latest: String = String(json.data[0].get("tag_name", ""))
	if latest == "":
		return
	print("VersionNotifier: последний релиз %s, у тебя %s" % [latest, GlobalVariable.BUILD])
	if _buildNumber(latest) > _buildNumber(GlobalVariable.BUILD) and gbData.settings.get("updNotif", true):
		Console.print(Lang.t("[color=ORANGE]Вышла новая версия DeskSaw VLLM: %s (у тебя %s). Скачать: [url=%s]%s[/url]. Это сообщение отключается в Настройки - Общее.[/color]") % [latest, GlobalVariable.BUILD, RELEASES_PAGE, RELEASES_PAGE])
		OS.alert(Lang.t("Вышла новая версия DeskSaw VLLM: %s\nУ тебя: %s\n\n%s\n\nЭто окно можно отключить в Настройки - Общее.") % [latest, GlobalVariable.BUILD, RELEASES_PAGE], "DeskSaw VLLM")


## "054.994Pru" -> 54.994, "v055" -> 55.0
static func _buildNumber(tag: String) -> float:
	var digits := ""
	for c in tag:
		if c.is_valid_int() or (c == "." and not digits.contains(".")):
			digits += c
	return digits.to_float() if digits != "" else 0.0
