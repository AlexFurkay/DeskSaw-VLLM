class_name Lang

## Язык игры (EN-план). Одна игра, два языка, переключатель во вкладке
## «Отладка» (см. switchTo / startupChoice ниже). Выбор хранится в
## override.cfg рядом с exe: Godot читает его до запуска игры, так что
## он задаёт и язык ([desksaw] lang), и папку сохранений (у EN своя -
## DDnAKFRK/DeskSawVLLM-EN). Feature-тег "en" тоже включает EN (старый
## способ, отдельной EN-сборки больше нет).
##
## Переведённые тексты лежат зеркалом в папке res://en/, повторяя путь
## оригинала: res://defaults/skins/Expie/lore.txt ->
## res://en/defaults/skins/Expie/lore.txt. Картинки не дублируются -
## берутся из оригинала. Чего нет в en/ - берётся русское. В RU папка
## en/ не читается вовсе.

static func code() -> String:
	return "en" if isEn() else "ru"

## Для стенда и проверок из исходников: override.cfg рядом с project.godot
## с [desksaw] lang="en" (и своей папкой данных - custom_user_dir_name).
static var _en := -1
static func isEn() -> bool:
	if _en < 0:
		_en = 1 if OS.has_feature("en") or String(ProjectSettings.get_setting("desksaw/lang", "")) == "en" else 0
	return _en == 1

## --- Переключение языка ---
## Файл выбора: override.cfg рядом с exe (из исходников - рядом с
## project.godot; там же его кладёт стенд). Игра пишет его целиком.
const CHOICE_FILE := "override.cfg"
const EN_USER_DIR := "DDnAKFRK/DeskSawVLLM-EN"

static func choicePath() -> String:
	if OS.has_feature("template"):
		return OS.get_executable_path().get_base_dir().path_join(CHOICE_FILE)
	return ProjectSettings.globalize_path("res://").path_join(CHOICE_FILE)

## Записать выбор. false - не удалось (папка игры защищена от записи,
## например Program Files).
static func writeChoice(lang: String) -> bool:
	var t := "; DeskSaw: язык игры / game language (вкладка «Отладка» / «Debug» tab)\n"
	t += "[desksaw]\nlang=\"%s\"\n" % lang
	if lang == "en":
		t += "\n[application]\nconfig/custom_user_dir_name=\"%s\"\n" % EN_USER_DIR
	var f := FileAccess.open(choicePath(), FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(t)
	f.close()
	return true

## Переключатель во вкладке «Отладка»: записать выбор и перезапустить игру.
static func switchTo(lang: String) -> bool:
	if lang == code():
		return true
	if not writeChoice(lang):
		return false
	_restart()
	return true

## Ключ ярлыка: --lang=en / --lang=ru (можно и после «--»).
static func _langArg(a: String) -> String:
	a = a.trim_prefix("--").trim_prefix("++").to_lower()
	if a == "lang=en":
		return "en"
	if a == "lang=ru":
		return "ru"
	return ""

static func _restart() -> void:
	var args := PackedStringArray()
	for a in OS.get_cmdline_args():
		if _langArg(a) == "":
			args.append(a)
	OS.set_restart_on_exit(true, args)
	(Engine.get_main_loop() as SceneTree).quit()

## Вызывается первым делом при запуске (SaveLoadSys._ready, до сохранений).
## true - игра сейчас перезапустится на другом языке, грузиться дальше нельзя.
## Порядок: ключ ярлыка; иначе при самом первом запуске - язык Windows
## (русский - RU, любой другой - EN). Из исходников (стенд) не срабатывает:
## там язык задаёт только override.cfg.
static func startupChoice() -> bool:
	if not OS.has_feature("template"):
		return false
	var want := ""
	for a in Array(OS.get_cmdline_args()) + Array(OS.get_cmdline_user_args()):
		var l := _langArg(String(a))
		if l != "":
			want = l
	if want == "" and not FileAccess.file_exists(choicePath()) and not FileAccess.file_exists("user://CONFIG.json"):
		want = "ru" if OS.get_locale_language() == "ru" else "en"
	if want == "" or want == code():
		return false
	if not writeChoice(want):
		push_warning("Lang: не удалось записать %s - папка игры защищена от записи" % choicePath())
		return false
	_restart()
	return true

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
## В RU словарь не грузится вовсе - t() возвращает текст как есть.
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

## --- Запросы к ИИ (EN-план, этап 3) ---
## Запросы собираются в llmManager/behavior из русских кусков. В EN-сборке
## готовый запрос проходит через tp(): каждый известный русский кусок
## заменяется английским (res://en/prompts.json, {"русский": "english"}).
## Куски с %s/%d/%.0f - шаблоны: превращаются в RegEx, значения
## переносятся в том же порядке. Длинные куски заменяются раньше коротких.
## Вызывается в llmManager._g() - через неё проходит каждый запрос.
const PROMPTS_PATH := "res://en/prompts.json"
static var _promptRules: Array = [] # [RegEx или null, ключ, перевод]
static var _promptsLoaded := false
static var _specRegex: RegEx = null

static func _loadPrompts() -> void:
	_promptsLoaded = true
	if not FileAccess.file_exists(PROMPTS_PATH):
		return
	var data = JSON.parse_string(FileAccess.get_file_as_string(PROMPTS_PATH))
	if not (data is Dictionary):
		return
	_specRegex = RegEx.create_from_string("%(?:\\.\\d)?[sdf]")
	var keys: Array = data.keys()
	keys.sort_custom(func(a, b): return String(a).length() > String(b).length())
	for k in keys:
		var en := String(data[k])
		if en == "" and String(k) != "":
			continue
		if _specRegex.search(k) == null:
			if String(k).length() <= 12 and not String(k).contains("\n"):
				# короткий кусок ("сок", "Ты") - только целым словом, иначе портит
				# слова вокруг ("высокомерно" -> "выjuiceомерно")
				var wre := RegEx.create_from_string("(?<![А-Яа-яЁё])" + _escapeRe(k) + "(?![А-Яа-яЁё])")
				if wre.is_valid():
					_promptRules.append([wre, k, en.replace("$", "$$")])
					continue
			_promptRules.append([null, k, en])
			continue
		# шаблон -> RegEx: текст экранируется, %s/%d/%.Nf -> группы
		var pattern := ""
		var last := 0
		for m in _specRegex.search_all(k):
			pattern += _escapeRe(k.substr(last, m.get_start() - last))
			pattern += "(-?[0-9]+(?:\\.[0-9]+)?)" if m.get_string() != "%s" else "([^\\n]*?)"
			last = m.get_end()
		pattern += _escapeRe(k.substr(last))
		var n := 0
		var repl := ""
		last = 0
		for m in _specRegex.search_all(en):
			n += 1
			repl += en.substr(last, m.get_start() - last).replace("$", "$$") + "$" + str(n)
			last = m.get_end()
		repl += en.substr(last).replace("$", "$$")
		var re := RegEx.create_from_string(pattern)
		if re.is_valid():
			_promptRules.append([re, k, repl])

static func _escapeRe(s: String) -> String:
	var out := ""
	for c in s:
		out += ("\\" + c) if "\\^$.|?*+()[]{}".contains(c) else c
	return out

## Перевод готового запроса (или его куска) на английский. RU - без изменений.
static func tp(text: String) -> String:
	if not isEn():
		return text
	if not _promptsLoaded:
		_loadPrompts()
	for r in _promptRules:
		if r[0] == null:
			if text.contains(r[1]):
				text = text.replace(r[1], r[2])
		else:
			text = (r[0] as RegEx).sub(text, r[2], true)
	return text
