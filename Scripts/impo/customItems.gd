extends RefCounted
class_name CustomItems

## 054.999: пользовательские предметы (идея Alex). Лежат в user://items/:
## <id>.png - картинка (прозрачный фон), <id>.json - {name, description, food, taste}.
## PNG без json (положили в папку руками) - тоже предмет: имя по файлу, не еда.
## Ключ предмета в игре - "custom:<id>" (meta itemName), по нему персонажи
## узнают описание и вкус. Хитбокс - по непрозрачным пикселям картинки.
## Здесь нет gbData/GlobalVariable: класс компилируется раньше автозагрузок
## (иначе ломаются проверки без окна) - нужное передают параметрами.

const DIR := "user://items/"
const KEY_PREFIX := "custom:"
const MAX_SIDE := 64 # больше 64 пикселей арта не бывает (огромное фото - не больше 256 px на экране)
## 054.9992: ЕДИНЫЙ масштаб для всех картинок. Раньше каждая картинка ужималась
## до 64 px и увеличивалась под ~128 px на экране - сгущёнка 64x64 и АК 316x127
## выходили одного размера (большая сторона 128 px), реальная разница стиралась.
## У иконок Таркова размер честный (клетка ~63 px: сгущёнка 1x1, АК 5x2), поэтому
## все картинки уменьшаются в одно число раз (до BLOCK пикселей картинки в один
## пиксель арта) и показываются x4, как встроенные: на экране ~0,7 от картинки.
## Сгущёнка -> ~50 px (бургер 48), АК -> ~210 px (рост персонажа ~200).
const BLOCK := 6
const PIXEL_ART_MAX := 32 # до 32 px - уже пиксель-арт: не уменьшаем, x4
const IMAGE_EXT := ["png", "jpg", "jpeg", "webp", "bmp", "tga"] # GIF движок не открывает
const FOOD_REPLENISH := 15.0
const PRE_SHRINK := 512 # огромные фото сначала грубо уменьшаем - блочный перебор по пикселям в GDScript небыстрый

static var _cache: Dictionary = {}
static var _loaded := false
static var _imgCache: Dictionary = {} # id -> {"mtime", "img"} - картинка уже "пикселизирована"
## ИИ-описания (054.9991): кто сейчас описывается и кого уже пробовали в этом запуске
static var describing: Dictionary = {}
static var describeTried: Dictionary = {}


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
		if not IMAGE_EXT.has(f.get_extension().to_lower()):
			continue
		var id := f.get_basename()
		if _cache.has(id):
			continue # одно имя в двух форматах - берём первое
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
		e["file"] = f
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


## Путь к картинке предмета (png, jpg, webp...).
static func imagePath(id: String) -> String:
	var e: Dictionary = _cache.get(id, {})
	return DIR + String(e.get("file", id + ".png"))


## Нужно ли ИИ-описание (пустое и в этом запуске ещё не пробовали).
static func needsDescription(id: String) -> bool:
	var e := entry(KEY_PREFIX + id)
	return not e.is_empty() and String(e["description"]).strip_edges() == "" and not describeTried.has(id)


## Сохранить (новый - id пустой). srcPng - путь к выбранной картинке ("" - оставить прежнюю).
static func save(id: String, name: String, description: String, food: bool, taste: int, srcPng: String) -> String:
	folder()
	if id == "":
		id = "item%d" % int(Time.get_unix_time_from_system())
		while FileAccess.file_exists(DIR + id + ".png"):
			id += "b"
	if srcPng != "":
		var img := Image.load_from_file(srcPng)
		if img == null or img.is_empty():
			return ""
		img.save_png(DIR + id + ".png")
		_imgCache.erase(id)
	var f := FileAccess.open(DIR + id + ".json", FileAccess.WRITE)
	f.store_string(JSON.stringify({"name": name, "description": description, "food": food, "taste": clampi(taste, 0, 10)}, "\t"))
	f.close()
	reload()
	return id


static func remove(id: String) -> void:
	for ext in [".png", ".jpg", ".jpeg", ".webp", ".bmp", ".tga", ".json"]:
		if FileAccess.file_exists(DIR + id + ext):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR + id + ext))
	_imgCache.erase(id)
	reload()


## Картинка для игры: до MAX_SIDE - как есть; больше - "конвертер" (054.9991):
## уменьшение в целое число раз блоками - каждый квадрат k x k становится одним
## пикселем среднего цвета, полупрозрачное - либо видно, либо нет. Ровная
## пиксельная сетка без мыла (винтовка 300x200 при сглаживании шла неровно).
static func image(id: String) -> Image:
	var path := ProjectSettings.globalize_path(imagePath(id))
	var mtime := FileAccess.get_modified_time(path)
	if _imgCache.has(id) and int(_imgCache[id]["mtime"]) == mtime:
		return _imgCache[id]["img"]
	var img := Image.load_from_file(path)
	if img == null or img.is_empty():
		return null
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	img = pixelize(img)
	_imgCache[id] = {"mtime": mtime, "img": img}
	return img


static func pixelize(img: Image) -> Image:
	var side := maxi(img.get_width(), img.get_height())
	if side <= PIXEL_ART_MAX:
		return img
	if side > PRE_SHRINK:
		var q := float(PRE_SHRINK) / side
		img = img.duplicate()
		img.resize(maxi(1, int(img.get_width() * q)), maxi(1, int(img.get_height() * q)), Image.INTERPOLATE_BILINEAR)
		side = maxi(img.get_width(), img.get_height())
	# единый блок; маленькие (33-71 px) - помягче, чтобы не стать точкой; огромные - до 64 px арта
	var k := maxi(clampi(int(side / 12.0), 1, BLOCK), int(ceil(float(side) / MAX_SIDE)))
	if k <= 1:
		return img
	var w := img.get_width()
	var h := img.get_height()
	var w2 := int(ceil(float(w) / k))
	var h2 := int(ceil(float(h) / k))
	var out := Image.create(w2, h2, false, Image.FORMAT_RGBA8)
	for by in h2:
		for bx in w2:
			var sr := 0.0
			var sg := 0.0
			var sb := 0.0
			var sa := 0.0
			var n := 0
			for y in range(by * k, mini((by + 1) * k, h)):
				for x in range(bx * k, mini((bx + 1) * k, w)):
					var c := img.get_pixel(x, y)
					sr += c.r * c.a
					sg += c.g * c.a
					sb += c.b * c.a
					sa += c.a
					n += 1
			if n == 0 or sa / n < 0.5:
				out.set_pixel(bx, by, Color(0, 0, 0, 0))
			else:
				out.set_pixel(bx, by, Color(sr / sa, sg / sa, sb / sa, 1.0))
	return out


## На экране - x4, как встроенные (пиксель арта = 4 пикселя экрана); размер
## задаёт pixelize. Поверх этого properties.gd масштабирует под petSize.
static func screenScale(_img: Image) -> float:
	return 4.0


static func icon(id: String) -> Texture2D:
	var img := image(id)
	return ImageTexture.create_from_image(img) if img else null


## Где появиться предмету (054.9991, Alex): около курсора, в радиусе 4-5 мед.
## ящиков, но не ближе 2-3 мед. ящиков к краю экрана. Мед. ящик - 32 px x petScale.
## Курсор - по экрану (консоль - отдельное окно, и позиция мыши в главном окне
## не обновлялась: предметы падали в левый верхний угол).
static func spawnPosition(viewSize: Vector2, petScale: float) -> Vector2:
	var crate := 32.0 * petScale
	var mouse := Vector2(DisplayServer.mouse_get_position() - DisplayServer.window_get_position())
	var ang := randf() * TAU
	var p := mouse + Vector2(cos(ang), sin(ang)) * randf_range(0.0, 4.5 * crate)
	var m := minf(2.5 * crate, minf(viewSize.x, viewSize.y) * 0.25)
	return Vector2(clampf(p.x, m, viewSize.x - m), clampf(p.y, m, viewSize.y - m))


## Собрать предмет как сцены из scenes/objects: тело, Detector, Sprite,
## формы столкновений, draggable, properties. Вызывающий добавляет в сцену
## и ставит owner (без owner предмет нельзя взять мышью).
static func build(id: String) -> RigidBody2D:
	var e := entry(KEY_PREFIX + id)
	var img := image(id)
	if e.is_empty() or img == null:
		return null
	var sc := screenScale(img)
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
	spr.scale = Vector2(sc, sc)
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
			cp.scale = Vector2(sc, sc)
			parent.add_child(cp)
	if det.get_child_count() == 0: # картинка вся прозрачная - хотя бы прямоугольник
		for parent in [det, body]:
			var cs := CollisionShape2D.new()
			var rect := RectangleShape2D.new()
			rect.size = Vector2(img.get_size()) * sc
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
