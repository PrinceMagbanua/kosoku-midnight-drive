class_name CarConfigurator
extends RefCounted

## Applies a CarProfile to the player-car scene (base car.tscn) at runtime, so
## one car scene serves every car (same lights/windows/wheel logic for all).
## base car.tscn is hard-wired to coupe.glb in several places (the body, four
## wheel meshes, head/brake lights); this swaps the hull and re-fits
## everything that depends on its shape, measured from the GLB itself:
##
## - wheel raycast positions (x/z from the hull's own wheel nodes),
## - tyre size (wheel.gd derives its radius from TyreSettings, so an integer
##   rim/aspect pair is solved to match the hull's wheel radius),
## - hull ground offset (so the body sits on the suspension like the coupe),
## - collision hull, exhaust/nitro fire positions, near-miss/hit extents.
##
## The COUPE is special: applying it restores a snapshot of base car.tscn's
## own authored values, taken the first time any profile is applied - so it
## behaves exactly as it always did, even after switching to another car and
## back. Timing: call this BEFORE the car's own _ready() (CarProfileApplier
## does it in _enter_tree) and no rebuild is needed; if the car is already
## ready, the hull-bound scripts are rebuilt in place.

const HULL_SCALE := 2.2078 # same uniform scale base car.tscn uses for VoxelCarMesh
const COUPE_HULL := preload("res://assets/cars/coupe.glb")
const HIDE_WHEELS_SCRIPT := preload("res://MAIN/misc/hide_embedded_wheels.gd")

## Reference geometry from base car.tscn (the coupe). GROUND_Y is the physics
## ground plane in car space: the coupe's settled wheel centre (hull offset
## -1.8237 + hull wheel centre y 0.3995 * 2.2078) minus its physics tyre
## radius (0.944, wheel.gd default TyreSettings). MID_Z is the midpoint of
## the raycast axles (front z 3.8, rear about -3.16).
const REF_GROUND_Y := -1.8857
const REF_MID_Z := 0.321

const TYRE_WIDTH := 185 # wheel.gd default, kept for every car
const CORNERS := ["FL", "FR", "BL", "BR"]
## raycast wheel node name -> hull corner name (rl/rr = rear left/right)
const WHEEL_NODES := {"fl": "FL", "fr": "FR", "rl": "BL", "rr": "BR"}
## car.gd exports scaled by CarStats: torque curve (both the normal and VVT
## sets), gearing, drag and clutch capacity. Anything containing "Torque", plus
## ClutchGrip, scales with `torque`.
const ENGINE_PROPS := [
	"OffsetTorque", "BuildUpTorque", "TorqueRise",
	"VVT_OffsetTorque", "VVT_BuildUpTorque", "VVT_TorqueRise",
	"FinalDriveRatio", "DragCoefficient",
	# The clutch clamps how much torque can reach the wheels (wheel.gd power()
	# limits it to ClutchGrip * 0.109). Scaled with the engine torque, or a
	# stronger engine just slips the clutch and pins at the rev limiter.
	"ClutchGrip",
]

const BASE_META := "_car_base_state"
const HULL_META := "_car_hull_path"

static var _metrics_cache: Dictionary = {}

static func apply(car: Node3D, profile: CarProfile) -> void:
	if profile == null or profile.hull_scene == null:
		return
	if not car.has_meta(BASE_META):
		car.set_meta(BASE_META, _capture_base(car))
	var base: Dictionary = car.get_meta(BASE_META)
	var is_base := profile.hull_scene.resource_path == COUPE_HULL.resource_path
	var fit: Dictionary = _base_fit(base) if is_base else _derive_fit(profile, base)
	if fit.is_empty():
		push_warning("CarConfigurator: could not measure hull for %s" % profile.id)
		return
	_apply_fit(car, profile, fit)
	retune(car, profile)

## Applies the profile's stats (plus purchased upgrades) to the car's physics
## config, always computed from the authored snapshot so it can be re-run
## safely whenever upgrades change. A coupe with no upgrades multiplies
## everything by exactly 1.0.
static func retune(car: Node3D, profile: CarProfile) -> void:
	if not car.has_meta(BASE_META):
		return
	var base: Dictionary = car.get_meta(BASE_META)
	var mult := CarStats.multipliers(CarStats.effective(profile))
	for prop in ENGINE_PROPS:
		var m: float
		if prop.contains("Torque") or prop == "ClutchGrip":
			m = mult.torque
		elif prop == "FinalDriveRatio":
			m = mult.final_drive
		else:
			m = mult.drag
		car.set(prop, float(base.engine[prop]) * m)
	for n in WHEEL_NODES:
		var w: Node3D = car.get_node(n)
		var tyre: Dictionary = w.get("TyreSettings")
		var authored: Dictionary = base.tyres[n]
		tyre["GripInfluence"] = float(authored["GripInfluence"]) * float(mult.grip)
		w.set("B_Torque", float(base.brake_torque[n]) * float(mult.brake))
		# Per-car tyre stiffness trim (CarProfile.tyre_stiffness) - a fresh copy
		# of the authored compound, so it never stacks across re-tunes.
		var compound: Dictionary = (base.compounds[n] as Dictionary).duplicate()
		compound["Stiffness"] = float(compound["Stiffness"]) * profile.tyre_stiffness
		w.set("CompoundSettings", compound)

	# Driver-feel values: authored directly on the profile (CarFeelConfig),
	# not derived from the stat multipliers or the base snapshot.
	profile.feel.apply_to(car)

# --- base snapshot / fit ------------------------------------------------

static func _capture_base(car: Node3D) -> Dictionary:
	var d := {"wheels": {}, "tyres": {}, "compounds": {}}
	for n in WHEEL_NODES:
		var w: Node3D = car.get_node(n)
		d.wheels[n] = w.position
		d.tyres[n] = (w.get("TyreSettings") as Dictionary).duplicate()
		d.compounds[n] = (w.get("CompoundSettings") as Dictionary).duplicate()
	d["hull_transform"] = (car.get_node("VoxelCarMesh") as Node3D).transform
	var col := car.get_node("CollisionShape") as CollisionShape3D
	d["col_shape"] = col.shape
	d["col_pos"] = col.position
	d["fire"] = (car.get_node("fire") as Node3D).position
	d["nitro_fire"] = (car.get_node("NitroFire") as Node3D).position
	# Authored physics values that CarStats scales (see retune()).
	d["engine"] = {}
	for prop in ENGINE_PROPS:
		d.engine[prop] = float(car.get(prop))
	d["brake_torque"] = {}
	for n in WHEEL_NODES:
		d.brake_torque[n] = float(car.get_node(n).get("B_Torque"))
	return d

static func _base_fit(base: Dictionary) -> Dictionary:
	var tyres := {}
	for n in WHEEL_NODES:
		tyres[n] = (base.tyres[n] as Dictionary).duplicate() # copies, so tuning never edits the snapshot
	return {
		"wheels": base.wheels, "tyres": tyres,
		"hull_transform": base.hull_transform,
		"col_shape": base.col_shape, "col_pos": base.col_pos,
		"fire": base.fire, "nitro_fire": base.nitro_fire,
		"w_scale": 1.0, "l_scale": 1.0,
	}

static func _derive_fit(profile: CarProfile, base: Dictionary) -> Dictionary:
	var m: Dictionary = _measure(profile.hull_scene)
	var ref: Dictionary = _measure(COUPE_HULL)
	if m.is_empty() or ref.is_empty():
		return {}
	var s := HULL_SCALE
	var wc: Dictionary = m.wheel_centres
	var front_z: float = (wc.FL.z + wc.FR.z) * 0.5 * s
	var rear_z: float = (wc.BL.z + wc.BR.z) * 0.5 * s
	var offset_z: float = REF_MID_Z - (front_z + rear_z) * 0.5
	var half_track: float = (absf(wc.FL.x) + absf(wc.FR.x) + absf(wc.BL.x) + absf(wc.BR.x)) * 0.25 * s
	var centre_y: float = (wc.FL.y + wc.FR.y + wc.BL.y + wc.BR.y) * 0.25
	var tyre := _solve_tyre(m.radius * s)
	var offset_y: float = REF_GROUND_Y + tyre.size - centre_y * s + profile.ground_trim

	# Raycast wheels: x/z from the hull, y kept as authored.
	var wheels := {}
	var tyres := {}
	for n in WHEEL_NODES:
		var corner: String = WHEEL_NODES[n]
		var authored: Vector3 = base.wheels[n]
		var side: float = 1.0 if corner.ends_with("L") else -1.0
		wheels[n] = Vector3(side * half_track, authored.y, wc[corner].z * s + offset_z)
		var t: Dictionary = (base.tyres[n] as Dictionary).duplicate()
		t["Width (mm)"] = float(TYRE_WIDTH)
		t["Aspect Ratio"] = float(tyre.aspect)
		t["Rim Size (in)"] = float(tyre.rim)
		tyres[n] = t

	# Body extents relative to the coupe: collision hull + near-miss/hit sizes.
	var body: AABB = m.body
	var ref_body: AABB = ref.body
	var kx: float = body.size.x / ref_body.size.x
	var kz: float = body.size.z / ref_body.size.z
	var body_centre_z: float = (body.position.z + body.size.z * 0.5) * s + offset_z
	var ref_centre_z: float = (ref_body.position.z + ref_body.size.z * 0.5) * s + (base.hull_transform as Transform3D).origin.z
	var rear: float = body.position.z * s + offset_z
	var ref_rear: float = ref_body.position.z * s + (base.hull_transform as Transform3D).origin.z
	var d_rear := Vector3(0.0, offset_y - (base.hull_transform as Transform3D).origin.y, rear - ref_rear)

	return {
		"wheels": wheels, "tyres": tyres,
		"hull_transform": Transform3D(Basis.from_scale(Vector3.ONE * s), Vector3(0.0, offset_y, offset_z)),
		"col_shape": _scaled_shape(base.col_shape as ConvexPolygonShape3D, kx, kz),
		"col_pos": (base.col_pos as Vector3) + Vector3(0.0, 0.0, body_centre_z - ref_centre_z),
		"fire": (base.fire as Vector3) + d_rear,
		"nitro_fire": (base.nitro_fire as Vector3) + d_rear,
		"w_scale": kx, "l_scale": kz,
	}

# --- applying -----------------------------------------------------------

static func _apply_fit(car: Node3D, profile: CarProfile, fit: Dictionary) -> void:
	var live := car.is_node_ready()
	var hull_path: String = profile.hull_scene.resource_path
	var swapped: bool = car.get_meta(HULL_META, COUPE_HULL.resource_path) != hull_path
	if swapped:
		_swap_hull(car, profile)
		car.set_meta(HULL_META, hull_path)
	(car.get_node("VoxelCarMesh") as Node3D).transform = fit.hull_transform

	for n in WHEEL_NODES:
		var w: Node3D = car.get_node(n)
		w.position = fit.wheels[n]
		w.set("TyreSettings", fit.tyres[n])
	if swapped:
		_dress_wheels(car, profile, live)
	# Head and rear lights are placed from the hull's transform but not
	# parented under it (so the cockpit view can hide the hull without killing
	# them) - they need re-placing whenever the hull transform changes, not
	# only on a swap.
	if live:
		_rebuild_lights(car)

	var col := car.get_node("CollisionShape") as CollisionShape3D
	col.shape = fit.col_shape
	col.position = fit.col_pos
	# Centre of mass. The automatic one (GodotPhysics3D) sits at the collision
	# shape's origin - the same height for every hull - so a profile can sink
	# it from there (CarProfile.com_drop). AUTO again for a car that doesn't.
	var body := car as RigidBody3D
	if body:
		if is_zero_approx(profile.com_drop):
			body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_AUTO
		else:
			body.center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
			body.center_of_mass = col.position - Vector3(0.0, profile.com_drop, 0.0)
	(car.get_node("fire") as Node3D).position = fit.fire
	(car.get_node("NitroFire") as Node3D).position = fit.nitro_fire

	# Read by CrashSystem to scale its near-miss / hit extents (authored for the coupe).
	car.set_meta("hull_w_scale", fit.w_scale)
	car.set_meta("hull_l_scale", fit.l_scale)
	car.set_meta("car_profile_id", profile.id)

## Replaces VoxelCarMesh with `profile`'s hull: the single GLB for an old
## car, or a ModularCarBuilder build of the saved loadout for a modular one.
## `paint` lets a loadout rebuild keep the existing paint material (the
## wheels share it).
static func _swap_hull(car: Node3D, profile: CarProfile, paint: StandardMaterial3D = null) -> void:
	var old := car.get_node("VoxelCarMesh") as Node3D
	var index := old.get_index()
	var keep_transform := old.transform
	var keep_visible := old.visible
	car.remove_child(old)
	old.queue_free()
	var hull: Node3D
	if profile.manifest_id.is_empty():
		hull = profile.hull_scene.instantiate() as Node3D
		StructuredCarParts.force_opaque(hull)
	else:
		hull = ModularCarBuilder.build(profile.manifest_id, SaveData.get_loadout(profile.id), paint)
	hull.name = "VoxelCarMesh"
	hull.set_script(HIDE_WHEELS_SCRIPT) # hides the hull's own baked-in wheels
	hull.transform = keep_transform
	hull.visible = keep_visible
	car.add_child(hull)
	car.move_child(hull, index)

## Points each corner's HullWheel at the profile's hull, and for modular cars
## at the loadout's custom rim/tyre (or the stock wheel) + the hull's paint.
static func _dress_wheels(car: Node3D, profile: CarProfile, live: bool) -> void:
	var hull := car.get_node("VoxelCarMesh")
	var loadout: Dictionary = hull.get_meta(ModularCarBuilder.LOADOUT_META, {})
	var rim: PackedScene = null
	var tyre: PackedScene = null
	var wheel := str(loadout.get("wheel", CarManifest.STOCK))
	if not loadout.is_empty() and wheel != CarManifest.STOCK:
		rim = ModularCarBuilder.get_scene(CarManifest.wheel_path(wheel))
		tyre = ModularCarBuilder.get_scene(CarManifest.tyre_path(str(loadout.get("tyre", ""))))
	var paint: Material = hull.get_meta(ModularCarBuilder.PAINT_META, null)
	for n in WHEEL_NODES:
		var hw: Node = car.get_node(n).get_node_or_null("animation/camber/wheel/HullWheel")
		if hw == null:
			continue
		hw.set("hull_scene", profile.hull_scene)
		hw.set("rim_scene", rim)
		hw.set("tyre_scene", tyre)
		hw.set("paint_material", paint)
		if live:
			hw.call("rebuild")

static func _rebuild_lights(car: Node3D) -> void:
	for light_node in ["HullBrakeLights", "HullHeadlights"]:
		var l: Node = car.get_node_or_null(light_node)
		if l:
			l.call("rebuild")

## Re-dresses a modular car after its loadout changed (Customize screen),
## touching only what changed: paint = an albedo swap, tint = a glass
## material edit, wheels = the four
## HullWheels, parts = a hull rebuild (+ lights, whose lens meshes live in
## the hull). No physics refit - parts don't change the car's dimensions.
static func refresh_loadout(car: Node3D, profile: CarProfile) -> void:
	if profile.manifest_id.is_empty() or car.get_meta("car_profile_id", "") != profile.id:
		return
	var hull := car.get_node_or_null("VoxelCarMesh") as Node3D
	if hull == null:
		return
	var new_loadout := SaveData.get_loadout(profile.id)
	var old_loadout: Dictionary = hull.get_meta(ModularCarBuilder.LOADOUT_META, {})
	var live := car.is_node_ready()
	if new_loadout.get("slots") != old_loadout.get("slots"):
		var paint := hull.get_meta(ModularCarBuilder.PAINT_META, null) as StandardMaterial3D
		_swap_hull(car, profile, paint)
		hull = car.get_node("VoxelCarMesh") as Node3D
		if live:
			_rebuild_lights(car)
	if new_loadout.get("paint") != old_loadout.get("paint"):
		ModularCarBuilder.set_paint(hull, str(new_loadout.get("paint", "")))
	if new_loadout.get("tint") != old_loadout.get("tint"):
		ModularCarBuilder.set_tint(hull, str(new_loadout.get("tint", WindowTint.DEFAULT)))
	hull.set_meta(ModularCarBuilder.LOADOUT_META, new_loadout.duplicate(true))
	if new_loadout.get("wheel") != old_loadout.get("wheel") or new_loadout.get("tyre") != old_loadout.get("tyre"):
		_dress_wheels(car, profile, live)

# --- measuring the hull -------------------------------------------------

## Wheel centres (hull-root space), wheel radius and body AABB for one hull.
static func _measure(scene: PackedScene) -> Dictionary:
	var key := scene.resource_path
	if _metrics_cache.has(key):
		return _metrics_cache[key]
	var hull := scene.instantiate() as Node3D
	var centres := {}
	var radius := 0.0
	for corner in CORNERS:
		var node := StructuredCarParts.find_part(hull, StructuredCarParts.wheel_patterns(corner)) as MeshInstance3D
		if node == null or node.mesh == null:
			hull.free()
			return {}
		var box: AABB = node.mesh.get_aabb()
		centres[corner] = _root_transform(node, hull) * (box.position + box.size * 0.5)
		radius = maxf(radius, maxf(box.size.y, box.size.z) * 0.5)
	var body := AABB()
	var have_body := false
	for mi in StructuredCarParts.mesh_instances(hull):
		var n := mi.name.to_lower()
		if mi.mesh == null or n.contains("wheel") or n.contains("light") or n.contains("window"):
			continue
		var box: AABB = _root_transform(mi, hull) * mi.mesh.get_aabb()
		body = box if not have_body else body.merge(box)
		have_body = true
	hull.free()
	if not have_body:
		return {}
	var result := {"wheel_centres": centres, "radius": radius, "body": body}
	_metrics_cache[key] = result
	return result

static func _root_transform(node: Node, root: Node) -> Transform3D:
	var t := Transform3D.IDENTITY
	var n: Node = node
	while n != null and n != root:
		if n is Node3D:
			t = (n as Node3D).transform * t
		n = n.get_parent()
	return t

# --- tyre + collision helpers ---------------------------------------------

## wheel.gd's own formula (integer width/aspect/rim), kept identical.
static func _tyre_radius(rim: int, aspect: int) -> float:
	return ((absi(TYRE_WIDTH) * ((absi(aspect) * 2.0) / 100.0) + absi(rim) * 25.4) * 0.003269) / 2.0

## Integer rim/aspect whose radius best matches `radius` (leaning toward
## ordinary-looking aspect ratios so the tyre stays plausible).
static func _solve_tyre(radius: float) -> Dictionary:
	var best := {"rim": 14, "aspect": 60, "size": _tyre_radius(14, 60)}
	var best_err := INF
	for rim in range(5, 21):
		for aspect in range(20, 91):
			var size := _tyre_radius(rim, aspect)
			var err := absf(size - radius) + 0.00001 * absf(aspect - 55)
			if err < best_err:
				best_err = err
				best = {"rim": rim, "aspect": aspect, "size": size}
	return best

## A copy of the coupe's convex collision hull, widened/lengthened about its
## own centre to match another body (x by kx, z by kz; height unchanged).
static func _scaled_shape(shape: ConvexPolygonShape3D, kx: float, kz: float) -> ConvexPolygonShape3D:
	var pts := shape.points
	var zmin := INF
	var zmax := -INF
	for p in pts:
		zmin = minf(zmin, p.z)
		zmax = maxf(zmax, p.z)
	var zc := (zmin + zmax) * 0.5
	var out := PackedVector3Array()
	for p in pts:
		out.append(Vector3(p.x * kx, p.y, zc + (p.z - zc) * kz))
	var copy := ConvexPolygonShape3D.new() # own resource: the scene's shape is shared by every car instance
	copy.points = out
	return copy
