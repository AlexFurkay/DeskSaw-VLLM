extends Node
@export var root: Control

# moved commands to 'Scripts\commandsGlobal.gd'
func _ready():
	resizeWindow(Vector2(gbData.settings.ConsoleSize.x, gbData.settings.ConsoleSize.y))
	CommandsGlobal.runInitialCommands.emit()
	CommandsGlobal.resizeCommandCalled.connect(resizeWindow)

func resizeWindow(v):
	root.size = v
