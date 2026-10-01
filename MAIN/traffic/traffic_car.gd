extends RigidBody3D

## One pooled traffic car - a data holder driven centrally by
## traffic_manager.gd (same centralized-loop architecture as main.js's
## per-frame traffic update, not a per-node _process: the AI needs to query
## every other car each frame for lane-following, which is naturally a
## manager-level concern). The manager owns all the logic; this script just
## carries state and the visual hull.
##
## Real voxel car hulls (Voxel Driver's own asset pack, assets/cars/
## structured/*.glb, copied into res://assets/cars/) - half_len/half_w are
## measured from each model's own AABB rather than hand-authored dims, so
## gap/collision math automatically matches whichever hull is assigned.
##
## Real RigidBody3D + CollisionShape3D (added for player-hit "budging" -
## see the plan's FOLLOWING/KNOCKED section) - but the AI's dist/x_frac/lane
## math below stays the sole source of truth for ordinary driving. In
## FOLLOWING mode, traffic_manager.gd STEERS this body every physics frame
## by setting linear_velocity/angular_velocity toward the AI-desired
## transform (not a teleport - a real velocity, so real collisions still
## work), rather than rewriting the AI to be continuously force-driven.
## Only on a confirmed hit (crash_system.gd's existing numeric proximity
## check - already tuned, reused rather than adding separate physics
## contact-signal plumbing) does control briefly hand off to real physics
## (KNOCKED), then re-sync back from wherever it physically settled.

## WRECKED: ANY hit from the player totals the car (crash_system.gd's
## _hit_traffic_car - KNOCKED is currently unused) - real physics still plays
## out the impact shove (heavily damped so it stops quickly), but unlike KNOCKED, it never recovers/resyncs back into traffic
## flow. It just stops wherever it lands and sits there as a real hazard
## blocking whatever lane it ended up in, hazard lights blinking, until the
## player eventually drives far enough past it to recycle normally (a
## position-based despawn check, since a wrecked car's `dist` is frozen and
## no longer a valid stand-in for where it actually is).
enum ControlMode { FOLLOWING, KNOCKED, WRECKED }
var control_mode: ControlMode = ControlMode.FOLLOWING
var knock_timer: float = 0.0

const KNOCK_DURATION := 1.8 # max time physics keeps control before forcing recovery
const KNOCK_SETTLE_LINEAR := 0.6 # units/s - below this (and angular) counts as "settled early"
const KNOCK_SETTLE_ANGULAR := 0.3
# A wrecked car's damping - high so the hit's shove dies out within about a
# second and it stays put as a hazard.
const WRECK_LINEAR_DAMP := 3.0
const WRECK_ANGULAR_DAMP := 4.0
const NORMAL_LINEAR_DAMP := 0.0 # RigidBody3D default - TrafficCar.tscn doesn't override it
const NORMAL_ANGULAR_DAMP := 0.0

const TRAFFIC_COLLISION_LAYER := 1 << 2 # bit 3 (value 4) - see TrafficCar.tscn
const PLAYER_LAYER := 1 << 1 # bit 2 (value 2) - dedicated player-identity bit, see base car.tscn's collision_layer=3 (1|2)
# NORMAL_MASK intentionally does NOT include the default world layer (1),
# which the road's ground/guardrail StaticBody3D collision uses - while
# FOLLOWING, a traffic car is fully AI-position-driven (velocity-steered
# every physics frame, gravity_scale=0, no suspension model), so it should
# never physically collide with road geometry at all. It used to (mask=1
# matched both the player AND the road, since both defaulted to layer 1),
# and on curved/banked sections the road's per-row ConvexPolygonShape3D has
# small kinks between rows - the physics engine kept nudging the car out of
# penetration against those kinks while the AI simultaneously steered it
# back onto the smooth interpolated path, and that fight showed up as
# violent vibration. Traffic only needs to detect the PLAYER while
# FOLLOWING, via its own dedicated layer bit instead.
const NORMAL_MASK := PLAYER_LAYER
const KNOCKED_MASK := 1 | PLAYER_LAYER | TRAFFIC_COLLISION_LAYER # real physics takes over here - allow colliding with world geometry, the player, and other traffic

# RigidBody3D `mass` here isn't real kg - it's this project's own internal
# scale, the same one `base car.tscn`'s player RigidBody3D uses (mass=90.0,
# per its own prior calibration notes, not a literal 90kg car). Derived
# proportionally from measured footprint (half_len*half_w*4) against that
# same 90 baseline. First bumped ~1.8x (scale 1.95->3.5, min 60->110, max
# 220->400) after "traffic flew off like they weighed nothing on a hit",
# bumped again here (3.5->6.0, 110->180, 400->650) per further user request -
# now noticeably heavier than the player (90) across the board, matching a
# real car-vs-car hit better. crash_system.gd's _hit_traffic_car() computes
# its impulse from the PLAYER's own mass/speed only (not the traffic car's
# mass at all), so a bigger traffic mass directly reduces how much a given
# hit budges it (impulse/mass = smaller velocity change) - and, since
# crash_system.gd now also applies a scaled-down reaction impulse back onto
# the player (PLAYER_REACTION_TRANSFER), the same heavier mass is also why
# that hit doesn't feel like shoving a cardboard box - still tune further by
# feel if needed.
const MASS_FOOTPRINT_SCALE := 6.0
const MASS_MIN := 480.0
const MASS_MAX := 950.0

var dist: float = 0.0
var lane: int = 0
var x_frac: float = 0.0 # normalized lane-center fraction, [-1, 1] of ROAD_HALF_WIDTH
var speed: float = 0.0
var half_len: float = 2.3
var half_w: float = 0.9
var near_best: int = -1 # closest near-miss tier seen this pass (-1 none, else a RiskEvents.NearMissTier), see crash_system.gd
var near_paid: int = -1 # best tier already rewarded for this car
var was_ahead: bool = false # overtake tracking, see crash_system.gd - only cars seen ahead can be overtaken
var overtaken: bool = false
var slipstreamed: bool = false # already gave its slingshot boost, see slipstream_scorer.gd

var turn_dir: int = 0
var pending_lane: int = 0
var changing_lanes: bool = false
var signal_timer: float = 0.0
var change_from_x: float = 0.0
var change_to_x: float = 0.0
var change_progress: float = 0.0
var lane_yaw_offset: float = 0.0

const WHEEL_CORNERS := ["FL", "FR", "BL", "BR"]

var _hull: Node3D
var _wheel_meshes: Array = []
var wheel_radius: float = 0.4 # world-scaled units, computed in setup_visual()

## Rain spray mist per REAR wheel (see update_spray()) - built once in
## setup_visual(), parented alongside (not under) each wheel's spin pivot so
## the emitter itself never spins with the wheel. Reuses smoke.png (no new
## texture asset) via a plain billboard StandardMaterial3D rather than
## wheel_spray.gd's shared particle_billboard.gdshader setup - traffic has no
## wheel.gd/RayCast3D to hang a script off of, and a pool of 35 cars x 4
## wheels makes the simplest possible per-particle setup the right call here.
const SPRAY_TEXTURE := preload("res://MAIN/misc/tyre smoke/smoke.png")
const SPRAY_MIN_SPEED := 8.0 # world units/s below which no spray shows, even in rain
var _wheel_sprays: Array = []

var _headlight_l: MeshInstance3D
var _headlight_r: MeshInstance3D
var _real_headlights: Array = []
var _real_headlights_on := false

var _rearlight_l: MeshInstance3D
var _rearlight_r: MeshInstance3D

func setup_visual(hull_scene: PackedScene, unit_scale: float) -> void:
	if _hull:
		_hull.queue_free()
	_hull = hull_scene.instantiate()
	add_child(_hull)

	# Measure in the hull's own untransformed local space first (composing
	# each descendant's transform down from the hull root - a flat "just
	# read child.transform" walk silently drops any transform on an
	# intermediate group node and produced wildly wrong sizes here before).
	# Must happen before _hull.scale/rotation/position are set below, since
	# these measurements assume the hull is still in its freshly-instantiated
	# (pre-modification) state - same reason the wheel measurement below
	# also has to happen before that point, not after.
	var aabb := _combined_aabb(_hull, Transform3D.IDENTITY)
	half_len = aabb.size.z * unit_scale / 2.0
	half_w = aabb.size.x * unit_scale / 2.0
	var height: float = maxf(aabb.size.y * unit_scale, 1.0)
	_setup_collision(height)

	# Unlike the player car's wheel_hull_mesh.gd (which rides on an existing
	# suspension pivot wheel.gd already rotates), traffic has no such
	# ancestor - each wheel needs its OWN rotating pivot created here, since
	# spin_wheels() below rotates these directly every frame.
	var found_wheels: Array = []
	var found_wheel_corners: Array = []
	for corner in WHEEL_CORNERS:
		var w := StructuredCarParts.find_part(_hull, StructuredCarParts.wheel_patterns(corner)) as MeshInstance3D
		if w and w.mesh:
			found_wheels.append(w)
			found_wheel_corners.append(corner)
	if not found_wheels.is_empty():
		var sample: MeshInstance3D = found_wheels[0]
		# Composes the FULL chain from _hull down to the wheel node (not
		# just the wheel node's own local transform) - a nested group
		# between _hull and the wheel mesh can carry a corrective scale
		# (this pack's models do), and skipping it produced a ~115-unit
		# "radius" here before this fix, the same bug class as above.
		var wheel_local_size: Vector3 = _full_chain_aabb(_hull, sample).size
		# Wheel discs sit in the local Y-Z plane (axle along local X) -
		# radius is half the larger of those two extents.
		wheel_radius = maxf(wheel_local_size.y, wheel_local_size.z) / 2.0 * unit_scale

	# Measured (not guessed/hardcoded) per wheel: most of this pack's wheel
	# meshes are NOT centered on their own node origin (coupe.glb's happens
	# to be; passenger/taxi/truck/armored/police's are offset by ~70-140
	# units in their own local space) - spinning the raw node as-is would
	# swing the mesh through a wide arc around that offset origin instead of
	# rotating it in place. _make_centered_pivot reparents each wheel mesh
	# under a new pivot placed exactly at its own measured geometric center,
	# so this self-corrects for any hull automatically.
	_wheel_meshes.clear()
	_wheel_sprays.clear()
	for i in found_wheels.size():
		var pivot := _make_centered_pivot(found_wheels[i])
		_wheel_meshes.append(pivot)
		# Rear wheels only - front spray is hidden behind the rear's anyway,
		# so it's half the emitters/overdraw for no visible loss.
		if found_wheel_corners[i].begins_with("B"):
			_wheel_sprays.append(_make_wheel_spray(pivot))

	_hull.scale = Vector3.ONE * unit_scale
	# glTF assets in this pack are authored front = -Z; this project's actual
	# driving-forward is +Z (see cockpit_camera.gd's FORWARD_YAW_OFFSET note),
	# so every hull needs the same 180 flip to face the direction of travel.
	_hull.rotation.y = PI
	# Sit the model on the ground: shift up/down by however far its own
	# lowest point is from its local origin.
	_hull.position.y = -aabb.position.y * unit_scale

	# Headlights for every traffic hull - a real SpotLight3D on ALL 35 cars
	# at once (70 lights) turned out too expensive for this project's
	# gl_compatibility renderer specifically (a per-MESH real-time-light cap,
	# `rendering/limits/opengl/max_lights_per_object` - see road_generator.gd's
	# streetlight notes for the full story). Every traffic car still gets
	# the cheap always-on emissive glow below (zero light-budget cost, just
	# looks lit); `traffic_manager.gd` separately promotes only the nearest
	# few cars to a real light via `set_real_headlights_enabled()`, so
	# there's real illumination on the road and on the car ahead without
	# ever having more than a handful of real traffic lights active at once.
	_headlight_l = StructuredCarParts.find_part(_hull, ["headlight_l"]) as MeshInstance3D
	_headlight_r = StructuredCarParts.find_part(_hull, ["headlight_r"]) as MeshInstance3D
	_make_headlight_glow(_headlight_l)
	_make_headlight_glow(_headlight_r)
	_make_headlight_cone(_headlight_l)
	_make_headlight_cone(_headlight_r)

	# Brake/tail lights, same cheap glow-only treatment as headlights (no
	# real Light3D, just an emissive material) - traffic doesn't track
	# per-car braking state closely enough yet to react, so this is a
	# constant dim taillight glow, matching how a real car's tail lights
	# always show some red even off the brake. Cached (not just built) so
	# update_turn_signal() below can flip their color between this dim red
	# and amber without re-searching the hull every time.
	_rearlight_l = StructuredCarParts.find_part(_hull, ["rearlight_l"]) as MeshInstance3D
	_rearlight_r = StructuredCarParts.find_part(_hull, ["rearlight_r"]) as MeshInstance3D
	_make_glow(_rearlight_l, StructuredCarParts.REARLIGHT_COLOR, 3.0)
	_make_glow(_rearlight_r, StructuredCarParts.REARLIGHT_COLOR, 3.0)

## Real collision shape + mass, sized from the SAME measured half_len/half_w
## the gap-following math already uses (not re-derived) - a truck's hull
## naturally gets a bigger, heavier collider than a sedan's for free.
func _setup_collision(height: float) -> void:
	for c in get_children():
		if c is CollisionShape3D:
			c.queue_free()
	var box := BoxShape3D.new()
	box.size = Vector3(half_w * 2.0, height, half_len * 2.0)
	var shape := CollisionShape3D.new()
	shape.shape = box
	shape.position = Vector3(0, height / 2.0, 0)
	add_child(shape)
	mass = clampf(half_len * half_w * 4.0 * MASS_FOOTPRINT_SCALE, MASS_MIN, MASS_MAX)
	collision_layer = TRAFFIC_COLLISION_LAYER
	collision_mask = NORMAL_MASK

## Called by crash_system.gd's existing numeric hit-detection (already
## correct/tuned, reused as the trigger rather than adding separate physics
## contact-signal plumbing) when a real collision with the player fires -
## hands control to real physics for a bounded window instead of continuing
## to be steered by the AI. `impulse` is a world-space linear impulse
## (already scaled for this car's mass by the caller); `spin` is a yaw
## angular impulse.
func enter_knocked_state(impulse: Vector3, spin: float) -> void:
	control_mode = ControlMode.KNOCKED
	knock_timer = 0.0
	collision_mask = KNOCKED_MASK
	# Re-lock pitch/roll - FOLLOWING briefly unlocks these (see
	# resume_following()) so the car can deliberately roll to match the
	# road's bank; a real hit should still look like real physics without
	# tumbling wildly, so lock back to yaw-only for the knock itself.
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	# gravity_scale is 0 (TrafficCar.tscn) while FOLLOWING - AI-position-
	# driven cars have no business falling. Real physics needs real gravity
	# though, or nothing ever pulls a hit car back down: any upward component
	# in `impulse` (or just the impact shoving it, unopposed, along whatever
	# heading it left the ground at) just carries it away in a straight line
	# forever instead of arcing back down and settling - this, not mass
	# alone, is why heavier traffic still looked like it "flew off."
	gravity_scale = 1.0
	apply_central_impulse(impulse)
	apply_torque_impulse(Vector3(0, spin, 0))

## Called every physics frame while KNOCKED (traffic_manager.gd) - returns
## true once this car should resume AI control, either because the knock
## window elapsed or because it settled (both linear and angular velocity
## below a small threshold) sooner than that. Doesn't touch dist/x_frac/
## lane itself - traffic_manager.gd does that resync on a true return, from
## wherever this car's real physics position/rotation ended up.
func update_knock(delta: float) -> bool:
	knock_timer += delta
	if knock_timer >= KNOCK_DURATION:
		return true
	return linear_velocity.length() < KNOCK_SETTLE_LINEAR and absf(angular_velocity.y) < KNOCK_SETTLE_ANGULAR

func resume_following() -> void:
	control_mode = ControlMode.FOLLOWING
	collision_mask = NORMAL_MASK
	linear_damp = NORMAL_LINEAR_DAMP # undo enter_wrecked_state's damping when the car is recycled
	angular_damp = NORMAL_ANGULAR_DAMP
	gravity_scale = 0.0 # back to AI-position-driven, see enter_knocked_state's note
	# Unlocked only while FOLLOWING, and only so traffic_manager.gd's
	# _drive_following can apply a deliberate, controlled roll matching the
	# road's own bank (real elevation/curve data, not arbitrary tumbling) -
	# re-locked the instant a real hit happens (enter_knocked_state/
	# enter_wrecked_state) so a collision can't send it spinning wildly.
	axis_lock_angular_x = false
	axis_lock_angular_z = false

## A BIG hit (crash_system.gd's own speed threshold) - real physics still
## plays out the impact impulse, but this car never recovers back to AI
## control afterward (unlike enter_knocked_state above); traffic_manager.gd
## just leaves it alone once wrecked, blinking hazard lights, until it's
## far enough behind the player to recycle.
func enter_wrecked_state(impulse: Vector3, spin: float) -> void:
	control_mode = ControlMode.WRECKED
	collision_mask = KNOCKED_MASK
	gravity_scale = 1.0 # see enter_knocked_state's note - a wrecked car needs to fall back down and stay put, not float away
	axis_lock_angular_x = true
	axis_lock_angular_z = true
	# Stop driving: drop its own traffic speed entirely, so it only moves as
	# far as the hit shoves it - and heavy damping brings that shove to rest
	# quickly instead of letting it slide/coast down the road.
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	linear_damp = WRECK_LINEAR_DAMP
	angular_damp = WRECK_ANGULAR_DAMP
	apply_central_impulse(impulse)
	apply_torque_impulse(Vector3(0, spin, 0))

## Both rear lights blinking amber together - real hazard lights, called
## every frame by traffic_manager.gd while this car is WRECKED.
func set_hazard_lights(blink_on: bool) -> void:
	_set_rear_light(_rearlight_l, blink_on)
	_set_rear_light(_rearlight_r, blink_on)

func _make_headlight_glow(mesh_node: Node3D) -> void:
	_make_glow(mesh_node, StructuredCarParts.HEADLIGHT_COLOR, 4.0)

## Cheap, always-on fake headlight cone for EVERY traffic car (unlike the
## real SpotLight3D LOD tier, which only promotes the nearest few) - see
## HeadlightSpec.build_forward_cone()'s own note on why zero extra rotation
## is needed here (same "-Z is forward once the hull's 180 flip is
## inherited" convention set_real_headlights_enabled() already relies on).
func _make_headlight_cone(mesh_node: Node3D) -> void:
	if mesh_node == null or not (mesh_node is MeshInstance3D) or (mesh_node as MeshInstance3D).mesh == null:
		return
	var cone := HeadlightSpec.build_forward_cone(StructuredCarParts.HEADLIGHT_COLOR)
	var local_aabb: AABB = (mesh_node as MeshInstance3D).mesh.get_aabb()
	cone.position = local_aabb.position + local_aabb.size / 2.0
	mesh_node.add_child(cone)

func _make_glow(mesh_node: Node3D, color: Color, energy: float) -> void:
	if mesh_node == null or not (mesh_node is MeshInstance3D) or (mesh_node as MeshInstance3D).mesh == null:
		return
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = energy
	mat.albedo_color = color
	(mesh_node as MeshInstance3D).material_override = mat

const TURN_SIGNAL_COLOR := Color(1.0, 0.6, 0.0)
const TURN_SIGNAL_ENERGY := 6.0
const REARLIGHT_DIM_ENERGY := 3.0

## Called by traffic_manager.gd's per-frame update with the car's own
## `turn_dir` (already tracked for the lane-change AI) and a shared blink
## phase - blinks the correct side amber while signaling/changing lanes,
## reverts to the normal dim red otherwise.
## Sign convention verified empirically (user reported the original guess
## backwards - signaled left while actually turning right): turn_dir > 0
## blinks the LEFT light, turn_dir < 0 blinks the RIGHT.
func update_turn_signal(turn_dir: int, blink_on: bool) -> void:
	_set_rear_light(_rearlight_l, turn_dir > 0 and blink_on)
	_set_rear_light(_rearlight_r, turn_dir < 0 and blink_on)

func _set_rear_light(mesh_node: MeshInstance3D, signaling: bool) -> void:
	if mesh_node == null or mesh_node.material_override == null:
		return
	var mat := mesh_node.material_override as StandardMaterial3D
	var color: Color = TURN_SIGNAL_COLOR if signaling else StructuredCarParts.REARLIGHT_COLOR
	# Called every tick for every car - only touch the material when the
	# light actually flips (each write re-uploads the material).
	if mat.emission == color:
		return
	mat.emission = color
	mat.emission_energy_multiplier = TURN_SIGNAL_ENERGY if signaling else REARLIGHT_DIM_ENERGY

## Called by traffic_manager.gd's distance-based LOD pass - lazily builds
## two real (but cheap: short range, no shadow) SpotLight3Ds on first
## enable, then just toggles `.visible` afterward so repeated on/off
## doesn't churn nodes every time a car crosses the LOD radius.
##
## Unlike the player (headlight_lights.gd), this needs NO extra yaw
## correction on the light itself - traffic's hull already gets flipped
## 180 in setup_visual() above (`_hull.rotation.y = PI`), and that flip is
## inherited automatically through the transform chain down to whatever
## sits on `_headlight_l`/`_headlight_r`, which themselves carry no
## rotation of their own (same asset, same identity-transform mesh nodes
## verified for the player's headlight fix).
func set_real_headlights_enabled(enabled: bool) -> void:
	if enabled == _real_headlights_on:
		return
	_real_headlights_on = enabled
	if enabled and _real_headlights.is_empty():
		_real_headlights.append(_build_real_headlight(_headlight_l))
		_real_headlights.append(_build_real_headlight(_headlight_r))
		return
	for l in _real_headlights:
		if is_instance_valid(l):
			l.visible = enabled

func _build_real_headlight(mesh_node: MeshInstance3D) -> SpotLight3D:
	if mesh_node == null or mesh_node.mesh == null:
		return null
	var light := SpotLight3D.new()
	light.rotation = Vector3(deg_to_rad(HeadlightSpec.TRAFFIC_DOWNWARD_TILT_DEG), 0, 0)
	light.light_color = StructuredCarParts.HEADLIGHT_COLOR
	light.light_energy = HeadlightSpec.TRAFFIC_LIGHT_ENERGY
	light.spot_range = HeadlightSpec.TRAFFIC_LIGHT_RANGE
	light.spot_angle = HeadlightSpec.TRAFFIC_LIGHT_SPOT_ANGLE
	light.spot_angle_attenuation = 1.5
	mesh_node.add_child(light)
	var local_aabb: AABB = mesh_node.mesh.get_aabb()
	light.position = local_aabb.position + local_aabb.size / 2.0
	return light

## Reparents `w` under a new pivot Node3D placed exactly at w's own measured
## geometric center (from its mesh AABB, in w's own local space), with w's
## own local transform adjusted to exactly cancel that offset - net visual
## position/orientation is unchanged, but rotating the returned pivot now
## spins the mesh around its true center instead of around w's original
## (possibly far-off) local origin.
func _make_centered_pivot(w: MeshInstance3D) -> Node3D:
	var local_aabb: AABB = w.mesh.get_aabb()
	var center: Vector3 = local_aabb.position + local_aabb.size / 2.0
	var pivot := Node3D.new()
	pivot.name = w.name + "_pivot"
	var old_parent := w.get_parent()
	pivot.transform = w.transform * Transform3D(Basis(), center)
	old_parent.add_child(pivot)
	old_parent.remove_child(w)
	w.owner = null
	pivot.add_child(w)
	w.transform = Transform3D(Basis(), -center)
	return pivot

func spin_wheels(delta: float, forward_speed: float) -> void:
	if _wheel_meshes.is_empty() or wheel_radius <= 0.0:
		return
	var angular_speed: float = forward_speed / wheel_radius
	for w in _wheel_meshes:
		w.rotate_x(angular_speed * delta)

## Anchored as a SIBLING of the wheel's spin pivot (same parent, same
## position) rather than a child of it - a child would spin with the wheel
## and swing its emission direction around every frame, which reads as
## chaotic sparkle rather than a trailing spray. The anchor still moves and
## turns with the hull overall (it's not top-level), just not with the
## wheel's own rotation.
func _make_wheel_spray(pivot: Node3D) -> CPUParticles3D:
	var anchor := Node3D.new()
	anchor.transform = pivot.transform
	pivot.get_parent().add_child(anchor)

	var p := CPUParticles3D.new()
	p.emitting = false
	# Kept low on purpose: a pool of 35 cars x 2 rear wheels is up to 70
	# emitters, and every particle is an alpha-blended quad (overdraw cost).
	p.amount = 12
	# Short-lived on purpose (user feedback: with no fade-out and a long
	# lifetime, these read as tiny cotton balls trailing the car instead of
	# a quick spray puff) - a fast color_ramp fade PLUS a short lifetime
	# together, not just one or the other, since a long-lived particle that
	# merely turns transparent still lingers/drifts oddly for that whole time.
	p.lifetime = 0.35
	p.mesh = _spray_mesh()
	p.material_override = _spray_material()
	p.color_ramp = _spray_fade()
	p.scale_amount_curve = _spray_grow()
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.direction = Vector3(0, 0, 1) # hull's local -Z is forward (see the 180 flip above), so +Z trails behind
	p.spread = 14.0
	p.gravity = Vector3(0, -6.0 * RoadMetrics.UNIT_SCALE, 0) # a little downward pull so it visibly dissipates, not just hovers
	p.damping_min = 2.0
	p.damping_max = 3.0
	p.scale_amount_min = 0.4
	p.scale_amount_max = 1.0
	anchor.add_child(p)
	return p

## Spray resources shared by every traffic car's emitters (built once,
## lazily) instead of a fresh mesh/material/gradient/curve per wheel.
static var _spray_mesh_res: QuadMesh
static var _spray_mat_res: StandardMaterial3D
static var _spray_fade_res: Gradient
static var _spray_grow_res: Curve

static func _spray_mesh() -> QuadMesh:
	if _spray_mesh_res == null:
		_spray_mesh_res = QuadMesh.new()
		# Bug: this was a flat `0.3` with no UNIT_SCALE applied, so at this
		# project's ~3.27 units/metre scale the quad was really only ~9cm
		# across - read as "tiny golf balls" rather than a spray puff.
		_spray_mesh_res.size = Vector2(0.5, 0.5) * RoadMetrics.UNIT_SCALE
	return _spray_mesh_res

static func _spray_material() -> StandardMaterial3D:
	if _spray_mat_res == null:
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		# PARTICLES billboard + keep_scale so scale_amount_curve applies, and
		# vertex color so the color_ramp fade actually reaches the pixels.
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
		mat.billboard_keep_scale = true
		mat.vertex_color_use_as_albedo = true
		mat.albedo_texture = SPRAY_TEXTURE
		mat.albedo_color = Color(0.8, 0.84, 0.9, 1.0)
		_spray_mat_res = mat
	return _spray_mat_res

static func _spray_fade() -> Gradient:
	if _spray_fade_res == null:
		_spray_fade_res = Gradient.new()
		_spray_fade_res.offsets = PackedFloat32Array([0.0, 0.2, 1.0])
		_spray_fade_res.colors = PackedColorArray([Color(1, 1, 1, 0.35), Color(1, 1, 1, 0.22), Color(1, 1, 1, 0.0)])
	return _spray_fade_res

static func _spray_grow() -> Curve:
	if _spray_grow_res == null:
		# Each puff grows a little as it fades (matches the player's spray).
		_spray_grow_res = Curve.new()
		_spray_grow_res.add_point(Vector2(0.0, 0.4))
		_spray_grow_res.add_point(Vector2(1.0, 1.2))
	return _spray_grow_res

## Called every physics frame by traffic_manager.gd's _update_car alongside
## spin_wheels() - purely visual, mirrors wheel_spray.gd's speed-gated (not
## slip-gated) trigger for the player, just with a single intensity level
## instead of 3. `is_raining` already folds in traffic_manager's distance LOD.
func update_spray(is_raining: bool, forward_speed: float) -> void:
	if _wheel_sprays.is_empty():
		return
	var active: bool = is_raining and VitaVehicleSimulation.misc_smoke 			and forward_speed > SPRAY_MIN_SPEED and control_mode == ControlMode.FOLLOWING
	var vel: float = forward_speed * 0.6
	for p in _wheel_sprays:
		if not is_instance_valid(p):
			continue
		if p.emitting != active:
			p.emitting = active
		if active:
			p.initial_velocity_min = vel
			p.initial_velocity_max = vel

## Composes the transform chain from `root` down to `target` (inclusive of
## both ends), then applies it to target's own mesh AABB - unlike
## _combined_aabb below (which walks DOWN from a node merging everything
## under it), this walks UP from an arbitrary descendant to get just that
## one node's true size, without dropping any intermediate ancestor's
## transform along the way.
func _full_chain_aabb(root: Node3D, target: MeshInstance3D) -> AABB:
	var chain: Array = []
	var n: Node3D = target
	while true:
		chain.push_front(n)
		if n == root:
			break
		n = n.get_parent()
	var xform := Transform3D.IDENTITY
	for node in chain:
		xform = xform * node.transform
	return xform * target.mesh.get_aabb()

func _combined_aabb(node: Node3D, parent_xform: Transform3D) -> AABB:
	var xform := parent_xform * node.transform
	var result := AABB()
	var has_any := false
	if node is MeshInstance3D and node.mesh:
		result = xform * node.mesh.get_aabb()
		has_any = true
	for child in node.get_children():
		if child is Node3D:
			var child_aabb := _combined_aabb(child, xform)
			if not has_any:
				result = child_aabb
				has_any = true
			elif child_aabb.size != Vector3.ZERO:
				result = result.merge(child_aabb)
	return result
