extends Node

## Autoload: PlayerManager - персонаж-игрок (054P).
##
## Игрок - обычный питомец (sawianBase) с behavior.isPlayer = true: та же
## физика, урон, голод, сон, но без собственных ИИ-фраз (говорит только то,
## что напишет человек). Одновременно существует один игрок; новый
## заменяет старого вместе со статами и надетой одеждой.
##
## Управление включается/выключается глобальным сочетанием клавиш (по
## умолчанию Ctrl+Alt+P, команда change_player_mode) - оно работает, даже
## когда в фокусе другая программа (перехват в GlobalKeys.cs). В режиме
## управления: A/D или стрелки - ходьба, W/вверх/пробел - прыжок, Enter -
## открыть/отправить реплику, Esc - закрыть без отправки.
## Без управления - автопилот (обычные прогулки), через 3-5 минут игрок
## засыпает и спит, пока управление не включат снова.

const DEFAULT_KEYS := "Ctrl+Alt+P"
const LEFT_KEYS := [0x41, 0x25]       # A, стрелка влево
const RIGHT_KEYS := [0x44, 0x27]      # D, стрелка вправо
const JUMP_KEYS := [0x57, 0x26, 0x20] # W, стрелка вверх, пробел
const CHAT_MEMORY := 24 # реплик в памяти разговора (~12 обменов)
const CHAT_MAX_LENGTH := 200
const CHAT_REPLY_DISTANCE := 1600.0 # пикс экрана при petSize 4 - кто "рядом" и ответит

var player: Node = null # behavior.gd игрока
var playerSkin := ""
var playerName := ""
var controlled := false
var chatOpen := false
var chatText := ""
## Память разговора: [{"who": имя, "text": реплика}]. Сбрасывается, только
## если новый игрок другого скина.
var history: Array = []

var _keys: Node = null
var _chatLayer: CanvasLayer
var _chatLabel: Label
var _statusLabel: Label
var _statusUntil := 0


func _ready() -> void:
	_keys = get_node_or_null("/root/GlobalKeys")
	if _keys:
		var combo: String = String(gbData.settings.get("playerModeKeys", DEFAULT_KEYS))
		if not _keys.SetCombo(combo):
			_keys.SetCombo(DEFAULT_KEYS)
		_keys.connect("ToggleRequested", toggleControl)
		_keys.connect("EnterPressed", _onEnter)
		_keys.connect("TextChar", _onChar)
		_keys.connect("BackspacePressed", _onBackspace)
		_keys.connect("EscapePressed", _onEscape)
	_buildUi()


func currentKeys() -> String:
	return String(gbData.settings.get("playerModeKeys", DEFAULT_KEYS))


## Команда консоли change_player_mode.
func setKeys(combo: String) -> bool:
	if _keys == null or not _keys.SetCombo(combo):
		return false
	gbData.settings["playerModeKeys"] = combo
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	return true


func hasPlayer() -> bool:
	return player != null and is_instance_valid(player)


static func displayNameFor(skinName: String) -> String:
	if skinName == "" or skinName == "Body" or skinName == "Default":
		return "Experiment"
	# имя из паспорта (VoyagerAlt -> Voyager), иначе название папки
	for path in ["user://skin/%s/character.json" % skinName, "res://defaults/skins/%s/character.json" % skinName]:
		if FileAccess.file_exists(path):
			var data = JSON.parse_string(FileAccess.get_file_as_string(path))
			if data is Dictionary and String(data.get("name", "")) != "":
				return String(data["name"])
	return skinName


func spawnPlayer(skinPath: String, skinName: String) -> void:
	if hasPlayer():
		_removePlayer()
	if skinName != playerSkin:
		history.clear() # другой персонаж - другой разговор
	playerSkin = skinName
	playerName = displayNameFor(skinName)

	var prevSkinPath: String = GlobalVariable.userSkinPath # общий для всех спавнов - вернём после
	GlobalVariable.userSkinPath = skinPath
	var instance = load("res://scenes/sawianBase.tscn").instantiate()
	var saveSkin := "Body" if skinPath.begins_with("res://") else skinName
	var petId: String = gbData.addPet(saveSkin)
	gbData.data["saw"][petId]["player"] = true
	var beh = instance.get_node("behavior")
	beh.petId = petId
	beh.isPlayer = true

	var scene := get_tree().current_scene
	var wrapper := Node2D.new()
	wrapper.scale = Vector2.ONE * float(gbData.settings.get("petScale", 4.0))
	scene.add_child(wrapper)
	wrapper.owner = scene
	wrapper.add_child(instance)
	instance.owner = scene
	instance.global_position.x = float(GlobalVariable.screenWidth) / 2
	instance.global_position.y = -float(GlobalVariable.screenHeight) * 2
	wrapper.set_meta("Category", "entity")
	GlobalVariable.userSkinPath = prevSkinPath # скинмаппер игрока уже прочитал свой путь в _ready

	player = beh
	controlled = false
	_applyCapture()
	Console.print("Игрок: [color=CYAN]%s[/color]. Управление - [color=CYAN]%s[/color] (A/D - ходьба, W/пробел - прыжок, Enter - сказать)." % [playerName, currentKeys()])


## Персонаж, восстановленный из сейва с пометкой player (expiePersistence).
func adopt(beh: Node, skinName: String) -> void:
	if hasPlayer() and player != beh:
		return
	player = beh
	playerSkin = skinName
	playerName = displayNameFor(skinName)


func _removePlayer() -> void:
	if chatOpen:
		_closeChat()
	controlled = false
	_applyCapture()
	var pid: String = player.petId
	if gbData.data["saw"].has(pid):
		gbData.removePet(pid)
	var wrapper: Node = player.get_parent().get_parent() # обёртка Node2D -> sawianBase -> behavior
	wrapper.queue_free() # вместе с ним уходит и надетая одежда
	player = null


func toggleControl() -> void:
	if not hasPlayer():
		_showStatus("Сначала создай игрока: консоль -> Skins -> Spawn as player")
		return
	if player.isUnconscious:
		_showStatus("Игрок без сознания")
		return
	controlled = not controlled
	if not controlled and chatOpen:
		_closeChat()
	player.setPlayerControlled(controlled)
	_applyCapture()
	if controlled:
		_showStatus("Управление: ВКЛ  (A/D, W/пробел, Enter - сказать)")
	else:
		_showStatus("Управление: ВЫКЛ (автопилот)")


func _applyCapture() -> void:
	if _keys == null:
		return
	_keys.SetCaptureMovement(controlled and not chatOpen and hasPlayer())
	_keys.SetCaptureText(chatOpen)


func _process(_delta: float) -> void:
	if controlled and not hasPlayer():
		controlled = false # игрока удалили (despawnPet и т.п.)
		chatOpen = false
		_applyCapture()
	if controlled and not chatOpen and _keys:
		var dir := 0.0
		if _anyDown(RIGHT_KEYS):
			dir += 1.0
		if _anyDown(LEFT_KEYS):
			dir -= 1.0
		player.playerInput(dir, _anyDown(JUMP_KEYS))
	elif controlled:
		player.playerInput(0.0, false)

	if chatOpen and hasPlayer():
		_placeAbovePlayer(_chatLabel, 150.0)
	if _statusLabel.visible:
		if Time.get_ticks_msec() > _statusUntil:
			_statusLabel.visible = false
		elif hasPlayer():
			_placeAbovePlayer(_statusLabel, 200.0)


func _anyDown(keys: Array) -> bool:
	for k in keys:
		if _keys.IsKeyDown(k):
			return true
	return false


# ---------------- Чат ----------------

func _onEnter() -> void:
	if not controlled or not hasPlayer():
		return
	if chatOpen:
		_submitChat()
	else:
		chatOpen = true
		chatText = ""
		_updateChatLabel()
		_chatLabel.visible = true
		_applyCapture()


func _onChar(ch: String) -> void:
	if chatOpen and chatText.length() < CHAT_MAX_LENGTH:
		chatText += ch
		_updateChatLabel()


func _onBackspace() -> void:
	if chatOpen and chatText.length() > 0:
		chatText = chatText.left(chatText.length() - 1)
		_updateChatLabel()


func _onEscape() -> void:
	if chatOpen:
		_closeChat()


func _closeChat() -> void:
	chatOpen = false
	chatText = ""
	_chatLabel.visible = false
	_applyCapture()


func _submitChat() -> void:
	var text := chatText.strip_edges()
	_closeChat()
	if text == "" or not hasPlayer():
		return
	player.playerSay(text)
	_remember(playerName, text)

	var listener = _nearestListener()
	if listener == null:
		return
	var listenerName := displayNameFor(listener._skinTag())
	listener.replyToPlayer(playerName, history.duplicate(), func(reply: String): _remember(listenerName, reply))


func _remember(who: String, text: String) -> void:
	history.append({"who": who, "text": text})
	while history.size() > CHAT_MEMORY:
		history.pop_front()


## Ближайший ИИ-персонаж, который может ответить.
func _nearestListener() -> Node:
	var best: Node = null
	var bestDist: float = CHAT_REPLY_DISTANCE * float(gbData.settings.get("petScale", 4.0)) / 4.0
	var from: Vector2 = player.moveSys.rigidtorso.global_position
	for pet in get_tree().get_nodes_in_group("pets"):
		if pet == player or pet.isPlayer or pet.isUnconscious:
			continue
		var d: float = from.distance_to(pet.moveSys.rigidtorso.global_position)
		if d < bestDist:
			bestDist = d
			best = pet
	return best


# ---------------- Интерфейс ----------------

func _buildUi() -> void:
	_chatLayer = CanvasLayer.new()
	_chatLayer.layer = 50
	add_child(_chatLayer)
	_chatLabel = _makeLabel()
	_statusLabel = _makeLabel()


func _makeLabel() -> Label:
	var l := Label.new()
	l.visible = false
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size = Vector2(420, 0)
	l.add_theme_font_size_override("font_size", 20)
	l.add_theme_color_override("font_color", Color(1, 1, 1))
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	l.add_theme_constant_override("outline_size", 6)
	_chatLayer.add_child(l)
	return l


func _updateChatLabel() -> void:
	_chatLabel.text = "> " + chatText + "_"


func _showStatus(text: String) -> void:
	Console.print(text)
	_statusLabel.text = text
	_statusLabel.visible = true
	_statusUntil = Time.get_ticks_msec() + 3000
	if not hasPlayer():
		var vs := get_viewport().get_visible_rect().size
		_statusLabel.position = Vector2(vs.x / 2.0 - 210.0, vs.y / 2.0)


func _placeAbovePlayer(label: Label, height: float) -> void:
	var p: Vector2 = player.moveSys.rigidtorso.get_global_transform_with_canvas().origin
	label.position = Vector2(p.x - label.size.x / 2.0, p.y - height - label.size.y)
