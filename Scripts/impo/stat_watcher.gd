extends Node

@export var window: Control
@export var stat = {
	"mood": 0.0,
	"hunger": 0.0,
	"sleep": 0.0,
}

## 054.9991: высота окошка - под число строк (4 без зависимости, 5 с ней):
## высота на 4 строки / 4 * N, растёт вверх от головы (Alex).
var _bottom := 0.0
var _rowH := 0.0

func _ready() -> void:
	_bottom = window.offset_bottom
	_rowH = (window.offset_bottom - window.offset_top) / 4.0
	upd(stat)

func upd(stats: Dictionary) -> void:
	if _rowH > 0.0:
		window.offset_top = _bottom - _rowH * maxi(4, stats.size())
	var ilist = window.get_node("ItemList")
	var textTemplate = window.get_node("ItemList/stat")

	for child in ilist.get_children():
		if child != textTemplate:
			child.queue_free()
	

	for key in stats.keys():
		#update asdfhsdfuioghj
		var val = stats[key]
		var new_stat = textTemplate.duplicate()
		

		new_stat.show()
		new_stat.text = str(key) + ": " + str(val)
		ilist.add_child(new_stat)
		

func _process(_delta: float) -> void:
	pass
