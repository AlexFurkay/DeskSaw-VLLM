extends Panel

@export var TabButtons: Array[Button]
@export var TabPanels: Array[Panel]

# how do i add more panels, you might ask?
# 1. create a button in 'SettingsView/MarginContainer/VSplitContainer/TabsScrollContainer/HBoxContainer' and add it to 'TabButtons'
# 2. create a panel in 'SettingsView/MarginContainer/VSplitContainer/SettingsPanel/MarginContainer' and add it to 'TabPanels'
# 3. buttons and panels in the same index will be linked, make sure they match numbers!

var btnG = ButtonGroup.new()

func _ready() -> void:
	visibility_changed.connect(_update)
	if len(TabButtons) != len(TabPanels):
		print(
			"\n%s: WARNING! button and panel amount is disproportionate (%s:%s)\n"
			% [name, len(TabButtons), len(TabPanels)]
		)
	var i: int = 0
	for btn in TabButtons:
		btn.button_group = btnG
		btn.pressed.connect(_tab_btn_pressed.bind(i))
		if i == 0:
			btn.button_pressed = true
		i += 1
	# show the first panel on load
	_tab_btn_pressed(0)

func _update() -> void:
	if !visible: # dont update if we're hiding
		return

func _tab_btn_pressed(idx: int):
	var i: int = 0
	for panel in TabPanels:
		panel.visible = idx == i
		i += 1
