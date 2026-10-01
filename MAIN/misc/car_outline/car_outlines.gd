extends Node

## Borderlands-style inverted-hull outlines on cars only (player car, garage
## preview car, traffic). Self-contained and hook-free: listens to
## SceneTree.node_added, and for every MeshInstance3D that lands under a car
## (base car.tscn's "player_car" group, or a TrafficCar) adds an "_Outline"
## child that draws a slightly inflated, back-face-only, flat-color copy of
## that mesh. No GLB or car-script changes.
##
## Settings (Graphics Config panel, misc_graphics_settings):
## - car_outlines: on/off, applied live to every existing outline.
## - car_outline_width: 0..1 slider, mapped to 0..MAX_PX pixels, live.
##
## TO REMOVE: delete this folder, the CarOutlines autoload line in
## project.godot, the two car_outline* vars in graphics.gd, the CarOutlines/
## CarOutlineWidth nodes in debugger.tscn, and the OUTLINE_META check in
## car_mesh_util.gd's solid_meshes().
##
## Glass/transparent surfaces are left out (an outline behind them would show
## through), as are emissive light lenses and generated helper meshes
## (PrimitiveMesh, light cones etc.).

const SHADER := preload("res://MAIN/misc/car_outline/car_outline.gdshader")
const TRAFFIC_CAR_SCRIPT := preload("res://MAIN/traffic/traffic_car.gd")
const PLAYER_GROUP := "player_car"
const OUTLINE_GROUP := "car_outline_mesh"
## Marks the outline nodes themselves (so they're never outlined again, and
## slow_mo.gd's afterimage can skip them).
const OUTLINE_META := "car_outline"

## Line thickness in pixels at slider = 100% (near the camera - see the
## shader's ref_distance/min_scale for how it thins with distance).
const MAX_PX := 8.0
## Cap on the corner extrusion boost (1/cos) - stops needle-sharp corners
## from shooting spikes out.
const MAX_CORNER_BOOST := 1.6
## Meshes flatter than this (thinnest / widest AABB side) are skipped:
## single-sided planes (plates, grilles, decals) have no "inside", so their
## shell shows as a solid black sheet when seen from behind.
const FLAT_RATIO := 0.02

var _material := ShaderMaterial.new()
## source Mesh -> {skip-mask String -> outline ArrayMesh}. Traffic reuses the
## same imported meshes for every car of a type, so each is baked once.
var _cache: Dictionary = {}

var _enabled := true
var _width := -1.0
## Roots whose outlines stay hidden regardless of the setting - the cockpit
## camera suppresses the player car's (from inside the car, the inflated
## shells would paint the whole cabin black).
var _suppressed: Array[Node] = []

func _ready() -> void:
	_material.shader = SHADER
	get_tree().node_added.connect(_on_node_added)
	_sync_settings(true)

func _process(_delta: float) -> void:
	_sync_settings(false)

func _sync_settings(force: bool) -> void:
	var enabled: bool = misc_graphics_settings.car_outlines
	var width: float = misc_graphics_settings.car_outline_width * MAX_PX
	if force or enabled != _enabled:
		_enabled = enabled
		get_tree().set_group(OUTLINE_GROUP, "visible", enabled)
		for root in _suppressed:
			_set_visible_under(root, false)
	if force or width != _width:
		_width = width
		_material.set_shader_parameter("outline_px", width)

## Hides (on = true) or restores the outlines of every mesh under `root`,
## including ones added later (a hull swapped while suppressed).
func set_suppressed(root: Node, on: bool) -> void:
	_suppressed.assign(_suppressed.filter(func(n): return is_instance_valid(n) and n != root))
	if on:
		_suppressed.append(root)
	_set_visible_under(root, _enabled and not on)

func _set_visible_under(root: Node, show: bool) -> void:
	if not is_instance_valid(root):
		return
	for o in get_tree().get_nodes_in_group(OUTLINE_GROUP):
		if root.is_ancestor_of(o):
			(o as Node3D).visible = show

func _is_suppressed(node: Node) -> bool:
	for root in _suppressed:
		if is_instance_valid(root) and root.is_ancestor_of(node):
			return true
	return false

# --- attaching -------------------------------------------------------------

func _on_node_added(node: Node) -> void:
	if not node is MeshInstance3D or node.has_meta(OUTLINE_META):
		return
	if not _is_under_car(node):
		return
	# Deferred: adding a child from inside node_added (mid enter-tree) is
	# refused by Godot, and hull scripts often re-parent meshes right after
	# adding them (wheel pivots) - by next idle frame everything has settled.
	_attach.call_deferred(node)

func _is_under_car(node: Node) -> bool:
	var n := node.get_parent()
	while n != null:
		if n.is_in_group(PLAYER_GROUP) or n.get_script() == TRAFFIC_CAR_SCRIPT:
			return true
		n = n.get_parent()
	return false

func _attach(mi: MeshInstance3D) -> void:
	if not is_instance_valid(mi) or not mi.is_inside_tree() or mi.top_level:
		return
	if mi.mesh == null or mi.mesh is PrimitiveMesh or mi.has_meta("lens"):
		return
	var size := mi.mesh.get_aabb().size
	if minf(size.x, minf(size.y, size.z)) < FLAT_RATIO * maxf(size.x, maxf(size.y, size.z)):
		return
	for child in mi.get_children():
		if child.has_meta(OUTLINE_META):
			return # already outlined (the mesh was just re-parented)
	var skip := PackedInt32Array()
	for s in mi.mesh.get_surface_count():
		if _is_see_through(mi.get_active_material(s)):
			skip.append(s)
	var outline_mesh := _outline_mesh_for(mi.mesh, skip)
	if outline_mesh == null:
		return
	var o := MeshInstance3D.new()
	o.name = "_Outline"
	o.set_meta(OUTLINE_META, true)
	o.mesh = outline_mesh
	o.material_override = _material
	o.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	o.layers = mi.layers
	o.visible = _enabled and not _is_suppressed(mi)
	o.add_to_group(OUTLINE_GROUP)
	mi.add_child(o)

static func _is_see_through(mat: Material) -> bool:
	var m := mat as BaseMaterial3D
	if m == null:
		return false
	if m.resource_name.to_lower().contains("glass"):
		return true
	if m.emission_enabled and m.emission_energy_multiplier > 1.0:
		return true # light lens - an ink line would dull the glow
	return m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED

# --- baking ----------------------------------------------------------------

func _outline_mesh_for(src: Mesh, skip: PackedInt32Array) -> ArrayMesh:
	var key := str(skip)
	var per_mesh: Dictionary = _cache.get(src, {})
	if per_mesh.has(key):
		return per_mesh[key]
	var baked := _bake(src, skip)
	per_mesh[key] = baked
	_cache[src] = per_mesh
	return baked

## A copy of `src` (minus `skip` surfaces) whose normals are replaced by the
## average of every DISTINCT face normal meeting at that position, and whose
## UV.x carries the extrusion multiplier the shader uses. Distinct (not every
## triangle's) so a corner where one face is split into many triangles isn't
## biased toward that face.
static func _bake(src: Mesh, skip: PackedInt32Array) -> ArrayMesh:
	var surfaces: Array = []
	var face_normals: Dictionary = {} # position key -> Array[Vector3]
	for s in src.get_surface_count():
		if skip.has(s) or src.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
			continue
		var arrays := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL] if arrays[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
		if verts.is_empty() or norms.size() != verts.size():
			continue
		surfaces.append(arrays)
		for i in verts.size():
			var k := _key(verts[i])
			var list = face_normals.get(k)
			if list == null:
				list = []
				face_normals[k] = list
			var n := norms[i]
			var seen := false
			for m in list:
				if (m as Vector3).dot(n) > 0.999:
					seen = true
					break
			if not seen:
				list.append(n)
	if surfaces.is_empty():
		return null

	var resolved: Dictionary = {} # position key -> [direction, multiplier]
	for k in face_normals:
		var list: Array = face_normals[k]
		var sum := Vector3.ZERO
		for m in list:
			sum += m
		var dir: Vector3 = sum.normalized() if sum.length_squared() > 1e-8 else list[0]
		var min_dot := 1.0
		for m in list:
			min_dot = minf(min_dot, dir.dot(m))
		resolved[k] = [dir, minf(1.0 / maxf(min_dot, 0.01), MAX_CORNER_BOOST)]

	var out := ArrayMesh.new()
	for arrays in surfaces:
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals := PackedVector3Array()
		var boost := PackedVector2Array()
		normals.resize(verts.size())
		boost.resize(verts.size())
		for i in verts.size():
			var r: Array = resolved[_key(verts[i])]
			normals[i] = r[0]
			boost[i] = Vector2(r[1], 0.0)
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = normals
		a[Mesh.ARRAY_TEX_UV] = boost
		a[Mesh.ARRAY_INDEX] = arrays[Mesh.ARRAY_INDEX]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	return out

static func _key(v: Vector3) -> Vector3i:
	return Vector3i(roundi(v.x * 10000.0), roundi(v.y * 10000.0), roundi(v.z * 10000.0))
