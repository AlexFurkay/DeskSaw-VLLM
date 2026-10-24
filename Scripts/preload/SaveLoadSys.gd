extends Node


"""
i had to redo this because the hive mind bug was really weird
heres the saving stuffs.,

s[dfuiogh iopsdfg uioesfigsdhuiopashdfyg ioasfg oaisud f 9ASDYFH ASYUISDUIOFGSH G SDVPASPUHV ZSDG OASG PASRV ASG ASDFGSD GSDFXGB SDFGH SDF ASFZGASDFG SDFGG SDFG  3QTFGWE9RUGH9-SERG H3QER GUOH]

"""

var data = {}
var text = {}
var settings = {}

var dialogueCache = {}

var skinData = []

var template = "res://Scripts/singletons/SaveTemplate.json"


# DO NOT FORGET TO DISABLE THIS WHENBUILDING 
var devMode = false
#turns out you can literally make a custom project setting that does something like this
#but im too  in too deep to go back now

const savePath = "user://SAVE.json"
const transPath = "user://TRANSLATION.json"
const conPath = "user://CONFIG.json"
const skinfilepath = "user://skin"


## Форк хранит данные в своей папке (%APPDATA%\DDnAKFRK\DeskSawVLLM), чтобы не
## конфликтовать со стоковым DeskSaw (deedee14\desksawPRE-RELEASE). При первом
## запуске новой версии всё из старой папки КОПИРУЕТСЯ (не переносится -
## стоковый DeskSaw остаётся со своими данными).
const OLD_DATA_DIR := "deedee14/desksawPRE-RELEASE"

## События запуска (перенос данных, обновления скинов) - для diagnostics.txt
var startupNotes: Array = []
func _note(msg: String) -> void:
	print(msg)
	startupNotes.append(msg)

func _migrateOldDataDir() -> void:
	if FileAccess.file_exists("user://CONFIG.json") or FileAccess.file_exists("user://SAVE.json"):
		return # уже есть свои данные
	var oldRoot := OS.get_data_dir().path_join(OLD_DATA_DIR)
	if not DirAccess.dir_exists_absolute(oldRoot):
		return
	var copied := _copyDirRecursive(oldRoot, ProjectSettings.globalize_path("user://"))
	_note(Lang.t("SaveLoadSys: данные перенесены из %s (%d файлов)") % [oldRoot, copied])


func _copyDirRecursive(from: String, to: String) -> int:
	var count := 0
	DirAccess.make_dir_recursive_absolute(to)
	var dir := DirAccess.open(from)
	if dir == null:
		return 0
	for f in dir.get_files():
		if DirAccess.copy_absolute(from.path_join(f), to.path_join(f)) == OK:
			count += 1
	for sub in dir.get_directories():
		if sub in ["logs", "shader_cache", "objectdb_snapshots"]:
			continue # служебное, не нужно
		count += _copyDirRecursive(from.path_join(sub), to.path_join(sub))
	return count


func _ready():
	_migrateOldDataDir()
	# Настройки грузим ПЕРВЫМИ (было после сохранения) - иначе самый первый
	# персонаж на чистой установке создаётся до того, как defaultSkin вообще
	# прочитан, и молча получает "Default" вместо того, что реально задано.
	if FileAccess.file_exists(conPath):
		settings = loadjson(conPath)
		# 054.995: галочку «Неуязвимость» убрали из настроек - сбрасываем, чтобы
		# включённая раньше неуязвимость не осталась навсегда без способа выключить
		if settings is Dictionary:
			settings["invincible"] = false
		fixMissing(settings, loadjson("res://Scripts/singletons/config.json"))
	else:
		newConfig()

	# Load save file
	if FileAccess.file_exists(savePath):
		data = loadjson(savePath)
		var templateData = loadjson(template)
		fixMissing(data, templateData)
		# Шаблон нового питомца лежит копией в SAVE.json игрока, и fixMissing
		# не обновляет уже существующие поля - стартовое настроение берём из
		# шаблона сборки, иначе его изменение не дошло бы до старых сейвов.
		if data.get("sawTemplate") is Dictionary and templateData.get("sawTemplate") is Dictionary:
			data["sawTemplate"]["mood"] = templateData["sawTemplate"].get("mood", 70.0)

		for petId in data.get("saw", {}).keys():
			fixMissing(data["saw"][petId], templateData["sawTemplate"])
		if data.get("saw", {}).is_empty():
			addPet(settings.get("defaultSkin", "Default"))

	else:
		newsave()
	
	# Load translation file
	if FileAccess.file_exists(transPath):
		text = loadjson(transPath)
		fixMissing(text, loadjson(Lang.localize("res://Scripts/singletons/TEMPDialogue.json")))
	else:
		newTrans()

	if DirAccess.dir_exists_absolute(skinfilepath):
		skinData = loadSkin()
	else:
		newSkinFile()

	_syncBundledSkins()



	InitAutosave()


func _skinVersion(charJsonPath: String) -> int:
	charJsonPath = Lang.localize(charJsonPath) # EN: паспорт из en/, если есть
	if not FileAccess.file_exists(charJsonPath):
		return 0
	var data = JSON.parse_string(FileAccess.get_file_as_string(charJsonPath))
	return int(data.get("version", 0)) if data is Dictionary else 0


func _skinTextVersion(charJsonPath: String) -> int:
	charJsonPath = Lang.localize(charJsonPath)
	if not FileAccess.file_exists(charJsonPath):
		return 0
	var data = JSON.parse_string(FileAccess.get_file_as_string(charJsonPath))
	return int(data.get("textVersion", 0)) if data is Dictionary else 0


## Обновление фраз и лора скина: если в паспорте сборки "textVersion" выше,
## чем у игрока, старые TRANSLATION.json и lore.txt сохраняются рядом
## (*.bak-textN) и заменяются новыми; паспорт тоже копируется, иначе
## замена повторялась бы на каждом запуске.
func _updateSkinTexts(srcRoot: String, dstRoot: String, skinName: String) -> void:
	var newVer := _skinTextVersion(srcRoot + "/character.json")
	var oldVer := _skinTextVersion(dstRoot + "/character.json")
	if newVer <= 0 or oldVer >= newVer:
		return
	for fileName in ["TRANSLATION.json", "lore.txt", "character.json"]:
		var srcPath: String = Lang.localize(srcRoot + "/" + fileName)
		if not FileAccess.file_exists(srcPath):
			continue
		var dstPath: String = dstRoot + "/" + fileName
		if fileName != "character.json" and FileAccess.file_exists(dstPath):
			DirAccess.copy_absolute(dstPath, "%s.bak-text%d" % [dstPath, oldVer])
		var out := FileAccess.open(dstPath, FileAccess.WRITE)
		if out:
			out.store_buffer(FileAccess.get_file_as_bytes(srcPath))
			out.close()
	_note(Lang.t("SaveLoadSys: фразы и лор скина '%s' обновлены до версии текстов %d (старые - *.bak-text%d)") % [skinName, newVer, oldVer])


## Обновление существующего скина: только картинки + character.json.
func _copySkinFiles(srcRoot: String, dstRoot: String, onlyArtAndPassport: bool) -> int:
	var srcDir := DirAccess.open(srcRoot)
	if srcDir == null:
		return 0
	var count := 0
	var entries := srcDir.get_files()
	for entryName in entries:
		var fileName: String = entryName.trim_suffix(".import")
		if fileName != entryName and fileName in entries:
			continue
		var ext := fileName.get_extension().to_lower()
		if onlyArtAndPassport and not (ext in ["png", "jpg", "jpeg"] or fileName == "character.json"):
			continue
		var srcPath := srcRoot + "/" + fileName
		var dstPath := dstRoot + "/" + fileName
		if ext in ["png", "jpg", "jpeg"]:
			var tex: Texture2D = load(srcPath)
			if tex and tex.get_image().save_png(dstPath) == OK:
				count += 1
		else:
			var out := FileAccess.open(dstPath, FileAccess.WRITE)
			if out:
				out.store_buffer(FileAccess.get_file_as_bytes(Lang.localize(srcPath)))
				out.close()
				count += 1
	return count


## Копирует в user://skin/ любые скины, зашитые в саму сборку под
## res://defaults/skins/<Имя>/, которых у игрока ещё НЕТ. Вызывается на
## КАЖДОМ запуске (не только первом) - так при обновлении, добавляющем
## нового Sawian-персонажа, он просто появится у всех существующих игроков
## сам, а уже настроенные/изменённые игроком скины никто не трогает и не
## перезаписывает (копируется только то, чего не хватает целиком).
func _syncBundledSkins() -> void:
	var bundledRoot := "res://defaults/skins"
	var dir := DirAccess.open(bundledRoot)
	if dir == null:
		print("SYNC DEBUG: res://defaults/skins не найдена вообще (DirAccess.open вернул null)")
		return # пока ничего не зашито - ничего не делаем, старое поведение не меняется

	var skinNames := dir.get_directories()
	print("SYNC DEBUG: найдены зашитые скины: ", skinNames)

	for skinName in skinNames:
		var userSkinDir: String = skinfilepath + "/" + skinName
		if DirAccess.dir_exists_absolute(userSkinDir):
			# Обновление скина: если в паспорте сборки "version" выше, чем у игрока,
			# перезаписываем ТЕКСТУРЫ и паспорт (фразы и лор не трогаем - вдруг
			# игрок их правил). Без поля version скин не обновляется никогда.
			# обе версии читаем ДО копирования - каждое обновление перезаписывает паспорт
			var bundledVer := _skinVersion(bundledRoot + "/" + skinName + "/character.json")
			var needArt: bool = bundledVer > 0 and _skinVersion(userSkinDir + "/character.json") < bundledVer
			_updateSkinTexts(bundledRoot + "/" + skinName, userSkinDir, skinName)
			if needArt:
				var updated := _copySkinFiles(bundledRoot + "/" + skinName, userSkinDir, true)
				_note(Lang.t("SaveLoadSys: скин '%s' обновлён до версии %d (%d файлов)") % [skinName, bundledVer, updated])
			else:
				print("SYNC DEBUG: '%s' - у игрока уже есть папка, пропускаю" % skinName)
			continue # у игрока уже есть эта папка - не трогаем, вдруг он сам её менял

		var madeDir := DirAccess.make_dir_recursive_absolute(userSkinDir)
		if madeDir != OK:
			print("SYNC DEBUG: '%s' - не смог создать папку %s (код %d)" % [skinName, userSkinDir, madeDir])
			continue

		var srcDir := DirAccess.open(bundledRoot + "/" + skinName)
		if srcDir == null:
			print("SYNC DEBUG: '%s' - не смог открыть исходную папку" % skinName)
			continue
		var copiedCount := 0
		var realFiles := 0
		var allEntries := srcDir.get_files()
		for entryName in allEntries:
			# В собранной игре PNG (и вообще любой импортируемый Godot тип)
			# не виден в листинге папки под своим настоящим именем "*.png" -
			# видна только служебная метка "*.png.import" рядом с ним, а
			# сам файл читается через load() по ОРИГИНАЛЬНОМУ имени (Godot
			# сам подставляет за кулисами скомпилированную версию). Поэтому
			# настоящее имя мы восстанавливаем ИЗ .import-файла, а не
			# пропускаем его как мусор.
			var fileName: String = entryName.trim_suffix(".import") if entryName.ends_with(".import") else entryName
			if fileName != entryName and fileName in allEntries:
				continue # у этого файла есть и сам файл, и .import - не считаем дважды, обработаем по настоящему имени в своём проходе
			realFiles += 1
			var srcPath: String = bundledRoot + "/" + skinName + "/" + fileName
			var dstPath: String = userSkinDir + "/" + fileName

			if fileName.get_extension().to_lower() in ["png", "jpg", "jpeg"]:
				# В экспортированной сборке PNG под res:// компилируется в
				# внутренний формат текстур Godot - сырых байт исходного
				# файла там больше нет, копировать их напрямую бессмысленно
				# (получались бы .import-файлы вместо картинок). Грузим как
				# ресурс (по восстановленному имени) и заново сохраняем как
				# настоящий PNG.
				var tex: Texture2D = load(srcPath)
				var img: Image = tex.get_image() if tex else null
				if img and img.save_png(dstPath) == OK:
					copiedCount += 1
				else:
					print("SYNC DEBUG: не смог перекодировать картинку %s" % srcPath)
			else:
				var fileData := FileAccess.get_file_as_bytes(Lang.localize(srcPath)) # EN: текст из en/, если есть
				var out := FileAccess.open(dstPath, FileAccess.WRITE)
				if out:
					out.store_buffer(fileData)
					out.close()
					copiedCount += 1
				else:
					print("SYNC DEBUG: не смог записать %s" % dstPath)
		_note(Lang.t("SaveLoadSys: добавлен новый зашитый скин '%s' (%d файлов скопировано из %d найденных)") % [skinName, copiedCount, realFiles])

#this bug fuxking sucks so im removing it once and for all
#automatically detect if the user is missing a setting or something related to that
#should fix the shocked face bug PERMANANTLY
func fixMissing(base: Dictionary, default: Dictionary):

	for key in default.keys():
		if not base.has(key):
			if typeof(default[key]) == TYPE_DICTIONARY:
				base[key] = default[key].duplicate(true)
			else:
				base[key] = default[key]

		elif typeof(base[key]) == TYPE_DICTIONARY and typeof(default[key]) == TYPE_DICTIONARY:
			fixMissing(base[key], default[key])


func newsave():
	# Read the save template
	if not ResourceLoader.exists(template):
		print("template not found at: ", template)
		return


	var keepAcrossSaves = data.get("everPresentAcrossSaves", null)

	#set data json to template
	data = loadjson(template).duplicate(true)

	if keepAcrossSaves != null:
		data["everPresentAcrossSaves"] = keepAcrossSaves
	#apparentally that function does nothing and hasnt done anything for a while??? or people are just lysing to me.
	#randomize()

#	what does ts even do
	#pingpong()
	var firstPetId = addPet(settings.get("defaultSkin", "Default"))
	data["saw"][firstPetId]["mood"] += randi_range(-5, 5)
	data["saw"][firstPetId]["hunger"] -= randi_range(1, 5)
	data["saw"][firstPetId]["trust"] += randi_range(-10, 0)

	savetodisk(savePath, data)


func addPet(skin: String = "Default") -> String:
	var newId = "id" + str(int(data.get("nextPetId", 1)))
	data["nextPetId"] = int(data.get("nextPetId", 1)) + 1

	data["saw"][newId] = data["sawTemplate"].duplicate(true)
	data["saw"][newId]["skin"] = skin
	# случайное стартовое настроение: каждый новый персонаж приходит немного по-своему
	data["saw"][newId]["mood"] = snappedf(randf_range(45.0, 65.0), 0.05)


	savetodisk(savePath, data)
	return newId


func removePet(id: String) -> void:
	if not data.get("saw", {}).has(id):
		return
	data["saw"].erase(id)
	data["everPresentAcrossSaves"]["PetsKilled"] += 1
	savetodisk(savePath, data)

func newTrans():
	#fix this later make it bassdfjogsdjfoigjsdfgjosdifgjiosdfjg nvm its good as it
	# Если в саму сборку зашит настоящий TRANSLATION.json (res://defaults/) -
	# новый игрок сразу получает его, а не голую generic-заглушку.
	var defaultTrans := "res://Scripts/singletons/TEMPDialogue.json"
	if ResourceLoader.exists("res://defaults/TRANSLATION.json"):
		defaultTrans = "res://defaults/TRANSLATION.json"
	defaultTrans = Lang.localize(defaultTrans)

	text = loadjson(defaultTrans).duplicate(true)
	savetodisk(transPath, text)

func newConfig():
	var configFile = "res://Scripts/singletons/config.json"

	settings = loadjson(configFile).duplicate(true)
	savetodisk(conPath, settings)

func newSkinFile():
	var readMeF = skinfilepath + "/READ.txt"
	

	if not DirAccess.dir_exists_absolute(skinfilepath):
		var error = DirAccess.make_dir_recursive_absolute(skinfilepath)
		
		if error == OK:
			var txt = FileAccess.open(readMeF, FileAccess.WRITE)
			

			if txt:
				txt.store_line("""Drop the Body folder of your skin into this folder!


In theory, everything on https://skin.cat-bot.de/ should be compatible with this!

If you want multiple skins, just rename your 'Body' folder to whatever you want to call it, then use the skin spawner.
(however you have to keep a 'Body' folder with any skin in it for it to work!)
If you have both a 'Body' and 'Head' folder, combine the files inside them into a new folder and drag them in here.

If your skin is only on the head, try restarting the app. That usually fixes it.

If you want custom dialogue for a specific skin, just copy the 'TRANSLATION.json' file from outside the folder and paste it into skin’s folder!
Skin with TRANSLATION.json file will use it's own dialogue instead of the default one.
""")
				txt.close()
	
	var folder_to_copy = "res://assets/Body"
	
	var new_dir_path: String = "user://skin/Body"
	DirAccess.make_dir_absolute(new_dir_path)
	
	#Copy each file and folder into the new folder
	var old_files: PackedStringArray = DirAccess.get_files_at(folder_to_copy)
	for f: String in old_files:
		# only copy images
		if !f.get_extension().to_lower() == "png":
			continue
		DirAccess.copy_absolute(folder_to_copy + "/" + f, new_dir_path + "/" + f)
	#var old_directories: PackedStringArray = DirAccess.get_directories_at(folder_to_copy)


func loadSkin():
		var _ifliterallyanythingisthere = false
		var added = []
		var pt = skinfilepath + "/Body"
		if DirAccess.dir_exists_absolute(pt):
			var files = DirAccess.get_files_at(pt)
			for file in files:
				if file.get_extension().to_lower() == "png":
					_ifliterallyanythingisthere = true
					added.append(pt.path_join(file))
			
		return added


# my favorite helpers!
#theyre gone nvm
func loadjson(filepath: String):
	if FileAccess.file_exists(filepath):
		var datafile = FileAccess.open(filepath, FileAccess.READ)
		var parsedresult = JSON.parse_string(datafile.get_as_text())
		if parsedresult is Dictionary:
			return parsedresult
		else:
			if gbData.devMode:
				print("Error parsing JSON file: " + filepath)
			return {}
	else:
		if gbData.devMode:
			print("File not found: " + filepath)
		return {}

# looks for a TRANSLATION.json in the skin folder, falls back to the global one
func getDialogueForSkin(skinPath: String):
	if skinPath.begins_with("res:"):
		return text.diaGlobal
	if dialogueCache.has(skinPath):
		return dialogueCache[skinPath]
	var merged = text.diaGlobal.duplicate(true)
	var skinFile = skinPath + "TRANSLATION.json"
	var skinName: String = skinPath.trim_suffix("/").get_file()

	# Категории из зашитой в сборку версии скина (res://defaults/skins/<Имя>/) -
	# _syncBundledSkins() не трогает уже существующую папку игрока, поэтому
	# новые категории из обновления (например healed) иначе никогда бы до
	# него не дошли. Файл игрока ниже всё равно перекрывает эти значения,
	# так что его собственные правки сохраняются.
	var bundledFile := Lang.localize("res://defaults/skins/%s/TRANSLATION.json" % skinName)
	if FileAccess.file_exists(bundledFile):
		var bundledText = loadjson(bundledFile)
		if bundledText is Dictionary and bundledText.get("diaGlobal") is Dictionary:
			for key in bundledText["diaGlobal"]:
				merged[key] = bundledText["diaGlobal"][key]

	if not FileAccess.file_exists(skinFile):
		# Миграция со старого плоского расположения (user://<имя>TRANSLATION.json) -
		# на случай если игрок успел создать файл именно так до того, как
		# перевод и лор объединили внутри самой папки скина.
		var oldFlatFile := "user://%sTRANSLATION.json" % skinName.to_lower()
		if FileAccess.file_exists(oldFlatFile):
			var oldFile := FileAccess.open(oldFlatFile, FileAccess.READ)
			var oldText := oldFile.get_as_text()
			oldFile.close()
			var newFile := FileAccess.open(skinFile, FileAccess.WRITE)
			if newFile:
				newFile.store_string(oldText)
				newFile.close()

	if FileAccess.file_exists(skinFile):
		var skinText = loadjson(skinFile)
		if skinText is Dictionary and skinText.get("diaGlobal") is Dictionary:
			for key in skinText["diaGlobal"]:
				merged[key] = skinText["diaGlobal"][key]
			dialogueCache[skinPath] = merged
	return merged

func savetodisk(path, dt):
		var file = FileAccess.open(path, FileAccess.WRITE)
		if file:
			var json_string = JSON.stringify(dt, "\t")
			file.store_line(json_string)
			file.close()


func InitAutosave():
	while true:
		await get_tree().create_timer(3.0).timeout
		if gbData.devMode:
			print("saved")

		savetodisk(savePath, data)
		savetodisk(conPath, settings)


func killEverything():
	newsave()
	newTrans()
	newSkinFile()
	newConfig()

## 054.998, команда full_reset: всё к стоковым значениям этой сборки, кроме
## выбранной модели и её настроек. Папки 8 встроенных персонажей заменяются
## версиями из сборки (старые - в full_reset_backup/<время>/, на всякий случай).
## Персонажи, добавленные пользователем, и логи не трогаются.
const FULL_RESET_KEEP := ["llmModelName", "llmCreativity", "llmRepetitionGuard"]

func fullReset() -> String:
	var keep := {}
	for k in FULL_RESET_KEEP:
		if settings.has(k):
			keep[k] = settings[k]
	newConfig() # сначала настройки: newsave() создаёт персонажа из defaultSkin
	for k in keep:
		settings[k] = keep[k]
	savetodisk(conPath, settings)
	newsave()
	newTrans()
	var backupRoot := "user://full_reset_backup/" + Time.get_datetime_string_from_system().replace(":", "-")
	var dir := DirAccess.open("res://defaults/skins")
	if dir:
		for skinName in dir.get_directories():
			var userSkinDir: String = skinfilepath + "/" + skinName
			if DirAccess.dir_exists_absolute(userSkinDir):
				DirAccess.make_dir_recursive_absolute(backupRoot)
				DirAccess.rename_absolute(userSkinDir, backupRoot + "/" + skinName)
	_syncBundledSkins() # папок нет - скопируются начисто из сборки
	return ProjectSettings.globalize_path(backupRoot)


func outdated():
	if settings.outdated:
		print("already outdated")
		return
	settings.outdated = true
	killEverything()

func checkupdated():
	if !settings.outdated: return
	print("version is current")
	settings.outdated = false

@warning_ignore("unused_signal") # called externally
signal SettingsChanged()

# used for getting settings in csharp scripts
# let me know if there's a better way to do this
func GetSetting(key: String, default):
	return settings.get(key, default) 