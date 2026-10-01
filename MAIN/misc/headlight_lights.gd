extends Node3D

## Finds the actual headlight_L/headlight_R meshes inside whichever hull is
## assigned (VoxelCarMesh) and adds a real SpotLight3D as a child of each -
## same "use the model's own named parts" approach as wheel_hull_mesh.gd.
## Matching goes through StructuredCarParts (structured_car_parts.gd), which
## documents this asset pack's naming convention.
##
## No true IES photometric profile (Godot has no built-in IES import - the
## closest equivalent is a `light_projector` cookie texture on the SpotLight,
## not set here since no such texture exists in this project yet). Plain
## warm-white spotlight tuned to look like a headlight cone, colored to
## match the pack's own documented headlight material
## (StructuredCarParts.HEADLIGHT_COLOR).
##
## Tuning constants live in HeadlightSpec (headlight_spec.gd), shared with
## traffic_car.gd's own headlight attachment so player and traffic cars
## always match instead of drifting apart via two separate copies.

@export var hull_path: NodePath = NodePath("../VoxelCarMesh")

# How far the beam tilts DOWN from dead-level, in degrees. VoxelCarMesh (the
# player's hull instance in base car.tscn) carries no rotation of its own -
# only uniform scale - so `Vector3(0, PI, 0)` below is the sole yaw
# correction needed to aim the light along the car's real forward (+Z, per
# the front wheel nodes' own local Z sign) and was verified correct via a
# headless world-space aim measurement.
#
# The beam itself was never actually broken - user confirmed with their own
# orbit-camera screenshot that it lights up the road correctly right in
# front of the car. What made it look "invisible driving straight, visible
# turning" was the default chase camera: it sits low and close behind the
# car, so at a steep tilt the nearby light pool lands almost directly under
# the hood/roof and gets hidden behind the car's own silhouette from that
# viewing angle - not hidden when swept sideways since there's no longer a
# hood in the way. Lowered from -8 to -4 so the pool lands twice as far
# ahead (given the same headlamp height, contact distance scales with
# 1/tan(tilt)) - far enough out from under the car to actually be visible
# from the default chase view, not just from the side.
const DOWNWARD_TILT_DEG := -4.0

## A damaged lamp (front bumper torn off - see break_side): still lit, but at
## DAMAGED_ENERGY of its normal beam, flickering between FLICKER_MIN and full
## of that, and shorting out every SPARK_INTERVAL seconds - the beam cuts for
## DROPOUT_TIME and a few sparks spit from the lamp at the same moment.
const DAMAGED_ENERGY := 0.35
const FLICKER_MIN := 0.55
const FLICKER_RATE := 12.0 # flicker speed, roughly per second
const SPARK_INTERVAL := Vector2(0.25, 0.9) # seconds between short-outs (random in range)
const DROPOUT_TIME := 0.06
const SPARK_AMOUNT := Vector2i(4, 9) # particles per burst (random in range)
const SPARK_SPEED := Vector2(2.0, 7.0) # spark launch speed, world units/s
const SPARK_LIFETIME := 0.35
const SPARKS_SCENE := preload("res://MAIN/misc/ImpactSparks.tscn")
# Same "ride along with the car" launch crash_system.gd's bursts use.
const SPARK_CARRY_FRAC := 0.85
const SPARK_LEAD_TIME := 0.06

var _lights: Array[SpotLight3D] = []
## "L"/"R" -> {"light": SpotLight3D, "mesh": the lens MeshInstance3D}.
var _by_side := {}
## Damaged sides: "L"/"R" -> {"next_spark": s until the next short-out,
## "dropout": s of beam cut left, "phase": this lamp's own flicker pattern}.
var _damaged := {}
var _energy: float = HeadlightSpec.LIGHT_ENERGY # undamaged beam energy right now (flash() pulses it)
var _time := 0.0
var _noise := FastNoiseLite.new()

## Re-attaches the lights to the (possibly swapped) hull. The lights live
## under this node, not the hull, so the old ones are freed here explicitly.
func rebuild() -> void:
	_ready()

func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0
	_damaged.clear()
	_energy = HeadlightSpec.LIGHT_ENERGY
	set_process(false)
	for old in _lights:
		if is_instance_valid(old):
			old.queue_free()
	_lights.clear()
	_by_side.clear()
	var hull: Node3D = get_node_or_null(hull_path)
	if hull == null:
		return
	_attach_light(StructuredCarParts.find_part(hull, ["headlight_l"]), "L")
	_attach_light(StructuredCarParts.find_part(hull, ["headlight_r"]), "R")

func _attach_light(mesh_node: Node3D, side: String) -> void:
	if mesh_node == null or not (mesh_node is MeshInstance3D) or (mesh_node as MeshInstance3D).mesh == null:
		return
	var light := SpotLight3D.new()
	# Pitch (about local X) applied BEFORE the yaw flip, so "down" means
	# down relative to the car's own forward-facing frame regardless of the
	# 180 correction - composed explicitly via Basis multiplication rather
	# than a Vector3 Euler triple, since Euler component order is easy to
	# get backwards for a combined yaw+pitch and this needs to be right.
	var aim := Basis(Vector3(0, 1, 0), PI) * Basis(Vector3(1, 0, 0), deg_to_rad(DOWNWARD_TILT_DEG))
	# Same bug class as the wheel meshes: the mesh's own node origin isn't
	# necessarily where its geometry actually is. Without this, the light
	# sat at (0,0,0) local to headlight_L/R - measured, this is NOT where
	# the visible lens geometry is, so the light ended up positioned
	# somewhere else entirely (likely inside the body, occluded).
	var local_aabb: AABB = (mesh_node as MeshInstance3D).mesh.get_aabb()
	var in_mesh := Transform3D(aim, local_aabb.position + local_aabb.size / 2.0)
	light.light_color = StructuredCarParts.HEADLIGHT_COLOR
	light.light_energy = HeadlightSpec.LIGHT_ENERGY
	light.spot_range = HeadlightSpec.LIGHT_RANGE
	light.spot_angle = HeadlightSpec.LIGHT_SPOT_ANGLE
	light.spot_angle_attenuation = 1.5
	# Parented to THIS node, not the headlight mesh: the cockpit camera hides
	# the whole hull (cockpit_camera.gd activate()), and a hidden parent
	# switches its child lights off too. Same placement as before - the
	# mesh-local transform re-expressed relative to this node.
	add_child(light)
	light.transform = global_transform.affine_inverse() * mesh_node.global_transform * in_mesh
	_lights.append(light)
	_by_side[side] = {"light": light, "mesh": mesh_node}

## Damage (CarPartDetacher): side "L"/"R"'s lens is gone and its beam turns
## faulty - weak, flickering, sparking (see DAMAGED_ENERGY above) - until
## restore(). Returns false if there's no such light or it's already damaged.
func break_side(side: String) -> bool:
	if not _by_side.has(side) or _damaged.has(side):
		return false
	var mesh := _by_side[side].mesh as MeshInstance3D
	if not is_instance_valid(mesh) or not mesh.visible:
		return false
	mesh.visible = false
	_damaged[side] = {
		"next_spark": randf_range(SPARK_INTERVAL.x, SPARK_INTERVAL.y),
		"dropout": 0.0,
		"phase": randf() * 100.0,
	}
	set_process(true)
	return true

## World centre of side's lens (where the glass burst goes).
func lens_center(side: String) -> Vector3:
	return LightBreak.lens_center(_by_side, side)

func lens_mesh(side: String) -> MeshInstance3D:
	return _by_side[side].mesh if _by_side.has(side) else null

func restore() -> void:
	LightBreak.restore(_by_side)
	_damaged.clear()
	set_process(false)
	_apply_energy()

## Only runs while a lamp is damaged: times the short-outs and re-applies the
## flickering energy.
func _process(delta: float) -> void:
	_time += delta
	var live := GameState.current == GameState.State.PLAYING or GameState.current == GameState.State.CRASHING
	for side in _damaged:
		var d: Dictionary = _damaged[side]
		d.dropout = maxf(d.dropout - delta, 0.0)
		d.next_spark -= delta
		if d.next_spark <= 0.0:
			d.next_spark = randf_range(SPARK_INTERVAL.x, SPARK_INTERVAL.y)
			d.dropout = DROPOUT_TIME
			if live:
				_spawn_sparks(side)
	_apply_energy()

## Share of the normal beam side's lamp gives right now (1 = undamaged).
func _damage_factor(side: String) -> float:
	if not _damaged.has(side):
		return 1.0
	var d: Dictionary = _damaged[side]
	if d.dropout > 0.0:
		return 0.0
	var n: float = 0.5 + 0.5 * _noise.get_noise_2d(_time * FLICKER_RATE, d.phase)
	return DAMAGED_ENERGY * lerpf(FLICKER_MIN, 1.0, clampf(n, 0.0, 1.0))

func _apply_energy() -> void:
	for side in _by_side:
		var light := _by_side[side].light as SpotLight3D
		if is_instance_valid(light):
			light.light_energy = _energy * _damage_factor(side)

## A few sparks out of side's exposed lamp, thrown forward and up.
func _spawn_sparks(side: String) -> void:
	var light := _by_side[side].light as SpotLight3D
	var car := get_parent() as RigidBody3D
	if not is_instance_valid(light) or car == null or car.get_parent() == null:
		return
	var sparks: CPUParticles3D = SPARKS_SCENE.instantiate()
	sparks.amount = randi_range(SPARK_AMOUNT.x, SPARK_AMOUNT.y)
	sparks.lifetime = SPARK_LIFETIME
	sparks.initial_velocity_min = SPARK_SPEED.x
	sparks.initial_velocity_max = SPARK_SPEED.y
	sparks.direction = (car.global_basis.z + Vector3.UP * 0.6).normalized()
	sparks.spread = 50.0
	var velocity := car.linear_velocity
	sparks.set("carry_velocity", velocity * SPARK_CARRY_FRAC) # script var, not a CPUParticles3D property
	car.get_parent().add_child(sparks)
	sparks.global_position = light.global_position + velocity * SPARK_LEAD_TIME

const FLASH_MULT := 3.0 # beam energy multiplier at the peak of a flash

var _flash_tween: Tween

## High-beam flash (horn.gd): two quick bright pulses over `duration`
## seconds, then back to the normal energy. Real time, so slow-mo doesn't
## drag it out. A damaged lamp pulses too, at its own reduced level.
func flash(duration := 0.6) -> void:
	if _flash_tween:
		_flash_tween.kill()
	var base := HeadlightSpec.LIGHT_ENERGY
	var pulse := duration / 4.0
	_flash_tween = create_tween().set_ignore_time_scale(true)
	for i in 2:
		_flash_tween.tween_method(_set_energy, base * FLASH_MULT, base * FLASH_MULT, pulse)
		_flash_tween.tween_method(_set_energy, base, base, pulse)

func _set_energy(e: float) -> void:
	_energy = e
	_apply_energy()
