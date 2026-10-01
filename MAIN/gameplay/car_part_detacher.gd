class_name CarPartDetacher
extends Node

## Visual side of CarDamageModel: finds the hull nodes behind each armor
## piece (plus the bolt-ons that ride along with it) and, when the piece is
## lost, rips them off the car - the originals are hidden and a copy tumbles
## away as a RigidBody3D, with glass shards and broken lamps where it
## applies. restore_all() puts everything back (next run, menus).
##
## The pack's meshes have no hinge pivots (everything sits at the hull
## origin), so each flying copy is re-centred on its own bounds instead.
## Flying copies collide with the road/walls only - never the player (a
## collision exception) or traffic (layers) - so debris can't count as a hit.

## Bolt-on part slots (ModularCarBuilder "Part_<Slot>") that leave with a piece.
const PIECE_PARTS := {
	"front_bumper": ["Front_Bumper", "Light_Covers", "Nudge_Bar"],
	"bonnet": ["Bonnet", "Louvers"],
	"rear_bumper": ["Rear_Bumper", "Spoiler", "Spoiler_Boot", "Exhaust", "Wheelie_Bars"],
}
## Door piece -> base mesh name suffix ("SM_Veh_<Car>" + suffix).
const DOOR_SUFFIX := {
	"door_l": "_Door_L", "door_r": "_Door_R",
	"door_lf": "_Door_LF", "door_lr": "_Door_LR",
	"door_rf": "_Door_RF", "door_rr": "_Door_RR",
}
## Car side -> the door pieces on it. Fender door flares ("..._Fenders_02_Door_L")
## and that side's half of the side skirts ride with them (with whichever
## door goes first on 4-door cars).
const SIDE_DOORS := {"L": ["door_l", "door_lf", "door_lr"], "R": ["door_r", "door_rf", "door_rr"]}
## Which lamp script a bumper breaks, and the lens-source slot that means the
## lens sits ON that bumper (ModularCarBuilder.LENS_SOURCES_META).
const BUMPER_LAMPS := {
	"front_bumper": ["HullHeadlights", "Front_Bumper"],
	"rear_bumper": ["HullBrakeLights", "Rear_Bumper"],
}

const SKIRT_SLOT := "Side_Skirts"
const SKIRT_SIDE_META := "damage_skirt_side"
const SKIRT_SPLIT_META := "damage_skirt_split"

const UNIT_SCALE := RoadMetrics.UNIT_SCALE
## Flying copies: own physics layer (bit 5), colliding with world layer 1 only.
const DEBRIS_LAYER := 1 << 4
const DEBRIS_MASK := 1
const PIECE_MASS := 6.0 # player car is 90
const MIN_BOX := 0.12 * UNIT_SCALE # collision box never thinner than this (panels are paper-thin)
## Launch velocity: a share of the car's velocity plus a pop up and outward
## (m/s, converted), each randomized by +-POP_RANDOM.
const CARRY_FRAC := 0.75
const POP_UP := 4.5 * UNIT_SCALE
const POP_OUT := 3.0 * UNIT_SCALE
const POP_RANDOM := 0.3
const SPIN_MAX := 9.0 # rad/s per axis
const DEBRIS_LIFETIME := 3.0 # seconds on the road before shrinking away
const DEBRIS_SHRINK := 0.4
const MAX_FLYING := 8 # oldest copy goes when a new one would exceed this

## Quick point flash where a piece rips off (rides on the flying copy):
## a light + a glowing billboard, gone in FLASH_TIME real seconds.
const FLASH_TIME := 0.18
const FLASH_COLOR := Color(1.0, 0.92, 0.75)
const FLASH_ENERGY := 8.0
const FLASH_RANGE := 3.0 * UNIT_SCALE
const FLASH_SIZE := 1.6 # glow quad size, world units

const GLASS_SCENE := preload("res://MAIN/misc/GlassShards.tscn")
const DOOR_GLASS_SHARDS := 40
const LAMP_GLASS_SHARDS := 16
const SFX_GLASS := [
	preload("res://MAIN/sfx/glass/glass-shatter-freesound.mp3"),
	preload("res://MAIN/sfx/glass/glass-shatter-universfield-.mp3"),
]
## Panel rip: the metal hit clips, pitched down so it reads as tearing metal.
const SFX_RIP := [
	preload("res://MAIN/sfx/freesound_community-car-hit.mp3"),
	preload("res://MAIN/sfx/floraphonic-metal-hit.mp3"),
]

var _car: RigidBody3D
var _hull: Node3D
## piece id -> Array[Node3D] currently bound to it.
var _nodes := {}
var _flying: Array[RigidBody3D] = []
var _debris_material := PhysicsMaterial.new()

func _ready() -> void:
	_debris_material.bounce = 0.25
	_debris_material.friction = 0.8

## Scans `car`'s hull (VoxelCarMesh). Returns true for a 4-door car.
func bind(car: RigidBody3D) -> bool:
	_car = car
	_hull = (car.get_node_or_null("VoxelCarMesh") as Node3D) if car else null
	_nodes.clear()
	clear_flying()
	if _hull == null:
		return false
	for piece in PIECE_PARTS:
		for slot in PIECE_PARTS[piece]:
			var part := _hull.get_node_or_null(ModularCarBuilder.PART_PREFIX + slot) as Node3D
			if part:
				_add(piece, part)
	var skirts := _hull.get_node_or_null(ModularCarBuilder.PART_PREFIX + SKIRT_SLOT) as Node3D
	if skirts:
		_split_skirts(skirts)
		for half in skirts.find_children("*", "MeshInstance3D", true, false):
			if half.has_meta(SKIRT_SIDE_META):
				for piece in SIDE_DOORS[half.get_meta(SKIRT_SIDE_META)]:
					_add(piece, half)
	var four_doors := false
	var car_id := str(_hull.get_meta(ModularCarBuilder.CAR_META, ""))
	if not car_id.is_empty():
		var prefix := "SM_Veh_" + car_id
		for mi in StructuredCarParts.mesh_instances(_hull):
			var n := String(mi.name)
			if _in_part(mi):
				for side in ["L", "R"]:
					if n.contains("_Fenders_") and n.ends_with("_Door_" + side):
						for piece in SIDE_DOORS[side]:
							_add(piece, mi)
				continue
			for piece in DOOR_SUFFIX:
				if n == prefix + DOOR_SUFFIX[piece]:
					_add(piece, mi)
					if piece.length() == 7: # door_lf etc.
						four_doors = true
	return four_doors

## `piece` was lost to a hit/scrape on `hit_side` ("L"/"R") of `zone`
## (CarDamageModel.Zone).
func lose(piece: String, zone: int, hit_side: String) -> void:
	var is_door := piece.begins_with("door_")
	var played_rip := false
	for n in _nodes.get(piece, []):
		if not is_instance_valid(n) or not n.visible:
			continue # already gone with another piece (shared rider)
		if _car and _hull and _hull.is_inside_tree():
			var centre := _launch(n, zone, hit_side)
			if is_door and not _in_part(n): # the door itself, not a flare/skirt riding with it
				_spawn_glass(centre, DOOR_GLASS_SHARDS)
				_play(SFX_GLASS, 1.0, randf_range(0.9, 1.05))
			played_rip = true
		n.visible = false
	if played_rip:
		_play(SFX_RIP, 0.8, randf_range(0.6, 0.75))
	if BUMPER_LAMPS.has(piece):
		_break_bumper_lamps(piece, hit_side)

func restore_all() -> void:
	for piece in _nodes:
		for n in _nodes[piece]:
			if is_instance_valid(n):
				n.visible = true
	for lamp in ["HullHeadlights", "HullBrakeLights"]:
		var l := _lamps(lamp)
		if l:
			l.restore()

func clear_flying() -> void:
	for b in _flying:
		if is_instance_valid(b):
			b.queue_free()
	_flying.clear()

# --- lamps ---------------------------------------------------------------

## The hit side's lamp always breaks; so does any lamp whose lens was copied
## from this bumper's own mesh (Muscle/Hatch headlights) - it leaves with it.
## A broken brake light goes dark; a broken headlight stays on but faulty -
## weak, flickering and sparking (headlight_lights.gd's break_side).
func _break_bumper_lamps(piece: String, hit_side: String) -> void:
	var lamps := _lamps(BUMPER_LAMPS[piece][0])
	if lamps == null:
		return
	var slot: String = BUMPER_LAMPS[piece][1]
	for side in ["L", "R"]:
		var mesh: MeshInstance3D = lamps.lens_mesh(side)
		if mesh == null:
			continue
		var on_bumper: bool = PackedStringArray(mesh.get_meta(ModularCarBuilder.LENS_SOURCES_META, PackedStringArray())).has(slot)
		if side != hit_side and not on_bumper:
			continue
		var pos: Vector3 = lamps.lens_center(side)
		if lamps.break_side(side):
			_spawn_glass(pos, LAMP_GLASS_SHARDS)
			_play(SFX_GLASS, 0.55, randf_range(1.2, 1.45))

func _lamps(node_name: String) -> Node:
	if _car == null:
		return null
	var l := _car.get_node_or_null(node_name)
	return l if l and l.has_method("break_side") else null

# --- flying copies -------------------------------------------------------

## Spawns a tumbling copy of `node` where it sits now. Returns its world centre.
func _launch(node: Node3D, zone: int, hit_side: String) -> Vector3:
	var hull_xf := _hull.global_transform
	var to_hull := hull_xf.affine_inverse()
	var box := AABB()
	var have := false
	for mi in StructuredCarParts.mesh_instances(node):
		if mi.mesh == null or mi.has_meta("lens"):
			continue
		var b: AABB = (to_hull * mi.global_transform) * mi.mesh.get_aabb()
		box = b if not have else box.merge(b)
		have = true
	if not have:
		return node.global_position
	var centre := hull_xf * box.get_center()

	var body := RigidBody3D.new()
	body.collision_layer = DEBRIS_LAYER
	body.collision_mask = DEBRIS_MASK
	body.mass = PIECE_MASS
	body.continuous_cd = true
	body.physics_material_override = _debris_material
	var shape := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	var size := box.size * hull_xf.basis.get_scale().x
	bs.size = Vector3(maxf(size.x, MIN_BOX), maxf(size.y, MIN_BOX), maxf(size.z, MIN_BOX))
	shape.shape = bs
	body.add_child(shape)
	var visual := node.duplicate() as Node3D
	_strip(visual)
	visual.visible = true
	body.add_child(visual)
	_car.get_parent().add_child(body)
	body.global_transform = Transform3D(hull_xf.basis.orthonormalized(), centre)
	visual.global_transform = node.global_transform
	body.add_collision_exception_with(_car)
	_spawn_flash(body)

	var fwd := _car.global_basis.z
	var left := _car.global_basis.x # hull/car +X is the car's left
	var skew := left * (0.4 if hit_side == "L" else -0.4)
	var out := -left
	if zone == CarDamageModel.Zone.FRONT:
		out = fwd + skew
	elif zone == CarDamageModel.Zone.REAR:
		out = -fwd + skew
	elif zone == CarDamageModel.Zone.LEFT:
		out = left
	out.y = 0.0
	out = out.normalized()
	body.linear_velocity = _car.linear_velocity * CARRY_FRAC \
		+ out * POP_OUT * randf_range(1.0 - POP_RANDOM, 1.0 + POP_RANDOM) \
		+ Vector3.UP * POP_UP * randf_range(1.0 - POP_RANDOM, 1.0 + POP_RANDOM)
	body.angular_velocity = Vector3(randf_range(-SPIN_MAX, SPIN_MAX), randf_range(-SPIN_MAX, SPIN_MAX), randf_range(-SPIN_MAX, SPIN_MAX))

	_flying.append(body)
	while _flying.size() > MAX_FLYING:
		var old: RigidBody3D = _flying.pop_front()
		if is_instance_valid(old):
			old.queue_free()
	var tw := body.create_tween()
	tw.tween_interval(DEBRIS_LIFETIME)
	tw.tween_property(visual, "scale", visual.scale * 0.01, DEBRIS_SHRINK)
	tw.tween_callback(_expire.bind(body))
	return centre

func _expire(body: RigidBody3D) -> void:
	_flying.erase(body)
	body.queue_free()

## Drops anything from a copied piece that shouldn't fly with it: scripted
## nodes (live mirrors/screens), lens overlays, lights, cameras.
func _strip(node: Node) -> void:
	for child in node.get_children():
		if child.get_script() != null or child.has_meta("lens") or child is Light3D or child is Camera3D:
			node.remove_child(child)
			child.free()
		else:
			_strip(child)
	if node.get_script() != null:
		node.set_script(null)

func _spawn_flash(parent: Node3D) -> void:
	var light := OmniLight3D.new()
	light.light_color = FLASH_COLOR
	light.light_energy = FLASH_ENERGY
	light.omni_range = FLASH_RANGE
	light.shadow_enabled = false
	parent.add_child(light)
	var glow := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE * FLASH_SIZE
	glow.mesh = quad
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glow.material_override = _flash_material()
	parent.add_child(glow)
	var mat := glow.material_override as StandardMaterial3D
	var tw := light.create_tween().set_ignore_time_scale(true).set_parallel(true)
	tw.tween_property(light, "light_energy", 0.0, FLASH_TIME).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(glow, "scale", Vector3.ONE * 1.8, FLASH_TIME).set_ease(Tween.EASE_OUT)
	tw.tween_property(mat, "albedo_color:a", 0.0, FLASH_TIME)
	tw.chain().tween_callback(light.queue_free)
	tw.tween_callback(glow.queue_free)

func _flash_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.no_depth_test = true # a flash reads over the piece it comes from
	m.albedo_color = FLASH_COLOR
	m.albedo_texture = _flash_texture()
	return m

static var _flash_tex: GradientTexture2D

## Soft round dot, made once.
static func _flash_texture() -> GradientTexture2D:
	if _flash_tex == null:
		var g := Gradient.new()
		g.set_color(0, Color(1, 1, 1, 1))
		g.set_color(1, Color(1, 1, 1, 0))
		_flash_tex = GradientTexture2D.new()
		_flash_tex.gradient = g
		_flash_tex.fill = GradientTexture2D.FILL_RADIAL
		_flash_tex.fill_from = Vector2(0.5, 0.5)
		_flash_tex.fill_to = Vector2(0.5, 0.0)
		_flash_tex.width = 64
		_flash_tex.height = 64
	return _flash_tex

func _spawn_glass(pos: Vector3, amount: int) -> void:
	var glass: CPUParticles3D = GLASS_SCENE.instantiate()
	glass.amount = amount
	glass.set("carry_velocity", _car.linear_velocity * 0.85 if _car else Vector3.ZERO)
	_car.get_parent().add_child(glass)
	glass.global_position = pos

func _play(streams: Array, volume: float, pitch: float) -> void:
	var p := AudioStreamPlayer.new()
	p.stream = streams[randi() % streams.size()]
	p.pitch_scale = pitch
	p.volume_db = linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume * volume, 0.0001, 1.0))
	add_child(p)
	p.finished.connect(p.queue_free)
	p.play()

# --- side skirts -----------------------------------------------------------

## The skirts part is one mesh for both sides; splits each of its meshes once
## (per hull) into a left and a right half so each can leave with its side's
## door. The original is hidden and the halves added beside it.
func _split_skirts(part: Node3D) -> void:
	if part.has_meta(SKIRT_SPLIT_META):
		return
	part.set_meta(SKIRT_SPLIT_META, true)
	var to_hull := _hull.global_transform.affine_inverse()
	for mi in StructuredCarParts.mesh_instances(part):
		if mi.mesh == null:
			continue
		var xf: Transform3D = to_hull * mi.global_transform
		for side in ["L", "R"]:
			var half := _half_mesh(mi, xf, side == "L")
			if half == null:
				continue
			half.name = String(mi.name) + "_" + side
			half.set_meta(SKIRT_SIDE_META, side)
			mi.get_parent().add_child(half)
			half.transform = mi.transform
		mi.visible = false

## Copy of `mi` keeping only the triangles on one side (hull +X = left).
func _half_mesh(mi: MeshInstance3D, xf: Transform3D, left: bool) -> MeshInstance3D:
	var src := mi.mesh
	var out := ArrayMesh.new()
	var overrides := []
	for s in src.get_surface_count():
		var arrays := src.surface_get_arrays(s)
		var pos: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		if idx.is_empty():
			for i in pos.size():
				idx.append(i)
		var keep := PackedInt32Array()
		for t in range(0, idx.size() - 2, 3):
			var c: Vector3 = xf * ((pos[idx[t]] + pos[idx[t + 1]] + pos[idx[t + 2]]) / 3.0)
			if (c.x > 0.0) == left:
				keep.append(idx[t])
				keep.append(idx[t + 1])
				keep.append(idx[t + 2])
		if keep.is_empty():
			continue
		arrays[Mesh.ARRAY_INDEX] = keep
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(out.get_surface_count() - 1, src.surface_get_material(s))
		overrides.append(mi.get_surface_override_material(s))
	if out.get_surface_count() == 0:
		return null
	var half := MeshInstance3D.new()
	half.mesh = out
	half.cast_shadow = mi.cast_shadow
	for s in overrides.size():
		half.set_surface_override_material(s, overrides[s])
	return half

# --- binding helpers ---------------------------------------------------------

func _add(piece: String, node: Node3D) -> void:
	if not _nodes.has(piece):
		_nodes[piece] = []
	if not _nodes[piece].has(node):
		_nodes[piece].append(node)

func _in_part(node: Node) -> bool:
	var n := node.get_parent()
	while n != null and n != _hull:
		if String(n.name).begins_with(ModularCarBuilder.PART_PREFIX):
			return true
		n = n.get_parent()
	return false
