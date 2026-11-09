extends Control
class_name ExpieWidget

var _loadedTextures: Dictionary[String,String] = {}
var _has_to_reset: bool = false

func _ready() -> void:
	pass

## Get textures from a skin directory path and apply it to the display
func ApplyTextures(skin_path: String) -> void:
	var dacc = DirAccess.open(skin_path)
	if !dacc:
		push_error("skin path '%s' is not accessible." % [skin_path])
		return
	_loadedTextures.clear()

	if _has_to_reset:
		# gross how were handling this, but we're reloading our 
		# default expie textures every time we load a new skin to
		# prevent skins with missing assets from merging with one another
		_has_to_reset = false
		ApplyTextures("res://assets/Body")

	for tex in dacc.get_files():
		if !tex.ends_with(".png"):
			continue
		_loadedTextures.set(tex.get_basename(), skin_path.path_join(tex))
	
	for node in get_children():
		# for reference, we're matching the node names with
		# the imported texture names, then quickly assigning their textures.
		# so if we import a texture named "experimentHead", we will
		# match it with the node named "Head".
		var refname = "experiment%s" % [node.name.remove_chars("2")]
		var imgpath = _loadedTextures.get(refname, null)

		# ignore if no matches
		if imgpath == null:
			continue
		# load internally if its a resource (probably [definitely] default)
		elif imgpath.begins_with("res:"):
			var _res = load(imgpath)
			node.texture = _res
			continue
		# load externally if we find something else
		var _img = Image.new()
		if _img.load(imgpath) != 0:
			continue
		node.texture = ImageTexture.create_from_image(_img)
	
	_has_to_reset = true
