extends RefCounted
class_name CustomItems

## 054.999: пользовательские предметы (идея Alex). Лежат в user://items/:
## <id>.png - картинка (прозрачный фон), <id>.json - {name, description, food, taste}.
## PNG без json (положили в папку руками) - тоже предмет: имя по файлу, не еда.
## Ключ предмета в игре - "custom:<id>" (meta itemName), по нему персонажи
## узнают описание и вкус. Хитбокс - по непрозрачным пикселям картинки.

const DIR := "user://items/"
const KEY_PREFIX := "custom:"
const MAX_SIDE := 64 # пикселей до увеличения x4; меньше - свой размер. Было 32 - иконки 64x64 (Тарков) размывало (Alex 20.10)
const SCALE := 4.0
const FOOD_REPLENISH := 15.0

static var _cache: Dictionary = {}
static var _loaded := false


static func folder() -> String:
	DirAccess.make_dir_recursive_absolute(DIR)
	return ProjectSettings.globalize_path(DIR)


## Перечитать папку (вкладка Предметы - при каждом открытии).
static func reload() -> void:
	_cache.clear()
	_loaded = true
	var d := DirAccess.open(folder())
	if d == null:
		return
	for f in d.get_files():
		if f.get_extension().to_lower() != "png":
			continue
		var id := f.get_basename()
		var e := {"id": id, "name": id, "description": "", "food": false, "taste": 5}
		var jp := DIR + id + ".json"
		if FileAccess.file_exists(jp):
			var parsed = JSON.parse_string(FileAccess.get_file_as_string(jp))
			if parsed is Dictionary:
				for k in ["name", "description", "food", "taste"]:
					if parsed.has(k):
						e[k] = parsed[k]
		e["taste"] = clampi(int(e["taste"]), 0, 10)
		e["food"] = bool(e["food"])
		_cache[id] = e


static func all() -> Array:
	if not _loaded:
		reload()
	var list := _cache.values()
	list.sort_custom(func(a, b): return String(a["name"]).naturalnocasecmp_to(String(b["name"])) < 0)
	return list


static func entry(key: String) -> Dictionary:
	if not _loaded:
		reload()
	return _cache.get(key.trim_prefix(KEY_PREFIX), {}) if key.begins_with(KEY_PREFIX) else {}


## Описание для ИИ ("" - не наш предмет).
static func describe(key: String) -> String:
	var e := entry(key)
	if e.is_empty():
		return ""
	var desc := String(e["description"]).strip_edges()
	return desc if desc != "" else String(e["name"])


static func isFood(key: String) -> bool:
	var e := entry(key)
	return not e.is_empty() and bool(e["food"])


## Сохранить (новый - id пустой). srcPng - путь к выбранной картинке ("" - оставить прежнюю).
static func save(id: String, name: String, description: String, food: bool, taste: int, srcPng: String) -> String:
	folder()
	if id == "":
		id = "item%d" % int(Time.get_unix_time_from_system())
	if srcPng != "":
		var img := Image.load_from_file(srcPng)
		if img == null or img.is_empty():
			return ""
		img.save_png(DIR + id + ".png")
	var f := FileAccess.open(DIR + id + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"name": name, "description": description, "food": food, "taste": clampi(taste, 0, 10)}, "\t"))
	f.close()
	reload()
	return id


static func remove(id: String) -> void:
	for ext in [".png", ".json"]:
		if FileAccess.file_exists(DIR + id + ext):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + id + ext))
	reload()


## Картинка, ужатая до MAX_SIDE по большей стороне (пиксель-арт как у остальных).
static func image(id: String) -> Image:
	var img := Image.load_from_file(ProjectSettings.globalize_path(DIR + id + ".png"))
	if img == null or img.is_empty():
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var side := maxi(img.get_width(), img.get_height())
	if side > MAX_SIDE:
		var k := float(MAX_SIDE) / side
		img.resize(maxi(1, int(round(img.get_width() * k))), maxi(1, int(round(img.get_height() * k))), Image.INTERPOLATE_LANCZOS)
	return img


static func icon(id: String) -> Texture2D:
	var img := image(id)
	return ImageTexture.create_from_image(img) if img else null


## Собрать предмет как сцены из scenes/objects: тело, Detector, Sprite,
## формы столкновений, draggable, properties. Вызывающий добавляет в сцену
## и ставит owner (без owner предмет нельзя взять мышью).
static func build(id: String) -> RigidBody2D:
	var e := entry(KEY_PREFIX + id)
	var img := image(id)
	if e.is_empty() or img == null:
		return null
	var food := bool(e["food"])
	var body := RigidBody2D.new()
	body.mass = 0.001 if food else 1.0
	body.set_meta("Category", "object")
	body.set_meta("itemName", KEY_PREFIX + id)
	var det := Area2D.new()
	det.name = "Detector"
	body.add_child(det)
	var spr := Sprite2D.new()
	spr.name = "Sprite"
	spr.texture = ImageTexture.create_from_image(img)
	spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	spr.scale = Vector2(SCALE, SCALE)
	body.add_child(spr)
	# хитбокс - по непрозрачным пикселям (BitMap -> многоугольники)
	var bm := BitMap.new()
	bm.create_from_image_alpha(img, 0.5)
	var polys := bm.opaque_to_polygons(Rect2i(Vector2i.ZERO, img.get_size()), 1.0)
	var off := -Vector2(img.get_size()) / 2.0
	for poly in polys:
		if poly.size() < 3:
			continue
		var shifted := PackedVector2Array()
		for p in poly:
			shifted.append(p + off)
		for parent in [det, body]:
			var cp := CollisionPolygon2D.new()
			cp.polygon = shifted
			cp.scale = Vector2(SCALE, SCALE)
			parent.add_child(cp)
	if det.get_child_count() == 0: # картинка вся прозрачная - хотя бы прямоугольник
		for parent in [det, body]:
			var cs := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(img.get_size()) * SCALE
			cs.shape = rect
			parent.add_child(cs)
	var drag = load("res://Scripts/impo/dragObj.gd").new() # load, не preload: класс компилируется раньше автозагрузок
	drag.name = "draggable"
	drag.sprite = spr
	body.add_child(drag)
	var props = load("res://Scripts/nimpo/properties.gd").new()
	props.name = "properties"
	props.propertyTable = {
		"object": true, "interest": 2, "danger": 0,
		"consumable": food,
		"replenishIfConsumable": FOOD_REPLENISH if food else 0.0,
		"moodBoostIfConsumable": 0.0,
		"tasteIfConsumable": int(e["taste"]) if food else 0,
		"healIfConsumable": 0.0,
	}
	body.add_child(props)
	# owner у всех частей: dragObj ищет Detector через find_child, а он без
	# owner узел не видит - предмет нельзя было взять мышью (тест Alex 20.10)
	for n in body.find_children("*", "", true, false):
		n.owner = body
	return body
