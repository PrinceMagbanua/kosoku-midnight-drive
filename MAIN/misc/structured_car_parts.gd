class_name StructuredCarParts
extends RefCounted

## Single source of truth for this project's car-hull asset pack naming
## convention (assets/cars/*.glb - Voxel Driver's "StructuredCars" pack,
## hand-labeled in Blender). Documented in Voxel Driver's
## js/voxel-assets.js (applyStructuredHull(), ~line 120-232) - ported here
## rather than re-derived, since that's the actual battle-tested spec:
##
## - Named sub-parts: headlight_L/R, rearlight_L/R, wheel_FL/FR/BL/BR,
##   roofsign, sidelight, sirenlight_red/blue, windows (glass).
## - Matching is case-insensitive SUBSTRING, not exact/suffix - each model
##   prefixes these names differently (coupe.glb: bare "wheel_FL"; taxi.glb:
##   "car_taxi_wheel_FL"; armored.glb: "armored_truck_wheel_FL"; etc.).
## - "rl"/"rr" are accepted as SYNONYMS for "bl"/"br" (rear-left/rear-right
##   vs. back-left/back-right) - at least one model in the pack (italia.glb)
##   uses that naming instead.
## - Known asset bug (documented in the JS, not yet hit in this Godot port
##   since kamaro.glb isn't used anywhere yet): kamaro.glb's non-glass
##   materials can export with alphaMode:BLEND set by mistake, causing a
##   jagged transparent-cutout look on solid parts (wheels included) unless
##   forced back to opaque. Worth checking if kamaro.glb is ever wired up.

const HEADLIGHT_COLOR := Color(1.0, 0.914, 0.659) # 0xffe9a8, matches core.js's procedural headlight color
const REARLIGHT_COLOR := Color(1.0, 0.165, 0.227) # 0xff2a3a

## Case-insensitive substring match, first hit wins. `patterns` in priority
## order (e.g. ["wheel_bl", "wheel_rl"] to accept either naming).
static func find_part(root: Node, patterns: Array) -> Node3D:
	for pattern in patterns:
		var found := _search(root, pattern.to_lower())
		if found:
			return found
	return null

static func _search(node: Node, pattern: String) -> Node3D:
	if node.name.to_lower().contains(pattern):
		return node as Node3D
	for child in node.get_children():
		var found := _search(child, pattern)
		if found:
			return found
	return null

## Every MeshInstance3D under `root` (including root itself).
static func mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root is MeshInstance3D:
		out.append(root)
	for child in root.get_children():
		out.append_array(mesh_instances(child))
	return out

## Forces every non-glass material under `root` back to opaque. kamaro.glb
## exports its body/light/metal materials with alphaMode BLEND by mistake
## (see the note at the top of this file), which renders solid parts with a
## jagged transparent-cutout look. Duplicates the material onto a per-surface
## override so the shared imported resource isn't modified. Harmless on hulls
## that are already opaque.
static func force_opaque(root: Node) -> void:
	for mi in mesh_instances(root):
		if mi.mesh == null:
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s) as BaseMaterial3D
			if mat == null or mat.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED:
				continue
			if mat.resource_name.to_lower().contains("glass"):
				continue
			var fixed := mat.duplicate() as BaseMaterial3D
			fixed.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
			mi.set_surface_override_material(s, fixed)

static func wheel_patterns(corner: String) -> Array:
	# corner: "FL", "FR", "BL", "BR"
	var p := "wheel_" + corner.to_lower()
	if corner == "BL":
		return [p, "wheel_rl"]
	if corner == "BR":
		return [p, "wheel_rr"]
	return [p]
