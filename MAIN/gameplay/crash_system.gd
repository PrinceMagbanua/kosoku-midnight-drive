extends Node3D
class_name CrashSystem

## Port of hud-crash.js's HP/damage model + triggerCrash()/recoverFromCrash()
## state machine, adapted to a real-physics RigidBody3D car instead of
## Voxel Driver's scripted game-speed model. Collision/near-miss DETECTION
## still isn't physics-engine collision - it's the same pure numeric
## proximity check the original uses each frame (lateral gap vs. hitW/
## nearW, longitudinal window vs. hitL/nearL), reused as-is since it's
## already correct/tuned. Traffic cars DO now have real collision shapes
## (see traffic_car.gd's FOLLOWING/KNOCKED state machine) so a confirmed
## hit here hands the traffic car off to real physics
## (_hit_traffic_car()) - the numeric check decides WHETHER a hit happened,
## physics decides how the car actually reacts to it. A modest hit budges
## the car (KNOCKED, temporary, recovers); a big one totals it (WRECKED,
## permanent, becomes a hazard, triggers a screen flash + sparks).
##
## Adaptations from the original, and why:
## - No fixed "maxSpeed" exists on a real-physics car (g-rcp2's car.gd has no
##   such export) - REFERENCE_MAX_SPEED below is an authored reference value
##   used only to normalize damage/near-miss "how fast were you going"
##   percentages, not an actual speed cap.
## - The original's crash spin is a scripted rotation.y tween (not physical,
##   since Voxel Driver's car isn't a real rigid body). Forcibly scripting
##   rotation.y here would fight car.gd's own continuous physics processing
##   every frame. Instead: a one-time torque impulse on CRASHING entry gives
##   a natural physics-based spin-out, then CRASH_SLOWMO_DURATION just lets
##   real physics play out before transitioning to CRASHED.
## - Player input isn't force-disabled during the crash spin (the original
##   fully locks it out) - a minor fidelity gap, not worth hacking around
##   car.gd's input reading for a ~1.7s window. Noted, not silently dropped.
##
## Damage goes through CarDamageModel: body panels are armor zones (front,
## sides, rear) and `hp` is the chassis behind them - see that script. Hits
## are discrete (one per new contact per traffic car) and sized by CLOSING
## speed along the contact normal, not the player's own speed, so a
## same-speed sideswipe is a light scrape.
##
## NOT ported yet (see RunRewards for the matching scoring-side notes):
## pileup escalation,
## dodge-on-lane-change-merge scoring, screen shake (flash now exists, see
## _play_big_crash_effects()).

const UNIT_SCALE := RoadMetrics.UNIT_SCALE

const REFERENCE_MAX_SPEED := 50.0 * UNIT_SCALE # ~180 km/h - see note above

const PLAYER_HALF_W := 2.75 # measured from this project's own car geometry (wheel track/2 + body overhang)
const PLAYER_HALF_L := 4.2 # measured from wheelbase (front/rear wheel Z +-3.8) + overhang

# Near-miss tiers by the real gap between the two cars' bodywork (closest
# distance between their footprints, any direction - see _check_near_miss).
const NEAR_MARGIN := 0.9 * UNIT_SCALE # gap under this = NEAR MISS
const HAIRLINE_MARGIN := 0.4 * UNIT_SCALE # gap under this = HAIRLINE
const IMPOSSIBLE_MARGIN := 0.15 * UNIT_SCALE # gap under this = IMPOSSIBLE
const DEDUP_RESET_DZ := -3.0 * UNIT_SCALE

## Crash sequence timing, all in REAL (wall-clock) seconds: the slow-mo
## plays alone for CRASH_POPUP_DELAY, then crash_overlay.gd fades the
## CRASHED popup in over CRASH_POPUP_FADE (stats counting up as it does).
## Slow-mo only ends - and the state only flips to CRASHED - once the popup
## is fully opaque. speed_blur.gd fades the world to black-and-white over
## the whole CRASH_SLOWMO_DURATION window.
const CRASH_POPUP_DELAY := 1.2
const CRASH_POPUP_FADE := 2.5
const CRASH_SLOWMO_DURATION := CRASH_POPUP_DELAY + CRASH_POPUP_FADE
const CRASH_SPIN_IMPULSE := 1400.0 # tuned by feel, not ported from a source value

## Nothing previously detected "fell through/off the road" at all - the car
## just kept falling forever until the player manually paused and ended the
## run themselves, and even then could resume the very same fall (see
## run_reset.gd's freeze note). Comfortably below any real driving surface
## (spawn sits around y=2), so this only fires once the car is unambiguously
## off the map, not on a big jump or a rough patch of road.
## Measured from the road's own height at the car's spot on the path, not
## from world y=0 - the road has elevation, and a long downhill used to take
## the car below a fixed y=-40 while it was still driving on the road.
const FALL_BELOW_ROAD := 40.0

## Upside down: the car's local up pointing below this (dot with world up)
## counts as flipped - roughly past 100 deg of roll/pitch, so a hard lean or
## a two-wheel moment doesn't count, only an actual rollover. Per user
## request, flipping is a crash straight away - UPSIDE_DOWN_GRACE is only a
## few physics ticks, enough to ignore a one-frame physics glitch.
const UPSIDE_DOWN_DOT := -0.2
const UPSIDE_DOWN_GRACE := 0.1
## On its side: tipped past ~70 deg but not over (a car resting on its door
## never reached UPSIDE_DOWN_DOT, so it used to just sit there). Longer
## grace than a full flip, so a two-wheel moment that drops back isn't a crash.
const ON_SIDE_DOT := 0.35
const ON_SIDE_GRACE := 1.0

@export var car_path: NodePath = NodePath("../car")
@export var traffic_manager_path: NodePath = NodePath("../TrafficManager")
@export var impact_flash_path: NodePath = NodePath("../ImpactFlash")
@export var road_generator_path: NodePath = NodePath("../RoadGenerator")

# "Plenty" of starting health per user request - was 100 (hud-crash.js's own
# base value), bumped to 300 so a normal run survives several real hits
# comfortably instead of a single hard one being close to fatal. Now that
# traffic has real collision physics, hits land more reliably/often than
# the old penetration-based detection ever did, so a much larger buffer
# matters more than it used to.
const BASE_MAX_HP := 300.0

## Armor pieces + chassis. `hp`/`max_hp` are the chassis (what the HUD bar
## shows); the "armor" upgrade now toughens the pieces instead of adding HP.
var damage := CarDamageModel.new()
var parts: CarPartDetacher
var _shake: CameraShake
var _engine_fx: EngineDamageFx
var hp: float:
	get:
		return damage.chassis_hp
	set(value):
		damage.chassis_hp = value
var max_hp: float:
	get:
		return damage.chassis_max
	set(value):
		damage.chassis_max = value
var invuln_timer: float = 0.0
# Cached targets of car_path / traffic_manager_path / road_generator_path.
var _car_node: RigidBody3D
var _traffic_node: Node
var _road_node: Node

## A traffic car still touching the player after its hit isn't hit again -
## a new hit needs a new contact, at least TRAFFIC_HIT_COOLDOWN after the
## last one from that car (contacts flicker for a tick or two on a bounce).
const TRAFFIC_HIT_COOLDOWN := 0.5
var _traffic_touching := {} # instance id -> true, cars in contact last tick
var _traffic_hit_cooldowns := {} # instance id -> seconds left
var _traffic_scrape_spark_timer := 0.0

var _crash_timer: float = 0.0

## What ended the last run, shown on the crash screen (crash_overlay.gd).
## `last_crash_cause` is the headline (CAUSE_* below), `last_crash_reason` the
## line under it saying what did it ("Hit by another vehicle" - empty when the
## headline says it all), `last_crash_detail` the debug line (collider node,
## shape, speed, contact normal - console only). All empty when the run was
## ended from the pause menu instead.
const CAUSE_TOTALED := "CAR TOTALED"
const CAUSE_FLIPPED := "CAR FLIPPED"
const CAUSE_ROLLED := "CAR ROLLED OVER"
const CAUSE_FELL := "FELL OFF THE ROAD"
static var last_crash_cause := ""
static var last_crash_reason := ""
static var last_crash_detail := ""
var _upside_down_timer: float = 0.0

# SFX - overtake plays on the same signal as the near-miss score bonus (a
# close pass IS an overtake in this game, every traffic car moves the same
# direction the player does); "scrape" is any hit that budges/wrecks a
# traffic car but doesn't end the player's own run; "crash" is reserved for
# _trigger_crash() specifically (the player's own HP hitting 0). Two scrape
# clips, picked at random per hit, so repeated scrapes don't sound identical.
const SFX_OVERTAKE := preload("res://MAIN/sfx/overtake.ogg")
const OVERTAKE_VOLUME := 0.6 # linear, fraction of the normal SFX volume
const SFX_SCRAPE := [
	preload("res://MAIN/sfx/freesound_community-car-hit.mp3"),
	preload("res://MAIN/sfx/floraphonic-metal-hit.mp3"),
]
const SFX_CRASH := preload("res://MAIN/sfx/freesound_gamestudio-car-hit.mp3")

var _overtake_player: AudioStreamPlayer
var _scrape_player: AudioStreamPlayer
var _crash_player: AudioStreamPlayer
var _barrier_slide_player: AudioStreamPlayer

## Barrier (guardrail wall) contact. Damage is driven by the player's velocity
## INTO the wall (the component along the wall's normal), taken from the
## previous tick - by the time a contact is reported the solver has already
## cancelled that component, so the current velocity would always read ~0.
## - Hitting the wall with more than BARRIER_HIT_MIN_SPEED of that into-wall
##   speed is a real hit: a CarDamageModel hit on the zone that touched
##   (times BARRIER_HIT_DAMAGE_SCALE), a hit sound, sparks + debris.
## - Anything gentler, or staying in contact afterwards, is a slide/glance:
##   CarDamageModel scrape damage (wears that side's door, then the chassis,
##   scaled by speed along the wall), small spark/debris bursts on a timer,
##   and the crash sound at BARRIER_SLIDE_VOLUME (10%).
const BARRIER_HIT_MIN_SPEED := 5.0 * UNIT_SCALE
const BARRIER_HIT_DAMAGE_SCALE := 1.0
const BARRIER_HIT_COOLDOWN := 0.4 # seconds before another wall contact can count as a new hit
const BARRIER_SLIDE_MIN_SPEED := 3.0 * UNIT_SCALE # slower than this along the wall = no sparks/sound
const BARRIER_SLIDE_VOLUME := 0.1 # linear, fraction of the normal SFX volume
const BARRIER_SLIDE_SPARK_INTERVAL := 0.07
const BARRIER_SLIDE_DEBRIS_INTERVAL := 0.3
const BARRIER_NORMAL_MAX_Y := 0.5 # contact normals steeper than this are the ground, not the wall
## Speed scrubbed off by the wall (the physics solver only stops the into-wall
## component, so without this a car could scrape the wall at full speed).
## A hit loses between BARRIER_HIT_SPEED_LOSS_MIN and _MAX of its along-wall
## speed, scaled by how hard it went in; sliding loses BARRIER_SLIDE_DRAG of
## it per second while in contact. Applies even while invulnerable.
const BARRIER_HIT_SPEED_LOSS_MIN := 0.1
const BARRIER_HIT_SPEED_LOSS_MAX := 0.4
const BARRIER_SLIDE_DRAG := 0.6

var _prev_velocity := Vector3.ZERO
var in_barrier_contact := false # public - DriftScorer skips its wall bonus while touching
## Closest near-miss tier (RiskEvents.NearMissTier) of any traffic car inside
## NEAR_MARGIN this tick, -1 = none. Read by DriftScorer's proximity bonus.
var closest_traffic_tier := -1
var _barrier_hit_cooldown := 0.0
var _barrier_spark_timer := 0.0
var _barrier_debris_timer := 0.0

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	_overtake_player = AudioStreamPlayer.new()
	add_child(_overtake_player)
	_scrape_player = AudioStreamPlayer.new()
	add_child(_scrape_player)
	_crash_player = AudioStreamPlayer.new()
	_crash_player.stream = SFX_CRASH
	add_child(_crash_player)
	_barrier_slide_player = AudioStreamPlayer.new()
	_barrier_slide_player.stream = SFX_CRASH
	add_child(_barrier_slide_player)
	parts = CarPartDetacher.new()
	parts.name = "PartDetacher"
	add_child(parts)
	_shake = CameraShake.new()
	_shake.name = "CameraShake"
	add_child(_shake)
	_engine_fx = EngineDamageFx.new()
	_engine_fx.name = "EngineDamageFx"
	damage.piece_lost.connect(parts.lose)
	damage.restored.connect(parts.restore_all)

## HUD jolt 0..1 from the camera shake (impacts + intro rev rumble).
func get_hud_shake() -> float:
	return _shake.get_hud_shake() if _shake else 0.0

func _sfx_volume_db() -> float:
	return linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume, 0.0001, 1.0))

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state == GameState.State.PLAYING and old_state != GameState.State.PAUSED:
		# Armor upgrade toughens the armor pieces (its HP per panel, from the
		# upgrade table);
		# the chassis is always BASE_MAX_HP. The hull is re-scanned every run -
		# the Customize screen can rebuild it between runs.
		var car := get_node_or_null(car_path) as RigidBody3D
		var four_doors := parts.bind(car)
		if car:
			# Lives on the car so it moves with it; added on the first run
			# (not in _ready - the car may still be setting up then).
			if _engine_fx.get_parent() == null:
				car.add_child(_engine_fx)
			_engine_fx.bind(car, damage)
		damage.setup(BASE_MAX_HP, SaveData.get_upgrade_value("armor"), four_doors)
		_traffic_touching.clear()
		_traffic_hit_cooldowns.clear()
		invuln_timer = 0.0
		_upside_down_timer = 0.0
		_prev_velocity = Vector3.ZERO
		in_barrier_contact = false
		_barrier_hit_cooldown = 0.0
		last_crash_cause = ""
		last_crash_reason = ""
		last_crash_detail = ""
	elif new_state == GameState.State.MENU or new_state == GameState.State.GARAGE:
		parts.restore_all() # don't show a wrecked car in the menus
		parts.clear_flying()
	# Restore normal time scale whenever we LEAVE the crash spin, regardless
	# of which specific transition does it (currently only the timer-driven
	# CRASHING->CRASHED below, but this is robust against any future path
	# away from CRASHING too) - see _trigger_crash()'s own note on why the
	# spin runs in slow motion.
	if old_state == GameState.State.CRASHING:
		Engine.time_scale = 1.0
		AudioServer.playback_speed_scale = 1.0

func _physics_process(delta: float) -> void:
	if GameState.current == GameState.State.CRASHING:
		# Every frame, not once on entry - see CarInputLock.suppress_input()'s
		# own note on why (a real "car gets launched" bug came from trying to
		# disable car.gd's script instead, which froze wheel.gd's inputs from
		# it mid-throttle/steer rather than letting them decay to neutral).
		CarInputLock.suppress_input()
		# `delta` is scaled by the slow-mo; count real time instead so the
		# popup delay is independent of CRASH_TIME_SCALE.
		_crash_timer += delta / maxf(Engine.time_scale, 0.001)
		if _crash_timer >= CRASH_SLOWMO_DURATION:
			GameState.set_state(GameState.State.CRASHED)
		return

	if GameState.current != GameState.State.PLAYING:
		return
	if invuln_timer > 0.0:
		invuln_timer -= delta
	if DevConsole.invincible:
		hp = max_hp

	# These three are fetched once and again only if they go away, not every tick.
	if not is_instance_valid(_car_node):
		_car_node = get_node_or_null(car_path) as RigidBody3D
	if not is_instance_valid(_traffic_node):
		_traffic_node = get_node_or_null(traffic_manager_path)
	var car := _car_node
	var tm := _traffic_node
	if car == null or tm == null:
		return

	var road_y := _road_height_at_car()
	if car.global_position.y < road_y - FALL_BELOW_ROAD:
		_trigger_crash(car, CAUSE_FELL, "", "y %.1f, road y %.1f" % [car.global_position.y, road_y], true)
		return

	var up_dot: float = car.global_basis.y.dot(Vector3.UP)
	if up_dot < ON_SIDE_DOT:
		_upside_down_timer += delta
		var grace := UPSIDE_DOWN_GRACE if up_dot < UPSIDE_DOWN_DOT else ON_SIDE_GRACE
		if _upside_down_timer >= grace:
			var tilt_deg := rad_to_deg(acos(clampf(up_dot, -1.0, 1.0)))
			var cause := CAUSE_FLIPPED if up_dot < UPSIDE_DOWN_DOT else CAUSE_ROLLED
			_trigger_crash(car, cause, "", "tilt %d deg for %.1fs" % [int(tilt_deg), _upside_down_timer], true)
			return
	else:
		_upside_down_timer = 0.0

	var roof_hit := _roof_on_ground(car)
	if not roof_hit.is_empty():
		_trigger_crash(car, CAUSE_FLIPPED, "Landed on the roof", "%s  shape %d" % [roof_hit.collider, roof_hit.shape], true)
		return

	var player_speed: float = car.linear_velocity.length()
	closest_traffic_tier = -1
	if tm.enabled: # dev console "Zero traffic" pulls the pool out of the tree
		for t in tm._cars:
			_check_near_miss(t, car, player_speed)

	# Real HIT detection uses actual physics contact now (car.gd's RigidBody3D
	# has contact_monitor enabled - see base car.tscn), not a distance/
	# "penetration depth" threshold. That numeric-penetration approach is
	# what the original three.js game used (no real collision shapes there
	# to prevent it), and it's what this project used too before traffic
	# cars had real CollisionShape3Ds - but now that they do, real collision
	# physically PREVENTS the player from ever penetrating past roughly
	# "combined half-extents" of both cars, so a penetration-depth check
	# essentially never fires anymore (verified empirically - see the
	# traffic-physics plan notes). Real contact is now the correct signal.
	for id in _traffic_hit_cooldowns.keys():
		_traffic_hit_cooldowns[id] -= delta
		if _traffic_hit_cooldowns[id] <= 0.0:
			_traffic_hit_cooldowns.erase(id)
	var touching := {}
	for body in car.get_colliding_bodies():
		if body.has_method("enter_knocked_state"):
			touching[body.get_instance_id()] = true
			_process_traffic_contact(car, body, delta)
			if GameState.current != GameState.State.PLAYING:
				return # that contact crashed the run
	_traffic_touching = touching

	if GameState.current == GameState.State.PLAYING:
		_process_barrier_contact(car, delta)
	_prev_velocity = car.linear_velocity

## The guardrail walls are extra collision shapes on each road chunk's
## StaticBody3D (road_generator.gd's _build_collision), the same body as the
## road surface - so they're picked out of the contact list by collider name
## plus a near-horizontal contact normal (the ground's normal points up).
## Returns {} when not touching a barrier this tick.
func _barrier_contact(car: RigidBody3D) -> Dictionary:
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	if state == null:
		return {}
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i) as Node
		if collider == null or not String(collider.name).begins_with("RoadChunk_"):
			continue
		# The road surface is a trimesh on the same body as the walls. When
		# the nose dips under braking the hull can scrape it, and trimesh
		# contacts at triangle edges / chunk seams report sideways normals
		# that pass the normal test below - which used to count as a
		# full-speed "wall hit". Walls are convex boxes, so skip the trimesh.
		if _is_ground_shape(collider, state.get_contact_collider_shape(i)):
			continue
		var normal: Vector3 = state.get_contact_local_normal(i)
		if absf(normal.y) > BARRIER_NORMAL_MAX_Y:
			continue
		var raw_normal := normal
		normal.y = 0.0
		return {
			"pos": state.get_contact_collider_position(i), "normal": normal.normalized(),
			"collider": collider.name, "shape": state.get_contact_collider_shape(i), "raw_normal": raw_normal,
		}
	return {}

## The road surface never damages the car or makes a sound (see
## _barrier_contact) - the only exception is the roof touching it. The
## contact normal points out of the road; seen from the car, the roof is
## touching when that normal points down along the car's own up axis.
const ROOF_CONTACT_DOT := -0.5

## Returns {collider, shape} of the road contact touching the roof, or {}.
func _roof_on_ground(car: RigidBody3D) -> Dictionary:
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	if state == null:
		return {}
	var car_up: Vector3 = car.global_basis.y
	for i in state.get_contact_count():
		var collider := state.get_contact_collider_object(i) as Node
		if collider == null or not String(collider.name).begins_with("RoadChunk_"):
			continue
		if not _is_ground_shape(collider, state.get_contact_collider_shape(i)):
			continue
		if state.get_contact_local_normal(i).dot(car_up) < ROOF_CONTACT_DOT:
			return {"collider": collider.name, "shape": state.get_contact_collider_shape(i)}
	return {}

func _is_ground_shape(collider: Node, shape_idx: int) -> bool:
	var body := collider as CollisionObject3D
	if body == null:
		return false
	var owner_id := body.shape_find_owner(shape_idx)
	var shape_node := body.shape_owner_get_owner(owner_id) as CollisionShape3D
	return shape_node != null and shape_node.shape is ConcavePolygonShape3D

## Road centreline height at the car's current distance along the path
## (RoadGenerator's tracker follows the car every physics tick). 0 if the
## generator isn't there, which keeps the old fixed-height behavior.
func _road_height_at_car() -> float:
	if not is_instance_valid(_road_node):
		_road_node = get_node_or_null(road_generator_path)
	var gen := _road_node
	if gen == null or gen.path == null or gen.tracker == null:
		return 0.0
	return gen.path.world_pos(gen.tracker.dist, 0.0).y

func _kmh(speed: float) -> int:
	return int(round(speed / UNIT_SCALE * 3.6))

func _barrier_detail(contact: Dictionary, speed: float) -> String:
	var n: Vector3 = contact.raw_normal
	return "%s  shape %d  %d km/h  normal (%.2f, %.2f, %.2f)" % [contact.collider, contact.shape, _kmh(speed), n.x, n.y, n.z]

func _process_barrier_contact(car: RigidBody3D, delta: float) -> void:
	if _barrier_hit_cooldown > 0.0:
		_barrier_hit_cooldown -= delta
	var contact := _barrier_contact(car)
	if contact.is_empty():
		in_barrier_contact = false
		return
	var pos: Vector3 = contact.pos
	var normal: Vector3 = contact.normal
	var into_speed: float = absf(_prev_velocity.dot(normal))
	var along: Vector3 = car.linear_velocity - normal * car.linear_velocity.dot(normal)
	along.y = 0.0
	var slide_speed: float = along.length()

	var is_new_contact := not in_barrier_contact
	in_barrier_contact = true
	if is_new_contact and into_speed > BARRIER_HIT_MIN_SPEED and _barrier_hit_cooldown <= 0.0:
		_barrier_hit_cooldown = BARRIER_HIT_COOLDOWN
		var hit_frac: float = into_speed / REFERENCE_MAX_SPEED
		var loss: float = lerpf(BARRIER_HIT_SPEED_LOSS_MIN, BARRIER_HIT_SPEED_LOSS_MAX, clampf(hit_frac, 0.0, 1.0))
		car.apply_central_impulse(-along * car.mass * loss)
		_scrape_player.stream = SFX_SCRAPE[randi() % SFX_SCRAPE.size()]
		_scrape_player.volume_db = _sfx_volume_db()
		_scrape_player.play()
		_spawn_hit_sparks(pos, hit_frac, 0, car.linear_velocity)
		_spawn_debris(pos, randi_range(5, 9), lerpf(4.0, 10.0, clampf(hit_frac, 0.0, 1.0)), car.linear_velocity)
		if hit_frac > TRAFFIC_WRECK_TRIGGER_FRAC:
			_play_big_crash_effects()
		if invuln_timer <= 0.0:
			var where := _classify_contact(car, pos, normal)
			var res := damage.apply_hit(where.zone, where.along, where.side, hit_frac * BARRIER_HIT_DAMAGE_SCALE)
			_log_hit("wall", where, hit_frac * BARRIER_HIT_DAMAGE_SCALE, res)
			if not res.lost.is_empty() or res.chassis_damage > 0.0:
				RiskEvents.collision.emit()
			if hp <= 0.0:
				_trigger_crash(car, CAUSE_TOTALED, "Hit the guardrail", _barrier_detail(contact, into_speed))
			if not res.lost.is_empty():
				_on_panels_torn_off(car, _hit_intensity(hit_frac * BARRIER_HIT_DAMAGE_SCALE))
			else:
				_on_hit_shake(_hit_intensity(hit_frac * BARRIER_HIT_DAMAGE_SCALE), res.chassis_damage > 0.0)
		return

	# Sliding / glancing along the wall.
	if slide_speed < BARRIER_SLIDE_MIN_SPEED:
		return
	car.apply_central_impulse(-along * car.mass * (1.0 - exp(-BARRIER_SLIDE_DRAG * delta)))
	var slide_frac: float = slide_speed / REFERENCE_MAX_SPEED
	if invuln_timer <= 0.0:
		var where := _classify_contact(car, pos, normal)
		var res := damage.apply_scrape(where.zone, where.along, where.side, slide_frac, delta)
		if not res.lost.is_empty():
			RiskEvents.collision.emit() # a panel torn off breaks the combo; wearing one down doesn't
			print("[Damage] wall scrape tore off %s" % [res.lost])
		if hp <= 0.0:
			_trigger_crash(car, CAUSE_TOTALED, "Ground along the guardrail", _barrier_detail(contact, slide_speed))
			return
		if not res.lost.is_empty():
			_on_panels_torn_off(car, _scrape_intensity(slide_frac))
	if not _barrier_slide_player.playing:
		_barrier_slide_player.volume_db = linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume * BARRIER_SLIDE_VOLUME, 0.0001, 1.0))
		_barrier_slide_player.play()
	_barrier_spark_timer -= delta
	if _barrier_spark_timer <= 0.0:
		_barrier_spark_timer = BARRIER_SLIDE_SPARK_INTERVAL
		_spawn_hit_sparks(pos, slide_frac * 0.3, randi_range(5, 9), car.linear_velocity)
	_barrier_debris_timer -= delta
	if _barrier_debris_timer <= 0.0:
		_barrier_debris_timer = BARRIER_SLIDE_DEBRIS_INTERVAL * randf_range(0.7, 1.3)
		_spawn_debris(pos, randi_range(2, 4), 4.0, car.linear_velocity)

## Where `t` is in the player's own frame (flattened heading): x = to the
## player's side, y = ahead (+) / behind (-), both in world units between the
## two origins. Vector2.INF if the car is pointing straight up/down. Shared
## with SlipstreamScorer.
static func player_frame_offset(car: Node3D, t: Node3D) -> Vector2:
	var fwd: Vector3 = car.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return Vector2.INF
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var rel: Vector3 = t.global_position - car.global_position
	return Vector2(rel.dot(side), rel.dot(fwd))

func _check_near_miss(t: Node3D, car: RigidBody3D, player_speed: float) -> void:
	# Still distance-based (not contact) - a near-miss is inherently about
	# NOT touching, so this is unaffected by traffic now having real
	# collision shapes. Reads the traffic car's REAL global_position (not
	# dist/x_frac) so this stays consistent with the real-contact hit check
	# above, and with FOLLOWING mode's own position (they match closely
	# under normal driving - verified drift ~0 - but can diverge briefly
	# during an active collision).
	#
	# Everything is measured in the player's own frame (flattened heading), so
	# "ahead"/"beside" stay correct through curves, where world X/Z don't.
	var offset := player_frame_offset(car, t)
	if not offset.is_finite():
		return
	var dz: float = offset.y # + = ahead of the player
	var dx: float = offset.x
	# Player extents are authored for the coupe; CarConfigurator scales them
	# per car (meta absent = coupe, 1.0).
	var half_w: float = PLAYER_HALF_W * float(car.get_meta("hull_w_scale", 1.0))
	var half_l: float = PLAYER_HALF_L * float(car.get_meta("hull_l_scale", 1.0))
	# Overtake: only cars seen ahead of the player can be overtaken (traffic
	# that spawns behind never counts), once each.
	if dz > 0.0:
		t.was_ahead = true
	elif dz < DEDUP_RESET_DZ and t.was_ahead and not t.overtaken:
		t.overtaken = true
		RiskEvents.overtake.emit(player_speed / REFERENCE_MAX_SPEED)

	# Real gap between the two cars' bodywork: treat both as boxes aligned to
	# the player and take the closest distance between them - pure side gap
	# while they overlap lengthwise, diagonal corner-to-corner distance past
	# the ends, bumper gap when one is straight ahead/behind.
	var gap_w: float = maxf(absf(dx) - (half_w + t.half_w), 0.0)
	var gap_l: float = maxf(absf(dz) - (half_l + t.half_len), 0.0)
	var gap: float = Vector2(gap_w, gap_l).length()

	# Near miss: while a car is inside the zone, just remember the closest tier
	# reached. The reward is paid when the car LEAVES the zone (you pulled
	# away, or it fell behind) - so riding alongside pays nothing until you
	# stray, and one pass can't be farmed. Each car remembers what it already
	# paid (`near_paid`), so coming back only pays again for a strictly
	# closer tier (Hairline after Near Miss, etc.). Tiers are RiskEvents.NearMissTier values.
	if gap < NEAR_MARGIN:
		var tier_now: int = RiskEvents.NearMissTier.CLOSE
		if gap < IMPOSSIBLE_MARGIN:
			tier_now = RiskEvents.NearMissTier.IMPOSSIBLE
		elif gap < HAIRLINE_MARGIN:
			tier_now = RiskEvents.NearMissTier.HAIRLINE
		t.near_best = maxi(t.near_best, tier_now)
		closest_traffic_tier = maxi(closest_traffic_tier, tier_now)
		return
	if t.near_best > t.near_paid:
		t.near_paid = t.near_best
		RiskEvents.near_miss.emit(player_speed / REFERENCE_MAX_SPEED, t.near_best)
		_overtake_player.stream = SFX_OVERTAKE
		_overtake_player.volume_db = _sfx_volume_db() + linear_to_db(OVERTAKE_VOLUME)
		_overtake_player.play()
	t.near_best = -1

## One tick of contact with traffic car `t`. A NEW contact (not touching last
## tick, off cooldown) is a hit; staying in contact along a side grinds that
## side like a wall slide. Both are sized by the RELATIVE velocity - the
## player's from last tick, since the solver has already cancelled this
## tick's into-contact component by the time the contact is reported.
func _process_traffic_contact(car: RigidBody3D, t: Node3D, delta: float) -> void:
	var id := t.get_instance_id()
	var contact := _traffic_contact(car, t)
	var normal: Vector3 = contact.normal
	var rel_v: Vector3 = _prev_velocity - (t as RigidBody3D).linear_velocity
	rel_v.y = 0.0
	var is_new := not _traffic_touching.has(id) and not _traffic_hit_cooldowns.has(id)
	if is_new:
		_traffic_hit_cooldowns[id] = TRAFFIC_HIT_COOLDOWN
		if invuln_timer <= 0.0:
			_register_collision(car, t, absf(rel_v.dot(normal)), rel_v, contact)
		return
	if invuln_timer > 0.0:
		return
	var where := _classify_contact(car, contact.pos, normal)
	if where.zone != CarDamageModel.Zone.LEFT and where.zone != CarDamageModel.Zone.RIGHT:
		return # pushing nose/tail against a car isn't a scrape
	var slide_speed: float = (rel_v - normal * rel_v.dot(normal)).length()
	if slide_speed < BARRIER_SLIDE_MIN_SPEED:
		return
	var slide_frac: float = slide_speed / REFERENCE_MAX_SPEED
	var res := damage.apply_scrape(where.zone, where.along, where.side, slide_frac, delta)
	if not res.lost.is_empty():
		RiskEvents.collision.emit()
		print("[Damage] %s scrape tore off %s" % [t.name, res.lost])
	_traffic_scrape_spark_timer -= delta
	if _traffic_scrape_spark_timer <= 0.0:
		_traffic_scrape_spark_timer = BARRIER_SLIDE_SPARK_INTERVAL
		_spawn_hit_sparks(contact.pos, slide_frac * 0.3, randi_range(5, 9), car.linear_velocity)
	if hp <= 0.0:
		_trigger_crash(car, CAUSE_TOTALED, "Sideswiped another vehicle", "%s  %d km/h" % [t.name, _kmh(slide_speed)])
	if not res.lost.is_empty():
		_on_panels_torn_off(car, _scrape_intensity(slide_frac))

## `closing` = relative speed along the contact normal; `rel_v` = full
## relative velocity (player minus traffic, flattened).
func _register_collision(car: RigidBody3D, t: Node3D, closing: float, rel_v: Vector3, contact: Dictionary) -> void:
	# Touching a car forfeits any near-miss reward from it.
	t.near_best = -1
	t.near_paid = RiskEvents.NearMissTier.IMPOSSIBLE
	var hit_frac := closing / REFERENCE_MAX_SPEED
	var where := _classify_contact(car, contact.pos, contact.normal)
	var res := damage.apply_hit(where.zone, where.along, where.side, hit_frac)
	_log_hit(t.name, where, hit_frac, res)
	# A dent keeps the combo alive; losing a panel or denting the chassis doesn't.
	if not res.lost.is_empty() or res.chassis_damage > 0.0:
		RiskEvents.collision.emit()
	# Only a car still driving reacts - one already KNOCKED/WRECKED is left to
	# its own physics (don't restart its impulse/timer on every bump).
	if t.control_mode == t.ControlMode.FOLLOWING:
		_hit_traffic_car(car, t, closing, rel_v, contact.pos)
	# Crash ONLY when the chassis actually reaches 0 - armor soaks the first
	# hard hit, then exposed hits take CarDamageModel.CHASSIS_HARD_HIT each.
	if hp <= 0.0:
		# Struck from behind = the other car ran into the player; anywhere else
		# the player drove into it.
		var reason := "Hit by another vehicle" if where.zone == CarDamageModel.Zone.REAR else "Hit another vehicle"
		_trigger_crash(car, CAUSE_TOTALED, reason, "%s  %d km/h closing" % [t.name, _kmh(closing)])
	if not res.lost.is_empty():
		_on_panels_torn_off(car, _hit_intensity(hit_frac))
	else:
		_on_hit_shake(_hit_intensity(hit_frac), res.chassis_damage > 0.0)

## A panel torn off: impact slow-mo (slow_mo.gd impact()) + camera shake,
## both scaled by `intensity` 0..1. Skipped when the same hit crashed the run
## (the crash has its own slow-mo).
func _on_panels_torn_off(car: RigidBody3D, intensity: float) -> void:
	if GameState.current != GameState.State.PLAYING:
		return
	var sm := car.get_node_or_null("SlowMo")
	if sm and sm.has_method("impact"):
		sm.impact(intensity)
	_shake.shake(intensity)

## Every other hit: camera shake only (no slow-mo), softer than a panel
## tearing off - a hit on bare chassis at CHASSIS_SHAKE_SCALE, one the armor
## soaked (a dent) at DENT_SHAKE_SCALE. Also plays when the hit crashed the
## run - the shake carries into the crash spin.
const CHASSIS_SHAKE_SCALE := 0.8
const DENT_SHAKE_SCALE := 0.6

func _on_hit_shake(intensity: float, chassis: bool) -> void:
	_shake.shake(intensity * (CHASSIS_SHAKE_SCALE if chassis else DENT_SHAKE_SCALE))

## Hit severity -> effect intensity: a hard hit (CarDamageModel.HARD_FRAC)
## is full; the lightest panel-losing hits still get a noticeable floor.
const TORN_OFF_MIN_INTENSITY := 0.3

func _hit_intensity(hit_frac: float) -> float:
	return clampf(hit_frac / CarDamageModel.HARD_FRAC, TORN_OFF_MIN_INTENSITY, 1.0)

## A door worn off by scraping: gentler than a hit, a bit more at speed.
func _scrape_intensity(slide_frac: float) -> float:
	return clampf(TORN_OFF_MIN_INTENSITY + slide_frac * 0.4, TORN_OFF_MIN_INTENSITY, 0.7)

const KNOCK_IMPULSE_TRANSFER := 0.5 # fraction of the relative momentum transferred into a hit traffic car
const KNOCK_SPIN_IMPULSE := 300.0
const TRAFFIC_WRECK_TRIGGER_FRAC := 0.5 # impact above this fraction of REFERENCE_MAX_SPEED also flashes the screen

# Per user feedback: traffic used to fly away on a hit AND the player never
# felt like they'd hit anything solid. Both come from the same root cause -
# see traffic_car.gd's MASS_FOOTPRINT_SCALE/MASS_MIN/MASS_MAX note (bumped
# further there) - but a heavier traffic car alone still doesn't push back
# on the PLAYER, since the impulse below only ever applied to the traffic
# car. PLAYER_REACTION_TRANSFER applies a real equal-and-opposite reaction
# to the player's own car (Newton's third law, not just flavor) - a fraction
# of the exact same impulse the traffic car receives, so a heavier-feeling
# hit now visibly knocks the player's own momentum too, not just the target.
const PLAYER_REACTION_TRANSFER := 0.4

## Hands the traffic car `t` off to real physics - impulse along the relative
## velocity (a real shove the way the two cars were closing), magnitude
## scaled by the player's mass, the closing speed and a transfer fraction -
## not a full elastic-collision derivation, just a plausible, tunable-by-feel
## push. A light hit only KNOCKS the car (it recovers and drives on); a hard
## one (CarDamageModel.HARD_FRAC and up) WRECKS it (stops for good, hazard
## lights, becomes an obstacle); a big enough one also flashes the screen.
func _hit_traffic_car(car: RigidBody3D, t: Node3D, closing: float, rel_v: Vector3, hit_pos: Vector3) -> void:
	var hit_frac: float = closing / REFERENCE_MAX_SPEED
	_scrape_player.stream = SFX_SCRAPE[randi() % SFX_SCRAPE.size()]
	# Taps are quieter than real hits.
	_scrape_player.volume_db = _sfx_volume_db() + linear_to_db(clampf(0.35 + hit_frac * 2.0, 0.35, 1.0))
	_scrape_player.play()
	_spawn_hit_sparks(hit_pos, hit_frac, 0, car.linear_velocity)
	# Car-on-car: far more sparks (16-44 above) than debris.
	_spawn_debris(hit_pos, randi_range(3, 6), lerpf(4.0, 9.0, clampf(hit_frac, 0.0, 1.0)), car.linear_velocity)
	var dir: Vector3 = rel_v.normalized()
	if rel_v.length_squared() < 1.0:
		dir = (t.global_position - car.global_position).normalized()
	var impulse: Vector3 = dir * (car.mass * closing * KNOCK_IMPULSE_TRANSFER)
	var spin: float = KNOCK_SPIN_IMPULSE * clampf(hit_frac / CarDamageModel.HARD_FRAC, 0.2, 1.0) * (1.0 if randf() < 0.5 else -1.0)
	if hit_frac >= CarDamageModel.HARD_FRAC:
		t.enter_wrecked_state(impulse, spin)
	else:
		t.enter_knocked_state(impulse, spin)
	if hit_frac > TRAFFIC_WRECK_TRIGGER_FRAC:
		_play_big_crash_effects()
	# Equal and opposite (scaled down) - hitting something heavier should
	# knock the PLAYER back/sideways too, not just the thing they hit.
	car.apply_central_impulse(-impulse * PLAYER_REACTION_TRANSFER)

const IMPACT_SPARKS_SCENE := preload("res://MAIN/misc/ImpactSparks.tscn")

func _play_big_crash_effects() -> void:
	var flash: Node = get_node_or_null(impact_flash_path)
	if flash:
		flash.flash(1.0)

## Where the player's car is touching `t` and the contact normal (flattened),
## from the physics engine's own contact list (car.tscn has contact_monitor
## on). Falls back to the midpoint between the two cars, normal pointing from
## the player to `t`, if no matching contact is reported this tick.
func _traffic_contact(car: RigidBody3D, t: Node3D) -> Dictionary:
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	if state:
		for i in state.get_contact_count():
			if state.get_contact_collider_object(i) == t:
				var n: Vector3 = state.get_contact_local_normal(i)
				n.y = 0.0
				if n.length_squared() > 0.01:
					return {"pos": state.get_contact_collider_position(i), "normal": n.normalized()}
	var to_t := t.global_position - car.global_position
	to_t.y = 0.0
	return {
		"pos": car.global_position.lerp(t.global_position, 0.5) + Vector3(0, 1.0, 0),
		"normal": to_t.normalized() if to_t.length_squared() > 0.0001 else car.global_basis.z,
	}

## One console line per hit, for tuning CarDamageModel's thresholds in play.
func _log_hit(source: String, where: Dictionary, frac: float, res: Dictionary) -> void:
	print("[Damage] %s -> %s (%s)  %d km/h closing  frac %.2f  lost %s  chassis -%.0f (%.0f/%.0f)" % [
		source, CarDamageModel.Zone.keys()[where.zone], where.side, _kmh(frac * REFERENCE_MAX_SPEED),
		frac, res.lost, res.chassis_damage, hp, max_hp])

## Which armor zone a contact at world `pos` with (flattened) `normal` hits,
## in the player's own frame: {zone: CarDamageModel.Zone, along: -1 rear..+1
## front, side: "L"/"R"}. The normal decides end-on vs side-on (a wall slide
## touching at the front corner is still a side scrape); the position says
## which end/side. +X is the car's left (forward is +Z).
func _classify_contact(car: RigidBody3D, pos: Vector3, normal: Vector3) -> Dictionary:
	var fwd: Vector3 = car.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized() if fwd.length_squared() > 0.0001 else Vector3.FORWARD
	var left := Vector3(fwd.z, 0.0, -fwd.x)
	var rel := pos - car.global_position
	var half_w: float = PLAYER_HALF_W * float(car.get_meta("hull_w_scale", 1.0))
	var half_l: float = PLAYER_HALF_L * float(car.get_meta("hull_l_scale", 1.0))
	var along := clampf(rel.dot(fwd) / half_l, -1.0, 1.0)
	var across := clampf(rel.dot(left) / half_w, -1.0, 1.0)
	var end_on := absf(along) > absf(across)
	var n := Vector3(normal.x, 0.0, normal.z)
	if n.length_squared() > 0.01:
		end_on = absf(n.dot(fwd)) > absf(n.dot(left))
	var zone: CarDamageModel.Zone
	if end_on:
		zone = CarDamageModel.Zone.FRONT if along >= 0.0 else CarDamageModel.Zone.REAR
	else:
		zone = CarDamageModel.Zone.LEFT if across >= 0.0 else CarDamageModel.Zone.RIGHT
	return {"zone": zone, "along": along, "side": "L" if across >= 0.0 else "R"}

## Randomized burst at the impact point on EVERY hit (not just wrecks): each
## burst gets a random tilt/facing (so the spray never looks identical) and
## its size/speed scale with how hard the hit was (`hit_frac` = impact speed
## / REFERENCE_MAX_SPEED).
## `amount_override` > 0 replaces the hit-scaled count (barrier slides use
## small, frequent bursts instead of one big one).
func _spawn_hit_sparks(pos: Vector3, hit_frac: float, amount_override := 0, car_velocity := Vector3.ZERO) -> void:
	var frac := clampf(hit_frac, 0.0, 1.0)
	var sparks: CPUParticles3D = IMPACT_SPARKS_SCENE.instantiate()
	sparks.amount = amount_override if amount_override > 0 else int(lerpf(16.0, 44.0, frac)) + randi_range(-4, 4)
	sparks.initial_velocity_max = lerpf(9.0, 22.0, frac) * randf_range(0.85, 1.15)
	sparks.direction = _random_tilt(0.7)
	_launch_burst(sparks, pos, car_velocity)

const IMPACT_DEBRIS_SCENE := preload("res://MAIN/misc/ImpactDebris.tscn")

## A handful of tumbling chunks thrown from the impact point, randomly tilted
## like the sparks. Kept few on purpose - sparks are the main effect.
func _spawn_debris(pos: Vector3, amount: int, max_velocity: float, car_velocity := Vector3.ZERO) -> void:
	var debris: CPUParticles3D = IMPACT_DEBRIS_SCENE.instantiate()
	debris.amount = maxi(amount, 1)
	debris.initial_velocity_max = max_velocity * randf_range(0.85, 1.15)
	debris.direction = _random_tilt(0.6)
	_launch_burst(debris, pos, car_velocity)

## Bursts spawn slightly AHEAD of the contact point along the car's velocity
## (BURST_LEAD_TIME seconds' worth) and start out carried along at
## BURST_CARRY_FRAC of that velocity, decaying (see impact_sparks.gd) - at
## speed they'd otherwise be left behind the car the instant they appear.
const BURST_LEAD_TIME := 0.06
const BURST_CARRY_FRAC := 0.85

func _launch_burst(burst: CPUParticles3D, pos: Vector3, car_velocity: Vector3) -> void:
	burst.set("carry_velocity", car_velocity * BURST_CARRY_FRAC) # script var, not a CPUParticles3D property
	get_parent().add_child(burst)
	burst.global_position = pos + car_velocity * BURST_LEAD_TIME

## Straight up, tilted randomly by up to `max_tilt` radians in a random
## direction - so no two bursts spray the same way.
func _random_tilt(max_tilt: float) -> Vector3:
	return Vector3.UP.rotated(Vector3.RIGHT, randf_range(-max_tilt, max_tilt)).rotated(Vector3.UP, randf() * TAU)

const CRASH_TIME_SCALE := 0.15 # very strong slow-mo (was 0.3, halved per user request)
# Audio playback speed/pitch during the crash spin - same mechanism as the
# Speedbreaker (AudioServer.playback_speed_scale), but not as extreme as
# CRASH_TIME_SCALE since 0.15 turns every sound into a rumble.
const CRASH_AUDIO_SPEED := 0.5

## `unrecoverable` = flipped over or fell off the map: skips the crash spin.
func _trigger_crash(car: RigidBody3D, cause: String, reason: String, detail: String, unrecoverable := false) -> void:
	# Dev console "Invincible": nothing crashes the run except falling off the
	# world (otherwise the car would just fall forever).
	if DevConsole.invincible and cause != CAUSE_FELL:
		hp = max_hp
		return
	_crash_player.volume_db = _sfx_volume_db()
	_crash_player.play()
	last_crash_cause = cause
	last_crash_reason = reason
	last_crash_detail = detail
	print("[CrashSystem] crash: %s | %s | %s" % [cause, reason, detail])
	_crash_timer = 0.0
	if not unrecoverable:
		var dir: float = -1.0 if randf() < 0.5 else 1.0
		car.apply_torque_impulse(Vector3(0, dir * CRASH_SPIN_IMPULSE, 0))
	# Player input fully cut the instant a crash triggers (was previously a
	# known, documented gap - car.gd kept reading input during the spin).
	# _physics_process() above calls CarInputLock.suppress_input() every
	# frame for the duration of CRASHING - nothing to do here at trigger
	# time itself beyond that loop starting once GameState flips below.
	# Slow-mo for the spin itself. _crash_timer counts real seconds (it
	# divides the scaled delta back out), so CRASH_SLOWMO_DURATION is the
	# wall-clock wait regardless of how strong the slow-mo is.
	Engine.time_scale = CRASH_TIME_SCALE
	GameState.set_state(GameState.State.CRASHING)
	# After set_state: slow_mo.gd resets playback speed to 1.0 when it sees
	# CRASHING, so this has to land after that. Undone in _on_state_changed().
	AudioServer.playback_speed_scale = CRASH_AUDIO_SPEED
