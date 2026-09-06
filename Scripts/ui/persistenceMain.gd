extends Panel

@export_category("Window")
@export var windowControl: WindowController

@export_category("Buttons")
@export var yesButton: Button
@export var noButton: Button

var _has_been_triggered: bool = false

func _ready() -> void:
    GlobalVariable.persistenceWarning.connect(_on_trigger)
    # link buttons
    if !yesButton:
        push_error("missing 'yesButton'")
    if !noButton:
        push_error("missing 'noButton'")
    yesButton.pressed.connect(_on_yes_button_pressed)
    noButton.pressed.connect(_on_no_button_pressed)

## Make this popup appear on persistenceWarning emit
func _on_trigger() -> void:
    # NOTE: we should instantiate this instead i think
    if _has_been_triggered:
        return
    _has_been_triggered = true
    position = Vector2(
        (float(GlobalVariable.screenWidth)  / 2) - (size.x / 2),
        (float(GlobalVariable.screenHeight) / 2) - (size.y / 2)
    )
    show()

func _finish_interaction() -> void:
    GlobalVariable.persistenceWarning.emit()
    windowControl._on_close_pressed()

func _on_yes_button_pressed() -> void:
    # literally nothing happens
    _finish_interaction()

func _on_no_button_pressed() -> void:
    # reset our expie data
    gbData.data["saw"] = {}
    gbData.addPet("Default")
    _finish_interaction()