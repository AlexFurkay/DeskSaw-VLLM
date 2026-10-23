extends Node
class_name Dialogue

const ORIGINAL_TEXT_COLOR := Color(0.97141486, 0.76168233, 0, 1)
## 054.999: звук печатания текста на 20% тише у всех (просьба Alex).
const SPEECH_GAIN_DB := -1.94 # linear_to_db(0.8)

var data
@onready var dialogueTimer = $dialogueTimer
@export var richtextlabel: RichTextLabel
@export var textspeed: float = 0.04
var pause: Array = [",", ".", "!"]
var vowls: Array = ["A", "E", "I", "O", "U", "a", "e", "i", "o", "u"]
var bb: Array = ["[shake]", "[wave]"]
var isTyping: bool = false
var pool: Array = []
var speedMod: float = 1.0
## Во сколько раз дольше реплика висит на экране после печати (у перса-игрока 1.5).
var holdMultiplier: float = 1.0

signal starttalking()
signal stoptalking()

var tre: int = 0

@export var fasdfasdfasddfas: Node
var passive_timer: SceneTreeTimer = null

## Text Sound Variables:
var base_db: float = -10 # Set base audio level of text
var variance_db: float = 3.0

func _ready() -> void:
	data = gbData.getDialogueForSkin(GlobalVariable.userSkinPath)
	richtextlabel.add_theme_font_size_override("normal_font_size", gbData.settings.expieDialogueSize)
	print("LOADED DIALOGUE KEYS: ", data.keys())

	
func typeOut(string: String, speed_multiplier: float = 1.0):
	if gbData.settings.get("mute", false): return

	tre += 1
	var h = tre

	richtextlabel.add_theme_font_size_override("normal_font_size", gbData.settings.expieDialogueSize)
	# 054.997: цвет персонажа над головой (как во вкладке «Фразы», на 15% насыщеннее)
	var owner_beh = get_parent()
	# 054.9991: галочка "Цветной текст у фраз" (Настройки - Общее); во вкладке Фразы - всегда цветной
	if owner_beh and owner_beh.has_method("_skinTag") and gbData.settings.get("phraseColorOnDesk", true):
		richtextlabel.add_theme_color_override("default_color", GlobalVariable.phraseColor(owner_beh._skinTag(), owner_beh.isPlayer, 0.575))
	elif owner_beh and owner_beh.has_method("_skinTag") and owner_beh.isPlayer:
		richtextlabel.add_theme_color_override("default_color", GlobalVariable.phraseColor(owner_beh._skinTag(), true, 0.575))
	else:
		# исходный жёлто-оранжевый DeskSaw (без override брался синий цвет темы)
		richtextlabel.add_theme_color_override("default_color", ORIGINAL_TEXT_COLOR)
	isTyping = true
	richtextlabel.text = string
	richtextlabel.visible_characters = 0
	_avoidOverlap()

	starttalking.emit()

	AudioServer.set_bus_mute(AudioServer.get_bus_index("Text"), not gbData.settings.dialogueSoundEnabled) # Update bus if sound is muted or not

	var i = 0
	while i < string.length():
		if tre != h: return

		if string[i] == "[":
			while i < string.length() and string[i] != "]":
				i += 1
			i += 1
			continue

		richtextlabel.visible_characters += 1
		var current_char = string[i]

		var wait = textspeed * speed_multiplier
		if current_char in pause:
			wait *= 8

		var speechSound: AudioStream = get_parent().voiceSet.get("speech", AudioManager.speech)
		AudioManager.play_sfx(speechSound, 0.75, base_db + SPEECH_GAIN_DB + randf_range(-variance_db, variance_db), 1 + randf_range(-.2, .2), false, 0.5, "", "Text")
		await get_tree().create_timer(wait).timeout
		i += 1

	if tre != h: return

	isTyping = false
	stoptalking.emit()
	await get_tree().create_timer(string.length() * 0.2 * holdMultiplier).timeout

	if tre == h:
		richtextlabel.visible_characters = 0

func stupify(input: String) -> String:
	var chance = .2
	var rng = RandomNumberGenerator.new()
	rng.randomize()
	var text = input


	var result = ""
	var words := text.split(" ")

	for wo in words.size():
		var word = words[wo]
		var _ex = ""
		var in_tag = false

		for i in word.length():
			var c = word[i]

			if c == "[":
				in_tag = true
				_ex += c
				continue
			if c == "]":
				in_tag = false
				_ex += c
				continue
			if in_tag:
				_ex += c
				continue

			#stuttering. randomly repeat a letter occasionally
			if i == 0 and rng.randf() < chance:
				_ex += c + "-"

			if rng.randf() < chance:
				c = c.to_upper()

			_ex += c

			# extend vowels
			if rng.randf() < chance:
				var extejnd = rng.randi_range(1, 3)
				if vowls.has(c):
					_ex += c.repeat(extejnd)

		result += _ex
		if wo < words.size() - 1:
			result += " "

	return result

func send(cooldown: float = 0.0, ignoreCooldown: bool = true) -> void:
	if (not dialogueTimer.is_stopped() or isTyping) and not ignoreCooldown:
		print("THE EXPIE IS OVERSTIMULATED HE WON'T TALK")
		return
	if self.get_parent().isSleeping:
		print("sleeping")
		return
	if pool.size() > 0:
		var text: String = pool.pick_random()
		var effectiveSpeed = speedMod

		if text.find("[stupid]") != -1:
			text = text.replace("[stupid]", "")
			text = stupify(text)
			effectiveSpeed -= .3

		typeOut(text, effectiveSpeed)

		await stoptalking

		if cooldown > 0.0:
			dialogueTimer.start(cooldown)


func setDia(stra: String, speed: float, cooldown: float = 0.0, ignoreCooldown: bool = true) -> void:
	if (not dialogueTimer.is_stopped() or isTyping) and not ignoreCooldown:
		print("THE EXPIE IS OVERSTIMULATED HE WON'T TALK")
		return

	typeOut(stra, speed)
	await stoptalking

	if cooldown > 0.0:
		dialogueTimer.start(cooldown)

## 054.9992: две фразы рядом налезали друг на друга - новая фраза поднимается над чужой.
## 055.003 (скрины Alex): 1) налезание вернулось - чужая фраза считалась видимой только
## пока печаталась, а допечатанная и висящая - нет; 2) длинная фраза уходила вниз под
## панель задач - высота отсчитывалась от размера ПРЕДЫДУЩЕЙ фразы, «пол» съезжал.
## Теперь: низ фразы всегда на одном месте над головой (_baseBottom, из сцены), фраза
## растёт вверх; не вылезает за края окна; проверка идёт всё время, пока фраза видна
## (персонаж мог упасть/сесть/сдвинуться). Сдвигается только более НОВАЯ фраза.
var _baseBottom := INF
var _startedAt := 0

func isShowing() -> bool:
	return richtextlabel.visible and richtextlabel.text.strip_edges() != "" and (isTyping or richtextlabel.visible_characters != 0)

func _avoidOverlap() -> void:
	_startedAt = Time.get_ticks_msec()
	var h := tre
	await get_tree().process_frame
	while is_instance_valid(richtextlabel) and tre == h and isShowing():
		_placeLabel()
		await get_tree().create_timer(0.1).timeout


func _placeLabel() -> void:
	if _baseBottom == INF:
		_baseBottom = BASE_LABEL_BOTTOM
	richtextlabel.position.y = _baseBottom - richtextlabel.size.y
	for _pass in 3:
		var mine := richtextlabel.get_global_rect()
		var moved := false
		for pet in get_tree().get_nodes_in_group("pets"):
			var other = pet.get("dialogueSys")
			if other == null or other == self or not is_instance_valid(other) or not other.isShowing():
				continue
			if other._startedAt > _startedAt:
				continue # двигается более новая фраза, не эта
			var r: Rect2 = other.richtextlabel.get_global_rect()
			if r.intersects(mine):
				richtextlabel.global_position.y += r.position.y - mine.end.y - 4.0
				moved = true
				break
		if not moved:
			break
	# в пределах окна (окно игры = рабочая область экрана над панелью задач)
	var view := get_viewport().get_visible_rect()
	var box := richtextlabel.get_global_rect()
	if box.end.y > view.end.y - 4.0:
		richtextlabel.global_position.y -= box.end.y - (view.end.y - 4.0)
		box = richtextlabel.get_global_rect()
	if box.position.y < view.position.y + 4.0:
		richtextlabel.global_position.y += view.position.y + 4.0 - box.position.y

## Низ фразы в textParent - offset_bottom из sawianBase.tscn (RichTextLabel).
const BASE_LABEL_BOTTOM := -5.2512627


func is_dialogue_playing() -> bool:
	return isTyping
