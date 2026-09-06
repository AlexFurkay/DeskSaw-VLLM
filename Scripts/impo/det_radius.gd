extends Node

var inRadius = {
	#object containing itself and its properties
}

var mousePriority = 5

func _ready() -> void:
	pass

#recoded to work with properties class

func _on_dect_body_entered(body: Node2D) -> void:
	var propsNode = body.get_node_or_null("properties")
	if propsNode:
		inRadius[body] = propsNode.propertyTable.duplicate()
		#print(inRadius)


func _on_dect_body_exited(body: Node2D) -> void:
	if inRadius.has(body):
		inRadius.erase(body)
		#print(body.name, " curr", inRadius)
