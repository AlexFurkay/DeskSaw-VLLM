extends Node

#i probably shouldve put these here earlier but better late than never

## Номер сборки - в diagnostics.txt и для проверки, какая версия у тестера.
const BUILD := "054.9991Pru"

## 054.995: журнал фраз для вкладки «Фразы» в консоли (пользователи просили
## видеть, что персонажи говорили, - фраза над головой быстро исчезает).
signal phraseLogged(line: String)
const PHRASE_LOG_MAX := 200
var phraseLog: Array[String] = []

## Цвет строки во вкладке «Фразы»: цвет персонажа наполовину смешан с белым
## (054.996, по просьбе пользователя) - текст остаётся читаемым. Только в
## консоли, над головой фразы по-прежнему белые.
const PHRASE_COLORS := {
	"Dune": Color(1.0, 0.85, 0.0),       # жёлтый
	"Expie": Color(0.85, 0.4, 0.0),      # тёмно-оранжевый
	"Leapy": Color(0.1, 0.8, 0.1),       # зелёный
	"Milky": Color(1.0, 1.0, 1.0),       # белый
	"Orange": Color(1.0, 0.6, 0.0),      # оранжевый
	"Roza": Color(0.3, 0.75, 1.0),       # голубой
	"Velvet": Color(1.0, 0.1, 0.1),      # красный
	"VoyagerAlt": Color(0.6, 0.0, 1.0),  # фиолетовый (с белым - розоватый)
}
const PHRASE_PLAYER_COLOR := Color(0.72, 0.72, 0.72) # белый, но темнее Milky

## 054.997: цвет фразы над персонажем - на 15% насыщеннее, чем во вкладке
## «Фразы» (смесь с белым 0.575 вместо 0.5).
func phraseColor(skin: String, isPlayer: bool, strength: float = 0.5) -> Color:
	if isPlayer:
		return PHRASE_PLAYER_COLOR
	return Color.WHITE.lerp(PHRASE_COLORS.get(skin, Color(0.6, 0.85, 1.0)), strength)

func _phraseColorHex(skin: String, isPlayer: bool) -> String:
	if isPlayer:
		return PHRASE_PLAYER_COLOR.to_html(false)
	var base: Color = PHRASE_COLORS.get(skin, Color(0.6, 0.85, 1.0))
	return Color.WHITE.lerp(base, 0.5).to_html(false)

func logPhrase(who: String, text: String, skin: String = "", isPlayer: bool = false) -> void:
	var col := _phraseColorHex(skin, isPlayer)
	var line := "[color=gray]%s[/color]  [color=#%s]%s: %s[/color]" % [Time.get_time_string_from_system().substr(0, 5), col, who, text]
	phraseLog.append(line)
	while phraseLog.size() > PHRASE_LOG_MAX:
		phraseLog.pop_front()
	phraseLogged.emit(line)

var pop = preload("res://scenes/ui/popup.tscn")
#ill fix the scripts that redefine these when it bothers me enough
var screenWidth: int = DisplayServer.screen_get_usable_rect().size.x
var screenHeight: int = DisplayServer.screen_get_usable_rect().size.y

var taskbarPos: int = DisplayServer.screen_get_usable_rect().end.y

var clickZoneSum: int = 0
@warning_ignore("unused_signal")
signal persistenceWarning() # used to warn user if they have more than 20 expies stored in persistence save
signal raga()
@warning_ignore("unused_signal")
signal vulkanToggle()
signal skinswap()
signal resize()
signal pet(t: bool)
@warning_ignore("unused_signal")
signal console(t: bool)
signal raisemood(t: int)
signal feed(t: int)
#signal bus shit this probably has like one thing in it
func petf(t: bool):
	pet.emit(t)
func Fresize():
	resize.emit()
func ragaa():
	raga.emit()
func skinswapFunc(data):
	skinswap.emit(data)

func raisemoodF(t: int):
	raisemood.emit(t)

func feedf(t: int):
	feed.emit(t)

@warning_ignore("unused_signal") # for now, we use other scripts to emit these
signal TerminalOpenPressed(is_native: bool)
@warning_ignore("unused_signal")
signal dataNuked
#make this
func makePopUp(text: String, parent: CanvasLayer, position: Vector2) -> bool:
	#add the scene properly this time
	var newpop = pop.instantiate()
	parent.add_child(newpop)

	newpop.labelText = text

	#configure
	newpop.titleText = "Эй!"
	newpop.yesButtonText = "Да"
	newpop.noButtonText = "Нет"
	newpop.position = position
	#ts dont work
	newpop.size = Vector2(500, 300)
	#apply
	newpop.update_labels()
	newpop.update_buttons()


	var result = await newpop.hasPressedSignal

	newpop.queue_free()
	
	return result == CustomPopup.popupResultEnum.YES

"""
func makePopUp(text: String, parent: CanvasLayer, position: Vector2) -> bool:
	var path = "res://scenes/ui/popUp.tscn"
	var scene = load(path)
	var instance = scene.instantiate()
	parent.add_child(instance)
	instance.owner = parent
	instance.position = position
	var result: bool = await instance.setup(text)
	return result
"""
#just ignore this. pretend like i didnt waste time adding this and it just doesnt work
func _apply_renderer_and_restart(use_vulkan: bool) -> void:
	var method := "forward_plus" if use_vulkan else "gl_compatibility"
	ProjectSettings.set_setting("rendering/renderer/rendering_method", method)
	ProjectSettings.save()

	OS.set_restart_on_exit(true, OS.get_cmdline_args())

	gbData.settings.renderingMode = use_vulkan
	gbData.data["firstLaunch"] = false
	gbData.savetodisk("user://SAVE.json", gbData.data)
	gbData.savetodisk("user://CONFIG.json", gbData.settings)
	get_tree().quit()
#????????????????
var userSkinPath = "user://skin/Body/"


## Оставляет из строки только число. Раньше выбрасывалась и точка, и "60.0"
## превращалось в 600 (интервалы по умолчанию в 10 раз длиннее задуманного).
## Запятая тоже считается разделителем; пустая строка -> "0".
func getNumFromString(inputString: String):
	var number_string = ""
	var hasDot := false
	for i in range(inputString.length()):
		var character = inputString[i]
		if character.is_valid_int():
			number_string += character
		elif (character == "." or character == ",") and not hasDot and number_string != "":
			number_string += "."
			hasDot = true
	return number_string if number_string != "" else "0"


func checkpositive(num):
	if num is int or num is float:
		return num >= 0
	return false


func _process(_d: float) -> void:
	if Input.is_action_just_pressed("Open Terminal"):
		TerminalOpenPressed.emit(true)
