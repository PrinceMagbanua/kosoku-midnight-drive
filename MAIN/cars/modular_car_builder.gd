class_name ModularCarBuilder
extends RefCounted

## Builds a modular Synty car hull at runtime from CarManifest: the base car
## GLB plus one GLB per equipped part, all added at identity (the pack's
## parts are authored in the base car's space, real-world meters, +Z
## forward, left = +X - same as the old hulls, so CarConfigurator's fit and
## HULL_SCALE apply unchanged).
##
## Every mesh in the pack uses only two materials, "Car" and "Glass" (no
## embedded textures):
## - "Car"   -> ONE StandardMaterial3D per car instance (duplicated from
##              materials/car_paint_base.tres), albedo = the chosen paint
##              texture. It's stored on the hull (PAINT_META) and shared by the
##              wheels, so repainting is a single albedo swap (set_paint()).
## - "Glass" -> ONE translucent material per car instance (duplicated from
##              materials/car_glass.tres), tinted by the loadout's "tint"
##              (WindowTint preset). Stored on the hull (GLASS_META), so a tint
##              change is a single material edit (set_tint()).
##
## Lights: the pack has no headlight/rearlight meshes - the lamps are painted
## into the texture atlas. Every palette/vinyl texture shares one UV layout,
## and the lamp lenses always use the same two tiny atlas swatches
## (HEAD_LENS_UV / TAIL_LENS_UV). The builder copies those triangles out of
## the base + equipped parts into four lens meshes named headlight_L/R and
## rearlight_L/R, so the existing HullHeadlights / HullBrakeLights scripts
## find and light them exactly like the old hulls' named light meshes -
## whatever bumper is fitted.
##
## Cockpit: the pack has no seat/eye marker, so build() adds a COCKPIT_EYE
## Marker3D at the driver's head, derived from the steering wheel mesh (see
## _add_cockpit_eye()). cockpit_camera.gd sits the camera there. The
## steering wheel mesh is re-hung on a pivot at its hub, aligned to its
## column, so steering_wheel_spin.gd can turn it with the car's steering.
## A mesh named "*Dash_Screen*" (split out of the dash in Blender) becomes a
## live gauge display (dash_screen.gd) - its UVs are re-projected here, so
## the Blender UVs don't matter. Meshes named "*Mirror_L*" become live side
## mirrors (side_mirror.gd) the same way.
##
## Interior lights etc. live in a per-car scene, INTERIOR_DIR/<car>_Interior.tscn
## (car_interior.gd - open it in the editor to see the car and edit in place).
## build() instances it into the hull as "Interior", hidden; the cockpit camera
## shows it while driving from inside.

const PAINT_BASE := preload("res://MAIN/cars/materials/car_paint_base.tres")
const STEERING_SPIN_SCRIPT := preload("res://MAIN/cars/steering_wheel_spin.gd")
const DASH_SCREEN_SCRIPT := preload("res://MAIN/cars/dash_screen.gd")
const SIDE_MIRROR_SCRIPT := preload("res://MAIN/cars/side_mirror.gd")
const GLASS_MATERIAL := preload("res://MAIN/cars/materials/car_glass.tres")

const PAINT_META := "car_paint_material"
const GLASS_META := "car_glass_material"
const COCKPIT_VIEW_META := "cockpit_view"
const LOADOUT_META := "car_loadout"
const CAR_META := "manifest_car"
const PART_PREFIX := "Part_"

## Lamp lens swatches in the pack's shared atlas UV layout (measured from the
## GLBs: every lens triangle on every car/bumper lands inside these).
const HEAD_LENS_UV := Rect2(0.0, 0.868, 0.009, 0.016)
const TAIL_LENS_UV := Rect2(0.009, 0.868, 0.009, 0.016)
## How far the lens copies sit off the body along their normals (meters,
## pre-HULL_SCALE) so they don't z-fight with the painted lamp underneath.
const LENS_PUSH := 0.004
const HEADLIGHT_LENS_ENERGY := 2.0

## Driver eye point relative to the steering wheel mesh (meters, pre-HULL_SCALE,
## base-car space: +X = left = driver side, +Z = forward).
const COCKPIT_EYE := "CockpitEye"
const EYE_BEHIND_WHEEL := 0.6 # from the wheel's back edge toward the seat
const EYE_ABOVE_WHEEL := 0.12 # above the wheel's top
const EYE_BELOW_ROOF := 0.15 # never closer than this to the highest glass
const STEERING_PIVOT := "SteeringPivot"
const DASH_SCREEN_NAME := "dash_screen" # case-insensitive substring
## Mirror meshes that get a live reflection (case-insensitive substrings).
## Only the driver-side mirror for now - each one is a full extra scene
## render; add "mirror_r" here to enable the passenger side too.
const MIRROR_NAMES := ["mirror_l"]
const INTERIOR_DIR := "res://MAIN/cars/interiors/"
const INTERIOR_NODE := "Interior"
## Optional Camera3D in the interior scene = the driver's view (editor
## Preview-able). Swapped for a DRIVER_EYE Marker3D (carrying its fov/near as
## meta) before the interior joins the tree, so it can never become the game's
## current camera - cockpit_camera.gd reads the marker.
const DRIVER_CAMERA := "DriverCamera"
const DRIVER_EYE := "DriverEye"

## Pieces the FBX->GLB conversion left in their Unity parent's LOCAL space
## (they were children of a hinged door/boot whose pivot was dropped), so they
## import floating near the origin/under the car. Offset = that lost pivot, in
## base-car space. Keys are node names without "SM_Veh_<car>_". Measured by
## matching each piece's edge to the geometry it attaches to - nudge here if
## one looks off in the editor.
const _SEDAN_BOOT := Vector3(0.0, 1.213, -1.881)
const _HATCH_BOOT := Vector3(0.0, 1.574, -1.517)
const _MUSCLE_BOOT := Vector3(0.0, 1.108, -2.064)
const _SPORTS_BOOT := Vector3(0.0, 0.941, -1.49)
const _SEDAN_REAR_DOOR_L := Vector3(0.976, 0.782, -0.2)
const _SEDAN_REAR_DOOR_R := Vector3(-0.976, 0.782, -0.2)
const PIECE_OFFSETS := {
	"Sedan_01": {
		"Spoiler_01": _SEDAN_BOOT, "Spoiler_02": _SEDAN_BOOT,
		# Rear-door arch flares that continue the fender flare across the
		# rear doors (the stock doors stay - these sit on top of them).
		"Fenders_02_Door_L": _SEDAN_REAR_DOOR_L, "Fenders_02_Door_R": _SEDAN_REAR_DOOR_R,
		"Fenders_04_Door_L": _SEDAN_REAR_DOOR_L, "Fenders_04_Door_R": _SEDAN_REAR_DOOR_R,
	},
	"Hatch_01": {"Spoiler_02": _HATCH_BOOT, "Spoiler_03": _HATCH_BOOT, "Spoiler_04": _HATCH_BOOT},
	"Muscle_01": {"Spoiler_04": _MUSCLE_BOOT, "Spoiler_02_Boot": _MUSCLE_BOOT},
	"Sports_01": {"Spoiler_02": _SPORTS_BOOT, "Spoiler_03": _SPORTS_BOOT, "Spoiler_04": _SPORTS_BOOT},
	# Set up from Hatch_01's files, so its spoiler keeps the hatch's pivot.
	"Sports_02": {"Spoiler_03": _HATCH_BOOT},
}

static var _scenes: Dictionary = {} # path -> PackedScene
static var _lens_cache: Dictionary = {} # Mesh -> {"head": PackedVector3Array, ...} (+ normals)

# --- building -----------------------------------------------------------

## A new hull node for `car` (manifest id, e.g. "Sports_01") dressed as
## `loadout` (already sanitized). `paint` reuses an existing paint material
## (so wheels sharing it keep working across a rebuild); null makes a new one.
## `with_interior` = false skips the interior scene (its own editor preview
## builds the car this way, or it would contain itself).
static func build(car: String, loadout: Dictionary, paint: StandardMaterial3D = null, with_interior: bool = true) -> Node3D:
	var root := Node3D.new()
	root.set_meta(CAR_META, car)
	var base_scene := get_scene(CarManifest.base_path(car))
	if base_scene:
		root.add_child(base_scene.instantiate())
	var slots: Dictionary = loadout.get("slots", {})
	for slot in slots:
		var variant := str(slots[slot])
		if variant == CarManifest.NONE:
			continue
		var scene := get_scene(CarManifest.part_path(car, slot, variant))
		if scene == null:
			continue
		var part := scene.instantiate() as Node3D
		part.name = PART_PREFIX + slot
		root.add_child(part)
	_apply_piece_offsets(root, car)

	if paint == null:
		paint = make_paint_material(str(loadout.get("paint", "")))
	var glass := GLASS_MATERIAL.duplicate() as StandardMaterial3D
	WindowTint.apply(glass, str(loadout.get("tint", WindowTint.DEFAULT)))
	root.set_meta(PAINT_META, paint)
	root.set_meta(GLASS_META, glass)
	root.set_meta(LOADOUT_META, loadout.duplicate(true))
	apply_materials(root, paint, glass)
	_add_lenses(root)
	_add_cockpit_eye(root)
	_rig_steering_wheel(root)
	_rig_dash_screen(root)
	_rig_mirrors(root)
	if with_interior:
		_add_interior(root, car)
	return root

## The car's interior scene, authored in world units around the hull origin
## (what you see in its editor preview) - so it's scaled back down by the
## hull's own HULL_SCALE, which the hull root gets when it joins the car.
static func _add_interior(root: Node3D, car: String) -> void:
	var path := INTERIOR_DIR + car + "_Interior.tscn"
	if not ResourceLoader.exists(path):
		return
	var interior := (load(path) as PackedScene).instantiate() as Node3D
	var cam := interior.find_child(DRIVER_CAMERA, true, false) as Camera3D
	if cam:
		var eye := Marker3D.new()
		eye.name = DRIVER_EYE
		eye.transform = cam.transform
		eye.set_meta("fov", cam.fov)
		eye.set_meta("near", cam.near)
		var parent := cam.get_parent()
		parent.add_child(eye)
		parent.remove_child(cam)
		cam.free()
	interior.name = INTERIOR_NODE
	interior.scale = Vector3.ONE / CarConfigurator.HULL_SCALE
	interior.visible = false
	root.add_child(interior)

static func make_paint_material(paint_file: String) -> StandardMaterial3D:
	var mat := PAINT_BASE.duplicate() as StandardMaterial3D
	mat.albedo_texture = load_texture(paint_file)
	return mat

## Repaints a built hull (and everything sharing its paint material - the
## wheels) by swapping the albedo texture only.
static func set_paint(hull: Node, paint_file: String) -> void:
	var mat := hull.get_meta(PAINT_META, null) as StandardMaterial3D
	if mat:
		mat.albedo_texture = load_texture(paint_file)

## Re-tints a built hull's windows (WindowTint preset id) in place, keeping
## the current cockpit/outside view (set_cockpit_view()).
static func set_tint(hull: Node, tint: String) -> void:
	var mat := hull.get_meta(GLASS_META, null) as StandardMaterial3D
	if mat:
		WindowTint.apply(mat, tint, bool(hull.get_meta(COCKPIT_VIEW_META, false)))

## Driver's view from inside (cockpit camera) vs everyone else's: the glass
## switches to WindowTint's see-through "inside" version, and the windscreen
## sticker part (painted, opaque) is hidden so it doesn't block the road.
## Cheap to call every frame - does nothing unless the view changed.
static func set_cockpit_view(hull: Node, on: bool) -> void:
	if bool(hull.get_meta(COCKPIT_VIEW_META, false)) == on:
		return
	hull.set_meta(COCKPIT_VIEW_META, on)
	var mat := hull.get_meta(GLASS_META, null) as StandardMaterial3D
	if mat:
		WindowTint.apply(mat, str(mat.get_meta(WindowTint.TINT_META, WindowTint.DEFAULT)), on)
	var sticker := hull.get_node_or_null(PART_PREFIX + "Windscreen_Sticker") as Node3D
	if sticker:
		sticker.visible = not on

## The pack's "Glass" material. Also accepts Blender's "Glass.001"-style
## renames, which a round trip through Blender (import -> edit -> export)
## adds when a material name already exists in the .blend.
static func is_glass_material(mat: Material) -> bool:
	return mat != null and (mat.resource_name == "Glass" or mat.resource_name.begins_with("Glass."))

## "Glass" surfaces -> `glass`, everything else -> `paint`.
static func apply_materials(root: Node, paint: Material, glass: Material = GLASS_MATERIAL) -> void:
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null or mi.has_meta("lens"):
			continue
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s)
			var is_glass := is_glass_material(mat)
			mi.set_surface_override_material(s, glass if is_glass else paint)

static func _apply_piece_offsets(root: Node, car: String) -> void:
	var offsets: Dictionary = PIECE_OFFSETS.get(car, {})
	if offsets.is_empty():
		return
	var prefix := "SM_Veh_%s_" % car
	for mi in StructuredCarParts.mesh_instances(root):
		var n := String(mi.name)
		if n.begins_with(prefix) and offsets.has(n.substr(prefix.length())):
			mi.position += offsets[n.substr(prefix.length())]

# --- resource loading -------------------------------------------------------

## Cached scene load. If preload() already requested it on a thread, this
## picks that result up (waiting only for what's still in flight).
static func get_scene(path: String) -> PackedScene:
	if path.is_empty():
		return null
	if _scenes.has(path):
		return _scenes[path]
	var res: Resource
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS or status == ResourceLoader.THREAD_LOAD_LOADED:
		res = ResourceLoader.load_threaded_get(path)
	else:
		res = load(path)
	var scene := res as PackedScene
	if scene:
		_scenes[path] = scene
	return scene

static func load_texture(paint_file: String) -> Texture2D:
	if paint_file.is_empty():
		return null
	var path := CarManifest.texture_path(paint_file)
	var status := ResourceLoader.load_threaded_get_status(path)
	if status == ResourceLoader.THREAD_LOAD_IN_PROGRESS or status == ResourceLoader.THREAD_LOAD_LOADED:
		return ResourceLoader.load_threaded_get(path) as Texture2D
	return load(path) as Texture2D

## Starts background loads of every part/wheel/tyre scene `car` can use, so
## switching parts in the Customize screen doesn't hitch on first use.
static func preload_car(car: String) -> void:
	var paths := CarManifest.all_part_paths(car)
	for id in CarManifest.wheel_ids():
		paths.append(CarManifest.wheel_path(id))
	for id in CarManifest.tyre_ids():
		paths.append(CarManifest.tyre_path(id))
	for p in paths:
		if _scenes.has(p) or p.is_empty():
			continue
		if ResourceLoader.load_threaded_get_status(p) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			ResourceLoader.load_threaded_request(p)

## Background-loads a paint texture (Customize screen hover/tab open).
static func preload_texture(paint_file: String) -> void:
	var path := CarManifest.texture_path(paint_file)
	if ResourceLoader.has_cached(path):
		return
	if ResourceLoader.load_threaded_get_status(path) == ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
		ResourceLoader.load_threaded_request(path)

# --- lamp lenses ------------------------------------------------------------

const _LENS_GROUPS := ["headlight_L", "headlight_R", "rearlight_L", "rearlight_R"]

## Meta on each lens mesh: the part slots whose meshes it was copied from
## ("" = the base body). CarPartDetacher reads it so a bumper that carries a
## headlight's lens takes that headlight with it when it's knocked off.
const LENS_SOURCES_META := "lens_sources"

static func _add_lenses(root: Node3D) -> void:
	var sources: Array = [] # [lens dict, transform, part slot] per mesh with lenses
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null or String(mi.name).to_lower().contains("wheel"):
			continue
		var lens: Dictionary = _mesh_lenses(mi.mesh)
		if not lens.is_empty():
			sources.append([lens, _root_transform(mi, root), _part_slot(mi, root)])

	for g in _LENS_GROUPS:
		var v := PackedVector3Array()
		var vn := PackedVector3Array()
		var slots := PackedStringArray()
		for src_pair in sources:
			var lens: Dictionary = src_pair[0]
			var xf: Transform3D = src_pair[1]
			var nb := xf.basis.inverse().transposed()
			var src: PackedVector3Array = lens[g]
			var src_n: PackedVector3Array = lens[g + "_n"]
			if not src.is_empty() and not slots.has(src_pair[2]):
				slots.append(src_pair[2])
			for i in src.size():
				var n: Vector3 = (nb * src_n[i]).normalized()
				v.append(xf * src[i] + n * LENS_PUSH)
				vn.append(n)
		if v.is_empty():
			continue
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = vn
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var mi := MeshInstance3D.new()
		mi.name = g
		mi.mesh = mesh
		mi.set_meta("lens", true)
		mi.set_meta(LENS_SOURCES_META, slots)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.material_override = _lens_material(g.begins_with("headlight"))
		root.add_child(mi)

## Part slot ("Front_Bumper") of the Part_<Slot> node `node` sits under, or
## "" for the base body.
static func _part_slot(node: Node, root: Node) -> String:
	var n: Node = node
	while n != null and n != root:
		if String(n.name).begins_with(PART_PREFIX):
			return String(n.name).substr(PART_PREFIX.length())
		n = n.get_parent()
	return ""

static func _lens_material(head: bool) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	var color: Color = StructuredCarParts.HEADLIGHT_COLOR if head else StructuredCarParts.REARLIGHT_COLOR
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = HEADLIGHT_LENS_ENERGY if head else 1.2
	return mat

## Lens triangles of one mesh (mesh space), split by lamp and side (+X =
## left). Cached per Mesh resource - parts are shared between rebuilds.
static func _mesh_lenses(mesh: Mesh) -> Dictionary:
	if _lens_cache.has(mesh):
		return _lens_cache[mesh]
	var pts := {} # group -> Array[Vector3] while collecting (Arrays are references)
	var nrm := {}
	var found := false
	for g in _LENS_GROUPS:
		pts[g] = []
		nrm[g] = []
	for s in mesh.get_surface_count():
		var mat := mesh.surface_get_material(s)
		if is_glass_material(mat):
			continue
		var arrays := mesh.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var nor: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		if uv.is_empty():
			continue
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := idx.size() if not idx.is_empty() else pos.size()
		for t in range(0, count - 2, 3):
			var a := idx[t] if not idx.is_empty() else t
			var b := idx[t + 1] if not idx.is_empty() else t + 1
			var c := idx[t + 2] if not idx.is_empty() else t + 2
			var uvc: Vector2 = (uv[a] + uv[b] + uv[c]) / 3.0
			var lamp := ""
			if HEAD_LENS_UV.has_point(uvc):
				lamp = "headlight"
			elif TAIL_LENS_UV.has_point(uvc):
				lamp = "rearlight"
			else:
				continue
			var side := "_L" if (pos[a].x + pos[b].x + pos[c].x) > 0.0 else "_R"
			var g := lamp + side
			var group_pts: Array = pts[g]
			var group_nrm: Array = nrm[g]
			for k in [a, b, c]:
				group_pts.append(pos[k])
				group_nrm.append(nor[k] if not nor.is_empty() else Vector3.ZERO)
			found = true
	var out := {}
	if found:
		for g in _LENS_GROUPS:
			out[g] = PackedVector3Array(pts[g])
			out[g + "_n"] = PackedVector3Array(nrm[g])
	_lens_cache[mesh] = out
	return out

# --- cockpit eye ------------------------------------------------------------

## Marker at the driver's eye: centred on the steering wheel sideways,
## EYE_BEHIND_WHEEL back from it, EYE_ABOVE_WHEEL above its top - but kept
## EYE_BELOW_ROOF under the highest glass so a low roof never clips the view.
## No steering wheel (shouldn't happen in this pack) = no marker, and the
## cockpit camera falls back to the car's CAMERA_CENTRE.
static func _add_cockpit_eye(root: Node3D) -> void:
	var wheel := AABB()
	var have_wheel := false
	var glass_top := -INF
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null or mi.has_meta("lens"):
			continue
		var box: AABB = _root_transform(mi, root) * mi.mesh.get_aabb()
		if String(mi.name).to_lower().contains("steeringw"):
			wheel = box if not have_wheel else wheel.merge(box)
			have_wheel = true
		for s in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(s)
			if is_glass_material(mat):
				glass_top = maxf(glass_top, box.end.y)
				break
	if not have_wheel:
		return
	var eye_y := wheel.end.y + EYE_ABOVE_WHEEL
	if glass_top > -INF:
		eye_y = minf(eye_y, glass_top - EYE_BELOW_ROOF)
	var marker := Marker3D.new()
	marker.name = COCKPIT_EYE
	marker.position = Vector3(wheel.get_center().x, eye_y, wheel.position.z - EYE_BEHIND_WHEEL)
	root.add_child(marker)

# --- steering wheel -----------------------------------------------------------

## Moves the steering wheel mesh under a SteeringPivot at its hub (centre of
## its bounds) whose local +Z is the column axis, so spinning the pivot about
## Z turns the wheel in place. The axis is the direction the wheel's vertices
## vary LEAST along (the normal of the rim's plane) - measured per car, since
## each column tilts differently (16-21 degrees in this pack).
static func _rig_steering_wheel(root: Node3D) -> void:
	var mi: MeshInstance3D = null
	for m in StructuredCarParts.mesh_instances(root):
		if m.mesh != null and String(m.name).to_lower().contains("steeringw"):
			mi = m
			break
	if mi == null:
		return
	var xf := _root_transform(mi, root)
	var pts := PackedVector3Array()
	for s in mi.mesh.get_surface_count():
		for v in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			pts.append(xf * v)
	if pts.size() < 3:
		return
	var box := AABB(pts[0], Vector3.ZERO)
	var mean := Vector3.ZERO
	for p in pts:
		box = box.expand(p)
		mean += p
	mean /= pts.size()
	var axis := _least_variance_axis(pts, mean)
	if axis.z < 0.0:
		axis = -axis # point forward, away from the driver
	var x := Vector3.UP.cross(axis).normalized()
	var pivot := Node3D.new()
	pivot.name = STEERING_PIVOT
	pivot.transform = Transform3D(Basis(x, axis.cross(x), axis), box.get_center())
	pivot.set_script(STEERING_SPIN_SCRIPT)
	root.add_child(pivot)
	mi.get_parent().remove_child(mi)
	mi.owner = null
	pivot.add_child(mi)
	mi.transform = pivot.transform.affine_inverse() * xf

# --- dash screen / mirrors --------------------------------------------------

## A mesh named "*Dash_Screen*" becomes the live gauge display (dash_screen.gd).
static func _rig_dash_screen(root: Node3D) -> void:
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null or not String(mi.name).to_lower().contains(DASH_SCREEN_NAME):
			continue
		var frame := _reproject_screen(mi, root)
		if frame.is_empty():
			continue
		mi.set_script(DASH_SCREEN_SCRIPT)
		mi.set_meta("lens", true) # keeps outlines/lens scans off it
		mi.set_meta("dash_aspect", frame.aspect)

## Meshes named in MIRROR_NAMES become live side mirrors (side_mirror.gd).
## The mirror's plane and size go along as mesh-local meta, so the script can
## place its reflection camera from the mesh's live global transform.
static func _rig_mirrors(root: Node3D) -> void:
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null:
			continue
		var n := String(mi.name).to_lower()
		if not MIRROR_NAMES.any(func(m): return n.contains(m)):
			continue
		var frame := _reproject_screen(mi, root)
		if frame.is_empty():
			continue
		mi.set_script(SIDE_MIRROR_SCRIPT)
		mi.set_meta("lens", true)
		mi.set_meta("mirror_aspect", frame.aspect)
		mi.set_meta("mirror_center", frame.center_local)
		mi.set_meta("mirror_normal", frame.normal_local)
		mi.set_meta("mirror_half_height", frame.half_height_local)

## Replaces `mi`'s mesh with a copy whose UVs lie flat across the panel as
## the driver sees it (U = driver's right, V = down, 0..1 over its bounds), so
## a texture drawn into it reads upright - the Blender UVs don't matter. The
## panel's plane is its least-variance axis (like the steering wheel's), so a
## tilted or slightly curved panel still maps cleanly. Returns the panel's
## aspect (width / height) plus its centre, facing normal (toward the rear,
## i.e. the driver) and half-height vector in the mesh's own local space.
static func _reproject_screen(mi: MeshInstance3D, root: Node3D) -> Dictionary:
	var xf := _root_transform(mi, root)
	var pts := PackedVector3Array()
	for s in mi.mesh.get_surface_count():
		for v in mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			pts.append(xf * v)
	if pts.size() < 3:
		return {}
	var mean := Vector3.ZERO
	for p in pts:
		mean += p
	mean /= pts.size()
	var normal := _least_variance_axis(pts, mean)
	if normal.z > 0.0:
		normal = -normal # face back toward the driver (-Z)
	var right := Vector3.LEFT.slide(normal).normalized() # driver's right = -X (car +X is left)
	var up := Vector3.UP.slide(normal).slide(right).normalized()
	var r_min := INF
	var r_max := -INF
	var u_min := INF
	var u_max := -INF
	for p in pts:
		r_min = minf(r_min, p.dot(right))
		r_max = maxf(r_max, p.dot(right))
		u_min = minf(u_min, p.dot(up))
		u_max = maxf(u_max, p.dot(up))
	var w := maxf(r_max - r_min, 1e-5)
	var h := maxf(u_max - u_min, 1e-5)
	var out := ArrayMesh.new()
	for s in mi.mesh.get_surface_count():
		var src := mi.mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = src[Mesh.ARRAY_VERTEX]
		var uv := PackedVector2Array()
		uv.resize(verts.size())
		for i in verts.size():
			var p: Vector3 = xf * verts[i]
			uv[i] = Vector2((p.dot(right) - r_min) / w, 1.0 - (p.dot(up) - u_min) / h)
		var a := []
		a.resize(Mesh.ARRAY_MAX)
		a[Mesh.ARRAY_VERTEX] = verts
		a[Mesh.ARRAY_NORMAL] = src[Mesh.ARRAY_NORMAL]
		a[Mesh.ARRAY_TEX_UV] = uv
		a[Mesh.ARRAY_INDEX] = src[Mesh.ARRAY_INDEX]
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, a)
	mi.mesh = out
	var inv := xf.affine_inverse()
	var centre := right * (r_min + r_max) * 0.5 + up * (u_min + u_max) * 0.5 + normal * mean.dot(normal)
	return {
		"aspect": w / h,
		"center_local": inv * centre,
		"normal_local": (inv.basis * normal).normalized(),
		"half_height_local": inv.basis * (up * h * 0.5),
	}

## Eigenvector of the points' covariance with the smallest eigenvalue, by
## power iteration on (trace * I - C) - its largest eigenvector is C's smallest.
static func _least_variance_axis(pts: PackedVector3Array, mean: Vector3) -> Vector3:
	var cx := Vector3.ZERO # covariance rows
	var cy := Vector3.ZERO
	var cz := Vector3.ZERO
	for p in pts:
		var d := p - mean
		cx += d * d.x
		cy += d * d.y
		cz += d * d.z
	var tr := cx.x + cy.y + cz.z
	var m := Basis(Vector3(tr, 0, 0) - cx, Vector3(0, tr, 0) - cy, Vector3(0, 0, tr) - cz)
	var v := Vector3(0.3, 0.5, 0.8).normalized()
	for i in 64:
		var w := m * v
		if w.length_squared() < 1e-12:
			break
		v = w.normalized()
	return v

static func _root_transform(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t
