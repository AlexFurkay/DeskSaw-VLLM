class_name Lang

## Язык сборки (EN-план, этап 1). Одна база кода, два языка:
## EN-сборка экспортируется пресетом с feature-тегом "en"
## (export_presets.cfg, custom_features="en"); RU - без тега.
##
## Переведённые тексты лежат зеркалом в папке res://en/, повторяя путь
## оригинала: res://defaults/skins/Expie/lore.txt ->
## res://en/defaults/skins/Expie/lore.txt. Картинки не дублируются -
## берутся из оригинала. Чего нет в en/ - берётся русское (RU-сборка
## вообще не смотрит в en/ и в неё не экспортируется).

static func code() -> String:
	return "en" if OS.has_feature("en") else "ru"

static func isEn() -> bool:
	return OS.has_feature("en")

## Путь к переведённой копии файла, если сборка EN и перевод есть;
## иначе - исходный путь без изменений.
static func localize(path: String) -> String:
	if not isEn() or not path.begins_with("res://"):
		return path
	var candidate := "res://en/" + path.trim_prefix("res://")
	if FileAccess.file_exists(candidate):
		return candidate
	return path

## Выбор строки по языку прямо в коде: Lang.pick("Привет", "Hi").
static func pick(ru, en):
	return en if isEn() else ru

## --- Интерфейс (EN-план, этап 2) ---
## Ключ - сам русский текст, перевод - в res://en/strings.json
## ({"русский": "english"}). В коде: Lang.t("Русский текст %s") % x -
## переводится ШАБЛОН, а не готовая строка. Надписи в сценах (.tscn)
## переводятся сами: словарь подключается к TranslationServer, и Godot
## подменяет text у Label/Button/CheckBox при совпадении ключа.
## RU-сборка словарь не грузит вовсе - t() возвращает текст как есть.
const STRINGS_PATH := "res://en/strings.json"
static var _dict: Dictionary = {}
static var _ready := false

static func setup() -> void:
	if _ready or not isEn():
		return
	_ready = true
	if FileAccess.file_exists(STRINGS_PATH):
		var data = JSON.parse_string(FileAccess.get_file_as_string(STRINGS_PATH))
		if data is Dictionary:
			_dict = data
	var tr := Translation.new()
	tr.locale = "en"
	for k in _dict:
		if String(_dict[k]) != "":
			tr.add_message(k, _dict[k])
	TranslationServer.add_translation(tr)
	TranslationServer.set_locale("en")

static func t(s: String) -> String:
	if not isEn():
		return s
	setup()
	var v = _dict.get(s, "")
	return s if String(v) == "" else String(v)
