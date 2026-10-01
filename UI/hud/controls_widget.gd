class_name ControlsWidget
extends Control

## Key-binding reference list, shown/hidden by its own small "CONTROLS"
## text button (bottom-centre of the HUD) or the HUD's "?" button
## (live_hud.gd calls toggle()). The list opens upward from the button. Purely a static reference (hardcoded from
## project.godot's [input] map, not read from it live) - simplest option, and
## these bindings aren't rebindable in-game anywhere else in the project
## either, so there's nothing for this to fall out of sync with.

@onready var _list: Control = %List
@onready var _toggle_button: Button = %ToggleButton

func _ready() -> void:
	_list.visible = false
	_toggle_button.pressed.connect(toggle)

func toggle() -> void:
	_list.visible = not _list.visible
