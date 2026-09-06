extends Panel

@export_category("Nodes - DO NOT CHANGE")
@export var itemContainer: Container
@export var buttonScene: PackedScene
@export var root: Panel
@export var wikiButton: Button
@export var wikiButtonClose: Button

class ItemEntry:
	var name: String
	var icon: Texture
	var scene_path: String
var itemList: Array[ItemEntry] = []

var _itemsPath = "res://scenes/objects/"

func  _ready() -> void:
	root.resized.connect(_recalculate_columns)
	if wikiButton:
		wikiButton.pressed.connect(_on_wiki_button_press)
	if wikiButton and wikiButtonClose:
		wikiButtonClose.pressed.connect(_on_wiki_close_button_press)
	_recalculate_columns()
	_refresh()

func _refresh() -> void:
	_generate_item_list()
	_generate_buttons()

## Walk through our item path and generate a list with all the items to be spawned.
func _generate_item_list() -> void:
	itemList.clear()
	var dacc = DirAccess.open(_itemsPath)
	if dacc == null:
		push_error("provided item path '%s' is not accessible." % [_itemsPath])
		return

	# pass through the items path and add any entry to the items list
	for item in dacc.get_files():
		if !item.ends_with(".tscn"): # only focus scene files
			continue
		var entry = ItemEntry.new()
		entry.name = item.get_basename()
		entry.scene_path = _itemsPath.path_join(item)
		entry.icon = _get_scene_texture(entry.scene_path)
		itemList.append(entry)

## Get the main scene's item texture.
func _get_scene_texture(scene_path: String) -> Texture:
	# instance and walk through the scene until we find a Sprite2D, then
	# yank its texture for our own purposes
	var instance = load(scene_path).instantiate()
	for i in instance.get_children():
		if i is Sprite2D:
			return i.texture
	push_error("sprite2d node not found on scene '%s'" % [scene_path])
	return Texture.new()

## Clear and regenerate interactable buttons for all available items.
## '_generate_item_list' should have been called at this point.
func _generate_buttons() -> void:
	# remove all items if any exist
	for child in itemContainer.get_children():
		child.queue_free()
	# get all our known items and implement them
	for item_entry in itemList:
		var btn = buttonScene.instantiate()
		itemContainer.add_child(btn)
		btn.name = "%sItemWidget" % [item_entry.name]
		btn.owner = itemContainer
		btn.itemName = item_entry.name
		btn.itemIcon = item_entry.icon
		# mind you, this' like that because of the referenced scene's anatomy
		btn.find_child("Button").pressed.connect(_on_item_button_press.bind(item_entry))

func _on_item_button_press(item: ItemEntry) -> void:
	# TODO: directly connect this to the command, maybe?
	var scene = load(item.scene_path)
	var instance = scene.instantiate()
	get_tree().current_scene.add_child(instance)
	instance.global_position = instance.get_global_mouse_position()
	instance.owner = get_tree().current_scene
	instance.set_meta("itemName", item)

## Recalculate item list columns using our root width
func _recalculate_columns() -> void:
	# (sort of) compensate for margin, how many times root fits into widget width
	itemContainer.columns = round((root.size.x - 132) / 180)

# wiki stuff
# i feel like this should be it's own node scene but i felt way too lazy tbh.

func _on_wiki_button_press() -> void:
	OS.shell_open("https://casualtiesunknown.miraheze.org/wiki/")

func _on_wiki_close_button_press() -> void:
	wikiButton.hide()
