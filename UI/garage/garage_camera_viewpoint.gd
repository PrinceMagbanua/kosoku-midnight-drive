class_name GarageCameraViewpoint
extends Marker3D

## A named camera position for the garage/start showcase. Select this node
## in the Godot editor and move it with the normal 3D move gizmo to tune
## where a shot's CAMERA stands.
##
## Where it LOOKS is a separate child Marker3D named "LookAt" (added under
## this node) - drag that one independently to aim the shot at whatever
## point you want (not necessarily the car's center). If no "LookAt" child
## exists, falls back to looking at the preview car itself.
##
## `h_offset` is Camera3D's own lens-shift property - it lets the subject
## sit off-center in frame (so a UI panel on one side never covers it)
## without the perspective distortion a real rotation would cause. Positive
## shifts it toward the RIGHT of screen, negative toward the LEFT (verify
## by eye once you can see it playing - flip the sign here if it reads
## backwards).
@export var h_offset: float = 0.0
@export var look_at_path: NodePath = NodePath("LookAt")

## Falls back to `fallback` (typically the preview car's position) if this
## viewpoint has no "LookAt" child of its own.
func get_look_at_position(fallback: Vector3) -> Vector3:
	var look_node: Node3D = get_node_or_null(look_at_path)
	return look_node.global_position if look_node else fallback
