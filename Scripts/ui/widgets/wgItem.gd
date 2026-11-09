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
		# F2.5 (тестер, 1440x900: картинки вылезали за карточку): карточка растёт и сжимается
		# вместе с текстом (textScale), а картинка была всегда 27 px - теперь в том же масштабе
		var k: float = preload("res://Scripts/ui/terminal/terminalMain.gd").textScale() / 0.75
		texRect.offset_left *= k
		texRect.offset_top *= k
		texRect.offset_right *= k
		texRect.offset_bottom *= k
		_refresh()
		btn.pressed.connect(_on_button_press)

func _on_button_press() -> void:
	print("pressed %s!" % [itemName])
