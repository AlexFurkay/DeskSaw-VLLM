extends Button

func _pressed() -> void:
	OS.shell_open(ProjectSettings.globalize_path("user://"))