class_name LightBreak
extends RefCounted

## Shared break/restore for the player's lamp scripts (headlight_lights.gd,
## brake_lights.gd). Each keeps `by_side`: "L"/"R" -> {"light": SpotLight3D,
## "mesh": lens MeshInstance3D}. Breaking hides both (visible, not energy, so
## the headlight flash / brake-light energy updates can't relight them).

static func break_side(by_side: Dictionary, side: String) -> bool:
	if not by_side.has(side):
		return false
	var e: Dictionary = by_side[side]
	var mesh := e.mesh as MeshInstance3D
	if not is_instance_valid(mesh) or not mesh.visible:
		return false
	mesh.visible = false
	if is_instance_valid(e.light):
		(e.light as Light3D).visible = false
	return true

static func lens_center(by_side: Dictionary, side: String) -> Vector3:
	if not by_side.has(side) or not is_instance_valid(by_side[side].mesh):
		return Vector3.ZERO
	var mesh := by_side[side].mesh as MeshInstance3D
	return mesh.global_transform * mesh.get_aabb().get_center()

static func restore(by_side: Dictionary) -> void:
	for side in by_side:
		var e: Dictionary = by_side[side]
		if is_instance_valid(e.mesh):
			(e.mesh as Node3D).visible = true
		if is_instance_valid(e.light):
			(e.light as Light3D).visible = true
