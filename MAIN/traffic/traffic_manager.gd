extends Node3D

## Port of traffic.js + the traffic portion of main.js's update(dt) loop.
## Centralized manager (not per-car _process) because following/lane-clear
## checks need to query every other car each frame - same architecture as
## the original.
##
## Two regressions are DOCUMENTED in Voxel Driver's AGENTS.md and must not
## be reintroduced here - both are called out at the exact lines that fix
## them below:
##   A) "overlap bug" - a per-lane front-tracker (`_lane_front`) collapsing
##      into one shared/cross-lane value. Fix: `_required_center()` must
##      only ever read/write `_lane_front[lane]` for the lane it was passed.
##   B) "spawn-runaway bug" - making the final spawn-distance clamp against
##      `ahead_max` conditional ("skip it if it would violate the gap")
##      let the per-recycle distance ratchet outward forever until every car
##      was unreachable. Fix: the clamp in `_place_traffic_car()` is
##      unconditional, always applied last, no exceptions.
##
## Lane math goes through RoadMetrics exclusively (see road_metrics.gd) -
## Voxel Driver also has a documented regression from a second, slightly
## different copy of the lane->x formula getting inlined into spawn code.
##
## NOT ported yet, deliberately (needs systems that don't exist in this
## Godot project yet):
## - Bump-spring reaction to being hit (needs a ram/collision system - step 6)
## - pileup/wrecked states, dodge/near-miss scoring (needs scoring - step 6)
## - difficulty-driven aggroMul/blocker cars (garage's difficulty upgrades
##   don't affect gameplay yet - nothing to read them from)
## - Blinker visual toggle (cheap, cosmetic, skipped for time - not a gap in
##   the AI logic itself)
##
## Hulls are Voxel Driver's own asset pack (assets/cars/structured/*.glb,
## copied into res://assets/cars/) mapped onto the same 5 "kind" categories -
## half_len/half_w for gap math come from each model's own AABB
## (traffic_car.gd), not hand-authored dims.

const UNIT_SCALE := RoadMetrics.UNIT_SCALE
const LANES := RoadMetrics.LANES

const GAP_CARS := 4
const AVG_CAR_LEN_M := 4.6
const GAP_DIST := GAP_CARS * AVG_CAR_LEN_M * UNIT_SCALE

const SPAWN_AHEAD_MIN := 200.0 * UNIT_SCALE
const SPAWN_AHEAD_MAX := 620.0 * UNIT_SCALE
const DESPAWN_BEHIND := 90.0 * UNIT_SCALE
const SPAWN_BEHIND_MIN := 60.0 * UNIT_SCALE
const SPAWN_BEHIND_MAX := 220.0 * UNIT_SCALE
const GAP_SEGMENT_LENGTH := 110.0 * UNIT_SCALE

const IDLE_SPEED_THRESHOLD := 3.0 * UNIT_SCALE
const IDLE_SPAWN_INTERVAL := 10.0
const BEHIND_SPAWN_CHANCE := 0.25
const BEHIND_SPAWN_CHANCE_IDLE := 0.05

const LANE_CHANGE_CHANCE := 0.045
const SIGNAL_DURATION := 1.4
const LANE_CHANGE_DURATION := 1.6
const TRAFFIC_LANE_YAW_MAX := 0.26

const TRAFFIC_COUNT := 35 # round(26 * LANES/3), baseline (no difficulty scaling yet)
# Used to be a fixed seed (777, matching js/traffic.js's mulberry32(777) -
# useful early on for reproducible debugging of the lane-following AI) -
# now randomized fresh each run (_ready() and reset_traffic() both draw a
# new one via randi()) per user request, so traffic actually looks
# different run to run instead of retracing the exact same pattern.

const PLAYER_HALF_LEN := 2.0 * UNIT_SCALE # rough player-car half-length for gap math

## Lane closures (RoadLayout - e.g. 4 -> 3 lanes through a tunnel). LANES above
## is the WIDEST the road gets; a lane is "usable" at a distance only if it
## stays open for MERGE_LOOKAHEAD beyond it, so cars never spawn into or
## change into a lane that's about to close. A car already in a closing lane
## merges out once it's within MERGE_LOOKAHEAD, waits for a gap, and slows
## toward where the barrier comes in if it can't find one; inside
## MERGE_URGENT_DIST of that point it goes regardless.
const MERGE_LOOKAHEAD := 260.0 * UNIT_SCALE
const MERGE_URGENT_DIST := 40.0 * UNIT_SCALE
const MERGE_SIGNAL_TIME := 0.7

const KINDS := [
	{"name": "wide", "weight": 0.20},
	{"name": "normal", "weight": 0.35},
	{"name": "passenger", "weight": 0.35},
	{"name": "armored", "weight": 0.05},
	{"name": "police", "weight": 0.05},
]

const HULL_SCENES := {
	"wide": preload("res://assets/cars/truck.glb"),
	"normal": preload("res://assets/cars/taxi.glb"),
	"passenger": preload("res://assets/cars/passenger.glb"),
	"armored": preload("res://assets/cars/armored.glb"),
	"police": preload("res://assets/cars/police.glb"),
}

const TRAFFIC_CAR_SCENE := preload("res://MAIN/traffic/TrafficCar.tscn")

@export var car_path: NodePath = NodePath("../car")
@export var road_generator_path: NodePath = NodePath("../RoadGenerator")

var _cars: Array = []
var _lane_front: Array = [] # size == LANES, per-lane front tracker (Regression A)
var _gap_lane_segments: Dictionary = {} # band index (int) -> lane (int)
var _rng := RandomNumberGenerator.new()
var _last_spawn_time: float = 0.0
## False = the dev console's "Zero traffic": every pooled car is taken out of
## the tree (no visuals, no collision) and nothing updates. See set_enabled().
var enabled := true

## The road now curves - the AI's own dist/x_frac math stays valid 1D
## arc-length math unchanged (that's exactly why the original's dist-based
## traffic model still ports cleanly onto a curving road), but converting
## to/from real world positions needs RoadGenerator's RoadPath/PathTracker.
func _road_path() -> RoadPath:
	var rg := _road_gen()
	return rg.path if rg else null

func _layout() -> RoadLayout:
	var rg := _road_gen()
	return rg.layout if rg else null

## Cached - these accessors run several times per car every physics tick.
## (path/layout themselves are re-read each call: a new run replaces them.)
var _rg: Node = null

func _road_gen() -> Node:
	if not is_instance_valid(_rg):
		_rg = get_node_or_null(road_generator_path)
	return _rg

## `lane` exists at `dist` and stays open for MERGE_LOOKAHEAD after it.
func _lane_usable(lane: int, dist: float) -> bool:
	if lane < 0 or lane >= LANES:
		return false
	var layout := _layout()
	return layout == null or layout.lane_open_over(lane, dist, dist + MERGE_LOOKAHEAD)

## Number of lanes (from the right) usable at `dist` - see _lane_usable.
func _usable_lanes(dist: float) -> int:
	var n := LANES
	while n > 1 and not _lane_usable(n - 1, dist):
		n -= 1
	return n

## RoadGenerator's own PathTracker is the single source of truth for "how
## far along the road has the player gotten" - its _physics_process runs
## before this one (RoadGenerator is earlier in world.tscn's tree), so this
## is always fresh for the current frame.
func _player_dist() -> float:
	var rg := _road_gen()
	if rg and rg.tracker:
		return rg.tracker.dist
	var car: Node3D = get_node_or_null(car_path)
	return car.global_position.z if car else 0.0

## Inverts RoadPath.world_pos()'s banked cross-section transform: projects
## `world_pos_value` onto the road frame's own right vector at `dist`,
## undoing the `cos(bank)` scale world_pos applies to lateral offsets.
func _lateral_offset(dist: float, world_pos_value: Vector3) -> float:
	var rp := _road_path()
	if rp == null:
		return world_pos_value.x
	var f: Dictionary = rp.road_frame(dist)
	var right := Vector3(cos(f.heading), 0, -sin(f.heading))
	var offset: Vector3 = world_pos_value - f.pos
	return offset.dot(right) / maxf(cos(f.bank), 0.2)

func _ready() -> void:
	if Engine.is_editor_hint():
		return
	_rng.seed = randi()
	_lane_front.resize(LANES)
	for i in range(LANES):
		_lane_front[i] = 0.0

	var player_dist: float = _player_dist()

	for i in range(TRAFFIC_COUNT):
		var t: Node3D = TRAFFIC_CAR_SCENE.instantiate()
		add_child(t)
		var kind: Dictionary = _pick_kind()
		t.setup_visual(HULL_SCENES[kind.name], UNIT_SCALE)
		_cars.append(t)
		_place_traffic_car(t, SPAWN_AHEAD_MIN, SPAWN_AHEAD_MAX, player_dist)

	_last_spawn_time = Time.get_ticks_msec() / 1000.0
	if DevConsole.zero_traffic: # still ticked from before a scene reload
		set_enabled.call_deferred(false) # deferred - the tree is locked during _ready

## Called by run_reset.gd when a fresh run starts (garage -> Play Endless,
## after a crash) - re-places the EXISTING pooled cars around the car's
## (already-reset) spawn position, mirroring exactly what _ready() does on
## first load, rather than instantiating a whole new pool. Re-seeding _rng
## and clearing _lane_front/_gap_lane_segments matters, not just cosmetic:
## _required_center()'s own logic only advances a lane's stale _lane_front
## value when it's LESS than the current player_dist - after a long run,
## the old value would be far larger than the freshly-reset (~0) player_dist,
## so without clearing it here, new traffic would spawn at the OLD run's
## distances instead of near the new start (the exact regression class this
## traffic system has hit before - see Regression A/B notes throughout this
## file).
func reset_traffic() -> void:
	if not enabled:
		return # re-placed by set_enabled(true) instead
	var player_dist: float = _player_dist()
	_rng.seed = randi()
	for i in range(LANES):
		_lane_front[i] = 0.0
	_gap_lane_segments.clear()
	for t in _cars:
		t.resume_following() # clear any KNOCKED/WRECKED state left over from the crash
		_place_traffic_car(t, SPAWN_AHEAD_MIN, SPAWN_AHEAD_MAX, player_dist)
	_last_spawn_time = Time.get_ticks_msec() / 1000.0

func _physics_process(delta: float) -> void:
	if Engine.is_editor_hint() or _cars.is_empty() or not enabled:
		return
	var car: Node3D = get_node_or_null(car_path)
	if car == null:
		return
	var player_dist: float = _player_dist()
	var player_lateral: float = _lateral_offset(player_dist, car.global_position)
	var player_lane: int = RoadMetrics.x_to_lane(player_lateral)
	# Well out on the right shoulder or parked in the starting lay-by: the
	# player isn't in any lane (-1), so traffic passes in lane 0 as normal
	# instead of treating a parked car as one stopped in its lane.
	if player_lateral < RoadMetrics.RIGHT_EDGE - RoadMetrics.SHOULDER_WIDTH * 0.5:
		player_lane = -1
	var player_speed: float = car.linear_velocity.length()

	# Shared blink phase - one oscillator for every car's turn signal, so
	# they all pulse in sync like real traffic would incidentally look
	# (rather than each car free-running its own timer).
	var blink_on: bool = fmod(Time.get_ticks_msec() / 1000.0, TURN_SIGNAL_PERIOD) < TURN_SIGNAL_PERIOD * 0.5

	PerfMonitor.begin("traffic")
	for t in _cars:
		_update_car(t, delta, player_dist, player_lane, player_speed, car, blink_on)

	_update_headlight_lod(player_dist)
	PerfMonitor.end("traffic")

const TURN_SIGNAL_PERIOD := 0.6 # seconds per full on/off cycle
const SPRAY_MAX_DIST := 60.0 * UNIT_SCALE # traffic further than this (along the road) from the player skips rain spray

func _update_car(t: Node3D, delta: float, player_dist: float, player_lane: int, player_speed: float, car: Node3D, blink_on: bool) -> void:
	if t.control_mode == t.ControlMode.WRECKED:
		t.set_hazard_lights(blink_on)
		t.update_spray(false, 0.0)
		_check_wrecked_despawn(t, player_dist)
		return

	if t.control_mode == t.ControlMode.KNOCKED:
		t.update_spray(false, 0.0)
		if t.update_knock(delta):
			_recover_from_knock(t)
		return

	_update_lane_change(t, delta, player_dist, player_lane)
	t.update_turn_signal(t.turn_dir, blink_on)
	var follow_mul := _compute_follow_mul(t, player_dist, player_lane)
	var effective_speed: float = t.speed * follow_mul
	t.dist += delta * effective_speed
	t.spin_wheels(delta, effective_speed)
	# Distance LOD - only cars near the player spray; far-off mist is barely
	# visible but still costs a full emitter of alpha-blended overdraw.
	var spray_near: bool = absf(t.dist - player_dist) < SPRAY_MAX_DIST
	var layout := _layout()
	var dry: bool = layout != null and layout.in_tunnel(t.dist)
	t.update_spray(Weather.is_raining and spray_near and not dry, effective_speed)
	_check_recycle(t, player_dist, player_lane, player_speed)
	_drive_following(t, delta)

## Steers the real RigidBody3D toward the AI-desired transform via velocity
## (not a teleport - a real velocity, so real collisions still resolve
## correctly) - the AI's dist/x_frac/lane_yaw_offset stay the sole source
## of truth for ordinary driving, this just converts that into motion the
## physics engine actually integrates, every physics frame.
func _drive_following(t: Node3D, delta: float) -> void:
	if delta <= 0.0:
		return
	var rp := _road_path()
	if rp == null:
		return
	var f: Dictionary = rp.road_frame(t.dist)
	var desired_pos: Vector3 = rp.world_pos(t.dist, t.x_frac * RoadMetrics.ROAD_HALF_WIDTH)
	t.linear_velocity = (desired_pos - t.global_position) / delta
	t.angular_velocity = _angular_velocity_toward(t, _desired_basis(f, t.lane_yaw_offset), delta)

## Full 3D orientation (yaw from heading+lane_yaw_offset, ROLL from the
## road's own bank) - not yaw-only. The player's real car naturally rolls
## on a banked curve as a byproduct of its raycast suspension hitting the
## now-correctly-banked ground collision (see the collision-fix work) -
## traffic has no such suspension, so without this it'd glide through a
## banked curve at the right height but staying perfectly level, which
## reads as obviously wrong once the road is visibly tilted under it.
##
## Builds the banked ROAD frame first, from the raw heading/bank alone -
## right_b/up_b are exactly RoadPath.world_pos()'s own cross-section
## rotation (right0*cos(bank)+up0*sin(bank) / -right0*sin(bank)+up0*cos(bank)),
## so this rolls in lockstep with the visual mesh/ground collision by
## construction. The PI/lane_yaw_offset yaw is then applied as a SEPARATE
## rotation about that banked frame's own local Y (post-multiply, i.e. "in
## the banked frame") rather than folded into the initial Y-axis rotation -
## previously this yaw was baked in FIRST (`Basis(UP, heading+PI+offset)`)
## and the bank was rolled around THAT basis's own local Z axis, which - the
## +PI hull-facing convention doubles as making that local Z point at the
## road's BACKWARD direction here, not forward - rolled by -bank instead of
## +bank relative to the true road surface. Confirmed via a standalone
## headless numeric check (Basis columns/`.rotated()` semantics, then the
## old vs. this formula's resulting UP vector against the true road-surface
## up derived independently): the old formula's up vector was off by exactly
## 2x the bank angle (e.g. 20.6 deg misaligned on a 10.3 deg bank - a
## systematic wrong-direction roll, not a rounding error), this one lands at
## 0.000 deg in every case tested, and both formulas agree exactly at
## bank=0 (the already-verified flat-road case is unaffected).
static func _desired_basis(f: Dictionary, lane_yaw_offset: float) -> Basis:
	var heading: float = f.heading
	var bank: float = f.bank
	var forward0 := Vector3(sin(heading), 0, cos(heading))
	var right0 := Vector3(cos(heading), 0, -sin(heading))
	var up0 := Vector3(0, 1, 0)
	var right_b: Vector3 = right0 * cos(bank) + up0 * sin(bank)
	var up_b: Vector3 = -right0 * sin(bank) + up0 * cos(bank)
	var banked := Basis(right_b, up_b, forward0)
	return banked * Basis(Vector3.UP, PI + lane_yaw_offset)

## Computes the angular velocity that rotates `t` from its current
## orientation to `desired_basis` over `delta` - the rotational equivalent
## of _drive_following's own linear velocity trick (steer via velocity, not
## a teleport, so a real collision can still interrupt it). Needs
## traffic_car.gd's angular X/Z locks temporarily OFF while FOLLOWING (see
## resume_following()/enter_knocked_state()) - they're normally on to stop
## a KNOCKED/WRECKED car from tumbling chaotically, which would also block
## this deliberate, controlled roll.
static func _angular_velocity_toward(t: Node3D, desired_basis: Basis, delta: float) -> Vector3:
	var current_q: Quaternion = t.global_transform.basis.get_rotation_quaternion()
	var desired_q: Quaternion = desired_basis.get_rotation_quaternion()
	# Quaternion double-cover guard: get_rotation_quaternion() can independently
	# return q or -q for either side (both represent the same rotation) - if
	# they land on opposite hemispheres, desired_q*current_q.inverse() comes out
	# as the "long way around" (angle near 2*PI instead of near 0), and its axis
	# extraction (dividing by sqrt(1-w*w), which is ~0 right at that boundary)
	# becomes numerically unstable and returns a near-garbage axis - producing a
	# huge, essentially random one-frame angular_velocity spike. Confirmed via a
	# headless diagnostic comparing this function's target basis against the
	# real physics basis frame-by-frame: the tracking error is normally a tiny
	# <0.6 deg oscillation, but jumped to ~360 deg for several consecutive
	# frames at one branch flip - this exact bug, not a persistent lag. Forcing
	# both quaternions onto the same hemisphere before differencing always picks
	# the shortest physical rotation instead.
	if current_q.dot(desired_q) < 0.0:
		desired_q = -desired_q
	var delta_q: Quaternion = (desired_q * current_q.inverse()).normalized()
	var angle: float = delta_q.get_angle()
	if angle < 0.0001:
		return Vector3.ZERO
	return delta_q.get_axis() * (angle / delta)

## dist/x_frac -> world position uses RoadPath.world_pos()'s banked
## transform (see road_path.gd) - going the other way (a real physics
## position -> dist/x_frac, needed after a KNOCKED/WRECKED car settles
## somewhere the AI didn't put it) means inverting that. `dist` comes from
## a throwaway PathTracker search seeded at the car's last known dist
## (close enough to seed the search window correctly, since knockback
## distances are far smaller than the search window); `x_frac` comes from
## projecting the real position onto the road frame's own right vector at
## that dist, undoing the `cos(bank)` scale world_pos applies.
func _estimate_dist_and_lateral(t: Node3D, seed_dist: float) -> Dictionary:
	var rp := _road_path()
	if rp == null:
		return {"dist": seed_dist, "lateral": 0.0}
	var tracker := PathTracker.new(rp, seed_dist)
	var dist: float = tracker.update(t.global_position)
	dist = clampf(dist, 0.0, rp.total_length())
	var lateral: float = _lateral_offset(dist, t.global_position)
	return {"dist": dist, "lateral": lateral}

## Called once the knock window ends (traffic_car.gd's update_knock() -
## timer elapsed or it settled early) - re-syncs AI state FROM wherever
## physics left the car, so it just re-enters traffic flow from there. No
## special-casing needed since this reuses the exact fields the AI already
## understands; _lane_front gap-tracking is only touched at spawn time (see
## _required_center), not by ongoing following, so it doesn't need
## resyncing here.
func _recover_from_knock(t: Node3D) -> void:
	var est: Dictionary = _estimate_dist_and_lateral(t, t.dist)
	t.dist = est.dist
	t.x_frac = clampf(est.lateral / RoadMetrics.ROAD_HALF_WIDTH, -1.0, 1.0)
	t.lane = RoadMetrics.x_to_lane(est.lateral)
	t.turn_dir = 0
	t.changing_lanes = false
	t.lane_yaw_offset = 0.0
	t.linear_velocity = Vector3.ZERO
	t.angular_velocity = Vector3.ZERO
	t.resume_following()

## WRECKED cars never call _check_recycle (their `dist` is frozen from the
## moment of the crash, not a valid stand-in for where they actually are),
## so this is the position-based equivalent - once the player has driven
## far enough past wherever the wreck actually settled, recycle it back
## into normal traffic via the same spawn placement everything else uses
## (which also calls resume_following() via _reset_car_state, clearing the
## WRECKED state and collision mask). Re-estimates the wreck's real `dist`
## the same way recovery does (its own `t.dist` field is frozen/stale), but
## only for this comparison - doesn't write it back, that's recovery's job.
func _check_wrecked_despawn(t: Node3D, player_dist: float) -> void:
	var est: Dictionary = _estimate_dist_and_lateral(t, t.dist)
	if est.dist - player_dist >= -DESPAWN_BEHIND:
		return
	if GameState.current != GameState.State.PLAYING:
		return
	_place_traffic_car(t, SPAWN_AHEAD_MIN, SPAWN_AHEAD_MAX, player_dist)

const MAX_ACTIVE_TRAFFIC_LIGHTS := 6
const TRAFFIC_LIGHT_LOD_RADIUS := 55.0 * UNIT_SCALE

## Distance-based light LOD: only the closest few traffic cars to the
## player (by road distance, ahead or behind) get a real headlight -
## `traffic_car.gd`'s set_real_headlights_enabled() lazily builds the real
## SpotLight3Ds on first enable and just toggles visibility after, so a car
## crossing the radius back and forth doesn't repeatedly rebuild nodes.
## Small `_cars` pool (35) makes a plain sort-every-frame fine here - no
## need to throttle.
func _update_headlight_lod(player_dist: float) -> void:
	var candidates: Array = []
	for t in _cars:
		var d: float = absf(t.dist - player_dist)
		if d < TRAFFIC_LIGHT_LOD_RADIUS:
			candidates.append({"car": t, "d": d})
	candidates.sort_custom(func(a, b): return a.d < b.d)
	var lit := {}
	for i in range(mini(MAX_ACTIVE_TRAFFIC_LIGHTS, candidates.size())):
		lit[candidates[i].car] = true
	for t in _cars:
		t.set_real_headlights_enabled(lit.has(t))

func _update_lane_change(t: Node3D, delta: float, player_dist: float, player_lane: int) -> void:
	if t.turn_dir == 0 and not t.changing_lanes and not _lane_usable(t.lane, t.dist):
		_try_merge(t, player_dist, player_lane)
		return
	if t.turn_dir == 0 and not t.changing_lanes:
		if _rng.randf() < LANE_CHANGE_CHANCE * delta:
			var dir: int = 1 if _rng.randf() < 0.5 else -1
			var target: int = t.lane + dir
			if _lane_usable(target, t.dist) \
					and _lane_clear_at(t.dist, t, target, GAP_DIST * 0.9, GAP_DIST * 0.6, player_dist, player_lane) \
					and _gap_lane_for_dist(t.dist) != target:
				t.turn_dir = dir
				t.pending_lane = target
				t.signal_timer = SIGNAL_DURATION
	elif t.turn_dir != 0 and not t.changing_lanes:
		t.signal_timer -= delta
		if t.signal_timer <= 0.0:
			t.changing_lanes = true
			t.change_from_x = t.x_frac
			t.change_to_x = RoadMetrics.lane_to_frac(t.pending_lane)
			t.change_progress = 0.0
			t.lane = t.pending_lane
	elif t.changing_lanes:
		t.change_progress += delta / LANE_CHANGE_DURATION
		var ep: float = clampf(t.change_progress, 0.0, 1.0)
		var eased: float = 2.0 * ep * ep if ep < 0.5 else 1.0 - pow(-2.0 * ep + 2.0, 2) / 2.0
		t.x_frac = lerpf(t.change_from_x, t.change_to_x, eased)
		t.lane_yaw_offset = signf(t.turn_dir) * TRAFFIC_LANE_YAW_MAX * sin(minf(1.0, ep) * PI)
		if t.change_progress >= 1.0:
			t.x_frac = t.change_to_x
			t.changing_lanes = false
			t.turn_dir = 0
			t.signal_timer = 0.0
			t.lane_yaw_offset = 0.0

## The car's lane closes ahead: signal toward the right (lower lanes stay
## open) once there's a gap - or regardless when the barrier is close.
## The normal signal/change branches of _update_lane_change take it from there.
func _try_merge(t: Node3D, player_dist: float, player_lane: int) -> void:
	var target: int = t.lane - 1 # one lane at a time; a two-lane closure just repeats this
	if target < 0:
		return
	var layout := _layout()
	var hard: float = layout.lane_hard_end(t.lane, t.dist, MERGE_LOOKAHEAD) if layout else INF
	var urgent: bool = hard - t.dist < MERGE_URGENT_DIST
	if urgent or _lane_clear_at(t.dist, t, target, GAP_DIST * 0.6, GAP_DIST * 0.4, player_dist, player_lane):
		t.turn_dir = target - t.lane
		t.pending_lane = target
		t.signal_timer = MERGE_SIGNAL_TIME

func _compute_follow_mul(t: Node3D, player_dist: float, player_lane: int) -> float:
	var lead_gap: float = INF
	var lead_half_len: float = 0.0
	# A lane that's closing ahead acts like a stopped car where its barrier
	# starts coming in, so a car that hasn't found a gap yet slows for it.
	var layout := _layout()
	if layout and not t.changing_lanes:
		var hard: float = layout.lane_hard_end(t.lane, t.dist, MERGE_LOOKAHEAD)
		if hard < INF and hard - t.dist > 0.0:
			lead_gap = hard - t.dist

	for other in _cars:
		if other == t or other.lane != t.lane:
			continue
		var d: float = other.dist - t.dist
		if d > 0.0 and d < lead_gap:
			lead_gap = d
			lead_half_len = other.half_len
	if player_lane == t.lane:
		var d: float = player_dist - t.dist
		if d > 0.0 and d < lead_gap:
			lead_gap = d
			lead_half_len = PLAYER_HALF_LEN
	if lead_gap == INF:
		return 1.0
	var desired: float = GAP_DIST * 0.85 + t.half_len + lead_half_len
	if lead_gap < desired * 0.55:
		return 0.15
	elif lead_gap < desired:
		return 0.15 + 0.85 * ((lead_gap - desired * 0.55) / (desired * 0.45))
	return 1.0

func _check_recycle(t: Node3D, player_dist: float, player_lane: int, player_speed: float) -> void:
	var dz: float = t.dist - player_dist
	if dz >= -DESPAWN_BEHIND and dz <= SPAWN_AHEAD_MAX + 40.0 * UNIT_SCALE:
		return
	if GameState.current != GameState.State.PLAYING:
		return # crash sequence in progress - let it keep drifting, don't respawn

	var now: float = Time.get_ticks_msec() / 1000.0
	if player_speed < IDLE_SPEED_THRESHOLD and (now - _last_spawn_time) < IDLE_SPAWN_INTERVAL:
		_place_traffic_car(t, SPAWN_AHEAD_MAX * 2.0, SPAWN_AHEAD_MAX * 2.0 + 40.0 * UNIT_SCALE, player_dist)
		return

	var behind_chance: float = BEHIND_SPAWN_CHANCE_IDLE if player_speed < IDLE_SPEED_THRESHOLD else BEHIND_SPAWN_CHANCE
	if _rng.randf() < behind_chance and _place_traffic_car_behind(t, player_dist, player_lane):
		pass
	else:
		_place_traffic_car(t, SPAWN_AHEAD_MIN, SPAWN_AHEAD_MAX, player_dist)
	_last_spawn_time = now

## One-time direct teleport, used ONLY at spawn/recycle (via
## _reset_car_state) - not called every frame anymore, that's
## _drive_following()'s job now (a real velocity, not a teleport, so real
## collisions keep working). An occasional teleport like this is fine for a
## physics body; continuously teleporting every frame is the anti-pattern
## that would have broken collision response.
func _render_car(t: Node3D) -> void:
	var rp := _road_path()
	if rp == null:
		t.position = Vector3(t.x_frac * RoadMetrics.ROAD_HALF_WIDTH, 0.0, t.dist)
		t.rotation.y = PI + t.lane_yaw_offset
	else:
		var f: Dictionary = rp.road_frame(t.dist)
		t.position = rp.world_pos(t.dist, t.x_frac * RoadMetrics.ROAD_HALF_WIDTH)
		t.basis = _desired_basis(f, t.lane_yaw_offset) # yaw + bank roll, see _drive_following's own notes
	t.linear_velocity = Vector3.ZERO
	t.angular_velocity = Vector3.ZERO

## --- Spawn placement -------------------------------------------------

func _required_center(lane: int, player_dist: float, half_len: float) -> float:
	# Regression A: only ever touches _lane_front[lane] - never a cross-lane value.
	if _lane_front[lane] < player_dist:
		_lane_front[lane] = player_dist + SPAWN_AHEAD_MIN - GAP_DIST + lane * GAP_DIST * 0.4
	return _lane_front[lane] + GAP_DIST + half_len

func _place_traffic_car(t: Node3D, ahead_min: float, ahead_max: float, player_dist: float) -> void:
	var start_lane: int = _rng.randi_range(0, LANES - 1)
	var candidate_base: float = player_dist + ahead_min + _rng.randf() * (ahead_max - ahead_min)

	var best_lane: int = -1
	var best_dist: float = 0.0
	var best_req: float = INF
	for i in range(LANES):
		var lane: int = (start_lane + i) % LANES
		var req: float = _required_center(lane, player_dist, t.half_len)
		var cand_dist: float = maxf(candidate_base, req)
		if _gap_lane_for_dist(cand_dist) == lane or not _lane_usable(lane, cand_dist):
			continue
		if req < best_req:
			best_req = req
			best_lane = lane
			best_dist = cand_dist

	if best_lane == -1:
		# Every lane's natural slot landed in its own gap-lane this band (or a
		# closing lane) - nudge forward.
		best_lane = _rng.randi_range(0, _usable_lanes(candidate_base) - 1)
		best_dist = maxf(candidate_base, _required_center(best_lane, player_dist, t.half_len))
		var guard := 0
		while _gap_lane_for_dist(best_dist) == best_lane and guard < 64:
			best_dist += GAP_SEGMENT_LENGTH
			guard += 1

	# Regression B: this clamp is UNCONDITIONAL. Do not make it conditional
	# on "would it break the gap" - that's the exact change that caused every
	# traffic car to drift to +infinity over a long play session.
	best_dist = minf(best_dist, player_dist + ahead_max + GAP_SEGMENT_LENGTH)

	_lane_front[best_lane] = best_dist + t.half_len
	_reset_car_state(t, best_dist, best_lane)

func _place_traffic_car_behind(t: Node3D, player_dist: float, player_lane: int) -> bool:
	for _attempt in range(8):
		var lane: int = _rng.randi_range(0, LANES - 1)
		if lane == player_lane:
			continue
		var dist: float = player_dist - (SPAWN_BEHIND_MIN + _rng.randf() * (SPAWN_BEHIND_MAX - SPAWN_BEHIND_MIN))
		if _lane_usable(lane, dist) and _lane_clear_at(dist, t, lane, GAP_DIST * 0.6, GAP_DIST * 0.6, player_dist, player_lane):
			_reset_car_state(t, dist, lane)
			return true
	return false

func _reset_car_state(t: Node3D, dist: float, lane: int) -> void:
	t.dist = dist
	t.lane = lane
	t.x_frac = RoadMetrics.lane_to_frac(lane)
	t.speed = _base_speed() * (0.94 + _rng.randf() * 0.12)
	t.turn_dir = 0
	t.pending_lane = lane
	t.changing_lanes = false
	t.signal_timer = 0.0
	t.change_progress = 0.0
	t.lane_yaw_offset = 0.0
	t.near_best = -1
	t.near_paid = -1
	t.was_ahead = false
	t.overtaken = false
	t.slipstreamed = false
	t.resume_following() # defensive - normal flow never recycles a KNOCKED car (see _update_car)
	_render_car(t) # one-time teleport to the new spawn transform, see _render_car's own note

func _base_speed() -> float:
	# No direct equivalent of Voxel Driver's "maxSpeed" (a game-speed model
	# constant) exists on g-rcp2's real-physics car - picking a flat highway
	# cruising speed instead: ~27 m/s (~97 km/h) converted to this project's units.
	return 27.0 * UNIT_SCALE

## Dev console "Zero traffic". Disabling pulls every pooled car out of the
## tree (the pool itself is kept); enabling puts them back and re-places them
## around the player exactly like a fresh run does.
func set_enabled(on: bool) -> void:
	if on == enabled:
		return
	enabled = on
	for t in _cars:
		if on:
			add_child(t)
		else:
			remove_child(t)
	if on:
		reset_traffic()

## Horn / headlight flash (horn.gd) - port of the original's
## attemptTrafficYield() (Voxel Driver input.js): the nearest car ahead in the
## player's lane within `reach` signals and moves over to whichever
## neighbouring lane is clear (+1 first, then -1). Cars already signalling,
## changing lanes, knocked or wrecked ignore it. `lane` is already the target
## lane once a change is under way, which is what the original's
## xToLane(changeToX) looked up. Returns true if a car agreed to move.
const YIELD_SIGNAL_TIME := 0.5 # quicker than an idle lane change's SIGNAL_DURATION - it's being told to

func request_yield(reach: float) -> bool:
	if not enabled:
		return false
	var car: Node3D = get_node_or_null(car_path)
	if car == null:
		return false
	var player_dist: float = _player_dist()
	var player_lane: int = RoadMetrics.x_to_lane(_lateral_offset(player_dist, car.global_position))
	var lead: Node3D = null
	var best_gap := reach
	for t in _cars:
		if t.lane != player_lane:
			continue
		var gap: float = t.dist - player_dist
		if gap > 0.0 and gap < best_gap:
			best_gap = gap
			lead = t
	if lead == null or lead.control_mode != lead.ControlMode.FOLLOWING or lead.changing_lanes or lead.turn_dir != 0:
		return false
	for dir in [1, -1]:
		var target: int = lead.lane + dir
		if not _lane_usable(target, lead.dist):
			continue
		if _lane_clear_at(lead.dist, lead, target, GAP_DIST * 0.8, GAP_DIST * 0.5, player_dist, player_lane):
			lead.turn_dir = dir
			lead.pending_lane = target
			lead.signal_timer = YIELD_SIGNAL_TIME
			return true
	return false

## --- Shared queries ---------------------------------------------------

func _lane_clear_at(ref_dist: float, exclude: Node3D, lane: int, gap_ahead: float, gap_behind: float, player_dist: float, player_lane: int) -> bool:
	for other in _cars:
		if other == exclude or other.lane != lane:
			continue
		var d: float = other.dist - ref_dist
		if d >= 0.0 and d < gap_ahead:
			return false
		if d < 0.0 and -d < gap_behind:
			return false
	if player_lane == lane:
		var d: float = player_dist - ref_dist
		if d >= 0.0 and d < gap_ahead:
			return false
		if d < 0.0 and -d < gap_behind:
			return false
	return true

## The random-walk gap lane is planned over all LANES; where fewer are open it
## squeezes into the outermost open one so there's still always a way through.
func _gap_lane_for_dist(dist: float) -> int:
	var band: int = int(floor(dist / GAP_SEGMENT_LENGTH))
	var lane: int = _gap_lane_for_band(maxi(band, 0))
	var layout := _layout()
	if layout:
		lane = mini(lane, layout.open_lanes_at(dist) - 1)
	return lane

func _gap_lane_for_band(band: int) -> int:
	if _gap_lane_segments.has(band):
		return _gap_lane_segments[band]
	if band <= 0:
		var lane0: int = _rng.randi_range(0, LANES - 1)
		_gap_lane_segments[0] = lane0
		return lane0
	var prev: int = _gap_lane_for_band(band - 1)
	var dir: int = -1 if _rng.randf() < 0.5 else 1
	var next_lane: int = prev + dir
	if next_lane < 0 or next_lane >= LANES:
		next_lane = prev - dir
	_gap_lane_segments[band] = next_lane
	return next_lane

func _pick_kind() -> Dictionary:
	var r: float = _rng.randf()
	var acc: float = 0.0
	for k in KINDS:
		acc += k.weight
		if r <= acc:
			return k
	return KINDS[-1]
