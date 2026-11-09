class_name CustomPopup
extends Panel

@export_category("Window")
@export var windowControl: WindowController
@export var titleText: String
@export_multiline var labelText: String
@export var yesButtonText: String
@export var noButtonText: String

@export var titleNode: Label
@export var labelNode: RichTextLabel

@export_category("Behavior")
@export var enableNoButton: bool = true
@export var enableCloseButton: bool = true
@export var enableResizeButton: bool = true

@export_category("Buttons")
@export var yesButton: Button
@export var noButton: Button
@export var closeButton: Button
@export var resizeButton: Button

# TODO: move this to globalvariable
enum popupResultEnum {
	YES = 1,
	NO = 0,
	CANCEL = -1
}

signal hasPressedSignal(pEnum: popupResultEnum)

func update_buttons() -> void:
	if !yesButton:
		push_error("missing 'yesButton'")
	if !noButton:
		enableNoButton = false
	if !enableNoButton and noButton:
		noButton.visible = false
	if !enableCloseButton and closeButton:
		closeButton.visible = false
	if !enableResizeButton and resizeButton:
		resizeButton.visible = false

func update_labels() -> void:
	if titleNode and titleText:
		titleNode.text = titleText
	if labelText and labelNode:
		labelNode.text = labelText
	if yesButtonText:
		yesButton.text = yesButtonText
	if noButtonText and noButton:
		noButton.text = noButtonText

func _ready() -> void:
	# link buttons
	if !yesButton:
		push_error("missing 'yesButton'")
	if !noButton:
		enableNoButton = false
	if !enableNoButton and noButton:
		noButton.visible = false
	if !enableCloseButton and closeButton:
		closeButton.visible = false
	if !enableResizeButton and resizeButton:
		resizeButton.visible = false

	update_labels()

	yesButton.pressed.connect(_has_pressed.bind(popupResultEnum.YES))
	if noButton:
		noButton.pressed.connect(_has_pressed.bind(popupResultEnum.NO))
	if closeButton:
		closeButton.pressed.connect(_has_pressed.bind(popupResultEnum.CANCEL))

func _has_pressed(pEnum: popupResultEnum) -> void:
	hasPressedSignal.emit(pEnum)
	windowControl._on_close_pressed()
