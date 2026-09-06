@tool
extends PanelContainer

@export_category("Settings")
@export_multiline var itemName: String:
	set(v):
		itemName = v
		_refresh()
@export var itemIcon: Texture:
	set(v):
		itemIcon = v
		_refresh()
@export var sceneToInstance: PackedScene

@export_category("Nodes - DONT CHANGE")
@export var texRect: TextureRect
@export var label: RichTextLabel
@export var btn: Button

func _refresh() -> void:
	texRect.texture = itemIcon
	label.text = itemName

func _ready() -> void:
	if not Engine.is_editor_hint():
		_refresh()
		btn.pressed.connect(_on_button_press)

func _on_button_press() -> void:
	print("pressed %s!" % [itemName])
