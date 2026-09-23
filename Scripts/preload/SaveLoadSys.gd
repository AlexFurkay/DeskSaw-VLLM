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


func _ready():
	# Настройки грузим ПЕРВЫМИ (было после сохранения) - иначе самый первый
	# персонаж на чистой установке создаётся до того, как defaultSkin вообще
	# прочитан, и молча получает "Default" вместо того, что реально задано.
	if FileAccess.file_exists(conPath):
		settings = loadjson(conPath)
		fixMissing(settings, loadjson("res://Scripts/singletons/config.json"))
	else:
		newConfig()

	# Load save file
	if FileAccess.file_exists(savePath):
		data = loadjson(savePath)
		var templateData = loadjson(template)
		fixMissing(data, templateData)

		for petId in data.get("saw", {}).keys():
			fixMissing(data["saw"][petId], templateData["sawTemplate"])
		if data.get("saw", {}).is_empty():
			addPet(settings.get("defaultSkin", "Default"))

	else:
		newsave()
	
	# Load translation file
	if FileAccess.file_exists(transPath):
		text = loadjson(transPath)
		fixMissing(text, loadjson("res://Scripts/singletons/TEMPDialogue.json"))
	else:
		newTrans()

	if DirAccess.dir_exists_absolute(skinfilepath):
		skinData = loadSkin()
	else:
		newSkinFile()

	_syncBundledSkins()



	InitAutosave()


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
				var fileData := FileAccess.get_file_as_bytes(srcPath)
				var out := FileAccess.open(dstPath, FileAccess.WRITE)
				if out:
					out.store_buffer(fileData)
					out.close()
					copiedCount += 1
				else:
					print("SYNC DEBUG: не смог записать %s" % dstPath)
		print("SaveLoadSys: добавлен новый зашитый скин '%s' (%d файлов скопировано из %d найденных)" % [skinName, copiedCount, realFiles])

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

	if not FileAccess.file_exists(skinFile):
		# Миграция со старого плоского расположения (user://<имя>TRANSLATION.json) -
		# на случай если игрок успел создать файл именно так до того, как
		# перевод и лор объединили внутри самой папки скина.
		var skinName: String = skinPath.trim_suffix("/").get_file()
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