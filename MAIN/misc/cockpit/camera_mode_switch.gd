extends Node

## Toggles between the chase camera and the cockpit camera on
## `toggle_cockpit_cam`. Godot automatically clears a Camera3D's `current`
## flag when another one in the same viewport becomes current, so this just
## has to call the right side's activation.

@export var chase_camera_path: NodePath = NodePath("../cam_chase/orbit/Camera")
@export var cockpit_camera_path: NodePath = NodePath("../cam_cockpit")

const SFX_CHANGE_VIEW := preload("res://MAIN/sfx/change-view.ogg")

var _in_cockpit: bool = false
var _sfx: AudioStreamPlayer

func _ready() -> void:
	_sfx = AudioStreamPlayer.new()
	_sfx.stream = SFX_CHANGE_VIEW
	add_child(_sfx)

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_cockpit_cam"):
		_in_cockpit = not _in_cockpit
		var cockpit: Node = get_node(cockpit_camera_path)
		if _in_cockpit:
			cockpit.activate()
		else:
			cockpit.deactivate()
			get_node(chase_camera_path).current = true
		_sfx.volume_db = linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume, 0.0001, 1.0))
		_sfx.play()
