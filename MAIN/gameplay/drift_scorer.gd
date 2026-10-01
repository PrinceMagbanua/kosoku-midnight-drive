class_name DriftScorer
extends Node

## Drift scoring. A drift SESSION builds its own running total (shown by the
## HUD's DriftMeter) and, when it ends, lands in RunRewards' combo pile as ONE
## event (RunRewards.register_drift - +1 streak, current combo multiplier).
##
## Qualifying = raw speed >= MIN_SPEED_KMH and slip angle (flattened heading
## vs. flattened velocity) between MIN_ANGLE_DEG and SPIN_ANGLE_DEG. While
## qualifying, per physics tick:
##   pts += DRIFT_RATE * delta * angle_factor * speed_factor * duration_mult
##          * prox_mult * nitro_mult
## - angle_factor: ramps 0.3 -> 1.0 over 15-45 deg, flat to 70, tapers to 0.5
##   at the 100 deg spin-out.
## - speed_factor: speed / CrashSystem.REFERENCE_MAX_SPEED, clamped the same
##   way RunRewards clamps it for near-misses.
## - duration_mult: +1x every DURATION_STEP seconds of qualifying drift in
##   this session, capped at DURATION_CAP.
## - prox_mult: the BEST of traffic closeness (CrashSystem's near-miss tiers)
##   and the guardrail (within WALL_RANGE, only while NOT touching it) - max,
##   not product.
## - nitro_mult: RunRewards.nitro_points_mult() - only while actually boosting.
## `delta` is scaled game time, so pause/Speedbreaker don't inflate points.
##
## A session ends (points KEPT, landed) when: not qualifying for longer than
## GRACE_TIME (straightened out, or dropped under the min speed - the grace
## lets a left->right flick stay one session), the angle passes
## SPIN_ANGLE_DEG ("SPUN OUT"), or RiskEvents.collision ("HIT" - lands after
## RunRewards.break_combo, so at 1x combo). A crash lands and banks it;
## leaving the run discards it. Totals under MIN_LAND_POINTS don't land (no streak farming
## with micro-slides). Nothing scores during the start cinematic.
##
## Tuning target: a clean 5 s, 45 deg drift at ~120 km/h ~= 125 points before
## combo (about 5 CLOSE near-misses).

const MIN_SPEED_KMH := 30.0
const MIN_ANGLE_DEG := 15.0
const FULL_ANGLE_DEG := 45.0 # angle_factor reaches 1.0 here...
const FLAT_END_DEG := 70.0 # ...stays there until here...
const SPIN_ANGLE_DEG := 100.0 # ...tapers to TAPER_MIN here; past it = spun out
const ANGLE_FACTOR_MIN := 0.3
const TAPER_MIN := 0.5
const GRACE_TIME := 0.6
const DRIFT_RATE := 21.0 # points per second at factor 1 everywhere
const DURATION_STEP := 2.0 # seconds per +1x
const DURATION_CAP := 5.0
const MIN_LAND_POINTS := 10.0

const PROX_CLOSE := 1.5
const PROX_HAIRLINE := 2.0
const PROX_IMPOSSIBLE := 3.0
const PROX_WALL := 1.5
const WALL_RANGE := 1.0 * RoadMetrics.UNIT_SCALE # bodywork-to-wall gap, 1 m

# Same conversion live_hud.gd / debug.gd use for km/h.
const KPH_PER_UNIT_SPEED := 1.10130592

@export var car_path: NodePath = NodePath("../car")
@export var crash_system_path: NodePath = NodePath("../CrashSystem")
@export var road_generator_path: NodePath = NodePath("../RoadGenerator")

var active := false
var points := 0.0
var drift_time := 0.0 # qualifying seconds this session (drives duration_mult)
var _grace := 0.0
# Cached targets of the paths above (looked up again only if they go away).
var _car: RigidBody3D
var _crash_system: CrashSystem
var _road_gen: Node

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)
	RiskEvents.collision.connect(_on_collision)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state == GameState.State.PAUSED:
		return
	if new_state == GameState.State.PLAYING and old_state == GameState.State.PAUSED:
		return
	if new_state == GameState.State.CRASHING and active:
		# A crash keeps what was earned: land the drift, then bank it (RunRewards
		# already banked the rest of the pile on this same state change).
		_end("HIT")
		RunRewards.bank_pile()
		return
	# Fresh run, garage... - a live drift doesn't survive those.
	_discard()

func _on_collision() -> void:
	if active:
		_end("HIT")

func duration_mult() -> float:
	return minf(DURATION_CAP, 1.0 + floorf(drift_time / DURATION_STEP))

func _physics_process(delta: float) -> void:
	if GameState.current != GameState.State.PLAYING or IntroPan.playing:
		return
	if not is_instance_valid(_car):
		_car = get_node_or_null(car_path) as RigidBody3D
	var car := _car
	if car == null:
		return

	var vel: Vector3 = car.linear_velocity
	vel.y = 0.0
	var fwd: Vector3 = car.global_basis.z
	fwd.y = 0.0
	var speed: float = vel.length()
	var qualifying := false
	var angle := 0.0
	if speed * KPH_PER_UNIT_SPEED >= MIN_SPEED_KMH and fwd.length_squared() > 0.0001:
		angle = rad_to_deg(fwd.normalized().angle_to(vel.normalized()))
		if active and angle > SPIN_ANGLE_DEG:
			_end("SPUN OUT")
			return
		qualifying = angle >= MIN_ANGLE_DEG and angle <= SPIN_ANGLE_DEG

	if not qualifying:
		if active:
			_grace += delta
			if _grace >= GRACE_TIME:
				_end("DRIFT")
		return

	if not active:
		active = true
		points = 0.0
		drift_time = 0.0
		RunRewards.drift_active = true
	_grace = 0.0
	drift_time += delta
	RunRewards.add_time("drift", delta)

	var speed_factor: float = clampf(speed / CrashSystem.REFERENCE_MAX_SPEED, RunRewards.MIN_SPEED_FACTOR, RunRewards.MAX_SPEED_FACTOR)
	var prox := _proximity(car, fwd.normalized())
	points += DRIFT_RATE * delta * _angle_factor(angle) * speed_factor * duration_mult() * prox[0] * RunRewards.nitro_points_mult()
	RiskEvents.drift_updated.emit(points, duration_mult(), prox[0], prox[1], angle)

func _angle_factor(angle: float) -> float:
	if angle <= FULL_ANGLE_DEG:
		return lerpf(ANGLE_FACTOR_MIN, 1.0, inverse_lerp(MIN_ANGLE_DEG, FULL_ANGLE_DEG, angle))
	if angle <= FLAT_END_DEG:
		return 1.0
	return lerpf(1.0, TAPER_MIN, inverse_lerp(FLAT_END_DEG, SPIN_ANGLE_DEG, angle))

## [multiplier, label] - best of traffic closeness and the guardrail.
func _proximity(car: RigidBody3D, fwd: Vector3) -> Array:
	var best := 1.0
	var label := ""
	if not is_instance_valid(_crash_system):
		_crash_system = get_node_or_null(crash_system_path) as CrashSystem
	var cs := _crash_system
	if cs:
		match cs.closest_traffic_tier:
			RiskEvents.NearMissTier.IMPOSSIBLE:
				best = PROX_IMPOSSIBLE
				label = "IMPOSSIBLE!"
			RiskEvents.NearMissTier.HAIRLINE:
				best = PROX_HAIRLINE
				label = "HAIRLINE!"
			RiskEvents.NearMissTier.CLOSE:
				best = PROX_CLOSE
				label = "CLOSE!"
		if PROX_WALL > best and not cs.in_barrier_contact and _wall_gap(car, fwd) < WALL_RANGE:
			best = PROX_WALL
			label = "WALL!"
	return [best, label]

## Gap between the car's bodywork and the nearer guardrail's inner face, in
## engine units (INF if the road isn't available). The car's footprint is
## projected onto the road's lateral axis using its yaw relative to the road,
## so a car sliding sideways (long side toward the wall) reads closer.
func _wall_gap(car: RigidBody3D, fwd: Vector3) -> float:
	if not is_instance_valid(_road_gen):
		_road_gen = get_node_or_null(road_generator_path)
	var rg := _road_gen
	if rg == null or rg.tracker == null:
		return INF
	var path: RoadPath = rg.tracker.path
	var d: float = rg.tracker.dist
	var p0: Vector3 = path.world_pos(d, 0.0)
	var left: Vector3 = path.world_pos(d, 1.0) - p0
	var along: Vector3 = path.world_pos(d + 1.0, 0.0) - p0
	left.y = 0.0
	along.y = 0.0
	if left.length_squared() < 0.000001 or along.length_squared() < 0.000001:
		return INF
	left = left.normalized()
	along = along.normalized()
	var rel: Vector3 = car.global_position - p0
	rel.y = 0.0
	var signed_lat: float = rel.dot(left)
	var lateral: float = absf(signed_lat)
	var half_w: float = CrashSystem.PLAYER_HALF_W * float(car.get_meta("hull_w_scale", 1.0))
	var half_l: float = CrashSystem.PLAYER_HALF_L * float(car.get_meta("hull_l_scale", 1.0))
	var extent: float = half_w * absf(fwd.dot(along)) + half_l * absf(fwd.dot(left))
	# The nearer wall is the one on the car's side - its position comes from
	# RoadLayout (the left one moves in where a lane closes / in tunnels).
	var edge: float = absf(rg.layout.shoulder_edge(d, 1.0 if signed_lat >= 0.0 else -1.0)) if rg.layout else rg.SHOULDER_HALF_WIDTH
	var wall_inner: float = edge - rg.WALL_THICKNESS
	return wall_inner - lateral - extent

func _end(reason: String) -> void:
	var landed := 0
	if points >= MIN_LAND_POINTS:
		landed = RunRewards.register_drift(points, "SPUN OUT" if reason == "SPUN OUT" else "DRIFT")
	_reset()
	RiskEvents.drift_ended.emit(landed, reason)

func _discard() -> void:
	var was_active := active
	_reset()
	if was_active:
		RiskEvents.drift_ended.emit(0, "LOST")

func _reset() -> void:
	active = false
	points = 0.0
	drift_time = 0.0
	_grace = 0.0
	RunRewards.drift_active = false
