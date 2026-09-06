extends HSlider
@onready var sliderText = $name

func _ready() -> void:
	value = AudioManager.soundMult
	sliderText.text = "Master sound volume (%d%%)" % [value * 100]
	value_changed.connect(_onChange)


func _onChange(new_value: float) -> void:
	AudioManager.soundMult = new_value
	sliderText.text = "Master sound volume (%d%%)" % [value * 100]
