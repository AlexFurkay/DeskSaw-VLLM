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
