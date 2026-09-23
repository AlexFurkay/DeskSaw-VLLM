extends Node

@export var eyeNode: Sprite2D
@export var headNode: Sprite2D
@export var loadedspritesData: Node
@export var dialogue: Node

@export var backtoggle: Node


var currentEmotion := "sad"
var talking := false
var blinking := false

var eyes = {
	"normal": {"open": "experimentEyeOpen.png", "closed": "experimentEyeClosed.png", "back": "experimentEyeLookBack.png"},
	"sad": {"open": "experimentEyeSad.png", "closed": "experimentEyeClosed.png", "back": "experimentEyeSadBack.png"},
	"sleep": {"open": "experimentEyeClosed.png", "closed": "experimentEyeClosed.png", "back": "experimentEyeClosed.png"},
	"tired": {"open": "experimentEyeHalfClosed.png", "closed": "experimentEyeClosed.png", "back": "experimentEyeClosed.png"},
	"scared": {"open": "experimentEyeScared.png", "closed": "experimentEyeClosed.png", "back": "experimentEyeHalfClosedBack.png"},
	"panic": {"open": "experimentEyePanic.png", "closed": "experimentEyePanic.png", "back": "experimentEyePanic.png"},
	"happy": {"open": "experimentEyeHappy.png", "closed": "experimentEyeHappy.png", "back": "experimentEyeHappy.png"},
}

var heads = {
	"default": "experimentHeadBack.png",
	"open": "experimentHeadBackMouth.png",
	"opensmall": "experimentHeadBackMouthMini.png",
	"disfigured": "experimentHeadDisfigured2.png",
}

## 0 = голова здорова, 1/2/3 = степень травмы - behavior.gd обновляет это
## из _applyInjuryLook(), чтобы анимация рта (talkLoop/stopTalking) могла
## показывать травмированный рот вместо здорового во время речи, а не
## только после её окончания.
var currentInjuryTier := 0

func setInjuryTier(tier: int) -> void:
	currentInjuryTier = tier

## Пробует "ИмяDisfiguredN.png" для текущей степени травмы, и если такого
## кадра ещё не нарисовано - тихо откатывается на обычный, здоровый кадр
## (это ключ из heads{}, не сам файл). Голова по умолчанию рисуется как
## "...Back.png" (без "Disfigured" в исходном имени вообще), а файлы травм
## называются без "Back" - пробуем оба варианта на всякий случай.
func _headTextureFor(key: String) -> String:
	var base: String = heads[key]
	if currentInjuryTier <= 0:
		return base
	var ext := base.get_extension()
	var stem := base.get_basename()
	var candidates := [
		"%sDisfigured%d.%s" % [stem, currentInjuryTier, ext],
	]
	if stem.contains("Back"):
		var stripped := stem.replace("Back", "")
		candidates.append("%sDisfigured%d.%s" % [stripped, currentInjuryTier, ext])
	for candidate in candidates:
		if _hasTexture(candidate):
			return candidate
	return base # для этого конкретного кадра рта травма ещё не нарисована - остаёмся на здоровом, лучше так, чем ничего не показать

func _hasTexture(texture_name: String) -> bool:
	for entry in loadedspritesData.alltextures:
		if entry["name"] == texture_name:
			return true
	return false

func _ready() -> void:
	setEmotion("normal")
	blinkLoop()
	eyedir()
	dialogue.starttalking.connect(startTalking)
	dialogue.stoptalking.connect(stopTalking)


func setEmotion(emotion: String):
	if !eyes.has(emotion):
		return

	currentEmotion = emotion
	setEyeTexture(eyes[emotion]["open"])


func setHeadTexture(texture_name: String):
	for entry in loadedspritesData.alltextures:
		if entry["name"] == texture_name:
			headNode.texture = entry["texture"]
			return


func setEyeTexture(texture_name: String):
	for entry in loadedspritesData.alltextures:
		if entry["name"] == texture_name:
			eyeNode.texture = entry["texture"]
			return


func startTalking():
	if talking:
		return

	talking = true
	talkLoop()


func stopTalking():
	talking = false
	setHeadTexture(_headTextureFor("default"))


func talkLoop():
	while talking:
		setHeadTexture(_headTextureFor("default"))
		await get_tree().create_timer(randf_range(0.08, 0.18)).timeout

		if !talking:
			break

		setHeadTexture(_headTextureFor("opensmall"))
		await get_tree().create_timer(randf_range(0.05, 0.12)).timeout

	setHeadTexture(_headTextureFor("default"))


func eyedir():
	while get_tree():
		await get_tree().create_timer(.2).timeout
		if !blinking:
			if backtoggle.lookback:
					setEyeTexture(eyes[currentEmotion]["back"])
			else:
					setEyeTexture(eyes[currentEmotion]["open"])


func blink():
	if blinking:
		return

	blinking = true

	setEyeTexture(eyes[currentEmotion]["closed"])
	await get_tree().create_timer(0.15).timeout

	if backtoggle.lookback:
		setEyeTexture(eyes[currentEmotion]["back"])
	else:
		setEyeTexture(eyes[currentEmotion]["open"])

	blinking = false


func blinkLoop():
	while true:
		await get_tree().create_timer(randf_range(2.0, 4.0)).timeout

		if !talking:
			blink()
