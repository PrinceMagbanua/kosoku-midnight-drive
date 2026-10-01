class_name SlipstreamScorer
extends Node

## Slipstream. Tuck in behind a traffic car - in line with it (within
## POCKET_FRAC of the two cars' combined half-widths), its tail no more than
## DRAFT_RANGE ahead, at MIN_SPEED_KMH or more - and a charge builds 0..1 over
## CHARGE_TIME. Swing out SIDEWAYS with at least MIN_BOOST_CHARGE and it's a
## slingshot: RiskEvents.slipstream_boost(charge) (boost_burst.gd turns that
## into speed) plus a "SLINGSHOT" combo event sized by the charge.
##
## Leaving the pocket any other way - braking out of range, the lead car
## pulling away, dropping under the min speed, hitting it - pays nothing: the
## charge is kept for GRACE_TIME in case the player drifts straight back in,
## then dropped.
##
## While drafting, every TICK_TIME seconds pays a small "SLIPSTREAM" event that
## keeps the chain alive without raising the combo streak (same anti-farm rule
## as HighSpeedScorer), and the seconds go to RunRewards.add_time("slipstream")
## for the crash screen.
##
## One slingshot per traffic car (`slipstreamed` on traffic_car.gd, cleared
## when the car is recycled) - a car that already paid can't be drafted again.
##
## The charging visual is SlipstreamFx, a child of this node.

const MIN_SPEED_KMH := 80.0
const DRAFT_RANGE := 14.0 * RoadMetrics.UNIT_SCALE # bumper-to-bumper gap, 14 m
const POCKET_FRAC := 0.6 # lateral offset allowed, share of the combined half-widths
const CHARGE_TIME := 1.2 # seconds in the pocket for a full charge
const MIN_BOOST_CHARGE := 0.5
const GRACE_TIME := 0.3
const TICK_TIME := 1.0
const TICK_POINTS := 10.0
const SLINGSHOT_POINTS := 40.0 # at full charge
const KPH_PER_UNIT_SPEED := 1.10130592 # same conversion live_hud.gd uses

@export var car_path: NodePath = NodePath("../car")
@export var traffic_manager_path: NodePath = NodePath("../TrafficManager")

var active := false
var charge := 0.0
var held := 0.0 # seconds drafted this session
var _lead: Node3D
var _grace := 0.0
var _next_tick := TICK_TIME
var _fx: SlipstreamFx
# Cached targets of the paths above (looked up again only if they go away).
var _car: RigidBody3D
var _traffic: Node

func _ready() -> void:
	_fx = SlipstreamFx.new()
	_fx.name = "SlipstreamFx"
	add_child(_fx)
	GameState.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state == GameState.State.PAUSED or (new_state == GameState.State.PLAYING and old_state == GameState.State.PAUSED):
		return
	_end()

func _physics_process(delta: float) -> void:
	if GameState.current != GameState.State.PLAYING or IntroPan.playing:
		return
	if not is_instance_valid(_car):
		_car = get_node_or_null(car_path) as RigidBody3D
	if not is_instance_valid(_traffic):
		_traffic = get_node_or_null(traffic_manager_path)
	var car := _car
	var tm := _traffic
	if car == null or tm == null or not tm.enabled:
		_end()
		return

	var speed: float = car.linear_velocity.length()
	var fast_enough := speed * KPH_PER_UNIT_SPEED >= MIN_SPEED_KMH
	var lead: Node3D = _find_lead(car, tm) if fast_enough else null
	if lead == null:
		_left_pocket(car, fast_enough, speed, delta)
		return

	if lead != _lead:
		# Swung out of one pocket straight into the next lane's: still a slingshot.
		if active and charge >= MIN_BOOST_CHARGE and _swung_out(car):
			_slingshot(speed)
		_lead = lead
		charge = 0.0 # a different car - its pocket charges from scratch
	if not active:
		active = true
		held = 0.0
		_next_tick = TICK_TIME
		RunRewards.slipstream_active = true
	_grace = 0.0
	charge = minf(charge + delta / CHARGE_TIME, 1.0)
	held += delta
	RunRewards.add_time("slipstream", delta)
	if held >= _next_tick:
		_next_tick += TICK_TIME
		RunRewards.register_score_event(TICK_POINTS, speed / CrashSystem.REFERENCE_MAX_SPEED, "SLIPSTREAM", false)
	_fx.set_draft(car, lead, charge)
	RiskEvents.slipstream_updated.emit(charge, held)

## Not in anyone's pocket this tick. If the player swung out sideways from a
## charged draft it's a slingshot; otherwise the session ends after the grace.
func _left_pocket(car: RigidBody3D, fast_enough: bool, speed: float, delta: float) -> void:
	if not active:
		return
	if fast_enough and charge >= MIN_BOOST_CHARGE and _swung_out(car):
		_slingshot(speed)
		_end()
		return
	_grace += delta
	if _grace >= GRACE_TIME:
		_end()

## Pays out the current charge and retires the lead car.
func _slingshot(speed: float) -> void:
	_lead.slipstreamed = true
	RiskEvents.slipstream_boost.emit(charge)
	RunRewards.register_score_event(SLINGSHOT_POINTS * charge, speed / CrashSystem.REFERENCE_MAX_SPEED, "SLINGSHOT")

## The car to draft: the current lead while it still qualifies, else the
## nearest one the player is lined up behind.
func _find_lead(car: RigidBody3D, tm: Node) -> Node3D:
	if is_instance_valid(_lead) and _in_pocket(car, _lead):
		return _lead
	var best: Node3D = null
	var best_gap := INF
	for t in tm._cars:
		if not _in_pocket(car, t):
			continue
		var gap := _bumper_gap(car, t)
		if gap < best_gap:
			best_gap = gap
			best = t
	return best

func _half_w(car: Node3D) -> float:
	return CrashSystem.PLAYER_HALF_W * float(car.get_meta("hull_w_scale", 1.0))

func _half_l(car: Node3D) -> float:
	return CrashSystem.PLAYER_HALF_L * float(car.get_meta("hull_l_scale", 1.0))

## Gap from the player's nose to `t`'s tail (negative = overlapping lengthwise).
func _bumper_gap(car: Node3D, t: Node3D) -> float:
	return CrashSystem.player_frame_offset(car, t).y - (_half_l(car) + t.half_len)

func _drivable(t: Node3D) -> bool:
	return t.is_inside_tree() and t.control_mode == t.ControlMode.FOLLOWING and not t.slipstreamed

func _in_pocket(car: Node3D, t: Node3D) -> bool:
	if not _drivable(t):
		return false
	var offset := CrashSystem.player_frame_offset(car, t)
	if not offset.is_finite():
		return false
	var gap: float = offset.y - (_half_l(car) + t.half_len)
	if gap < 0.0 or gap > DRAFT_RANGE:
		return false
	return absf(offset.x) <= POCKET_FRAC * (_half_w(car) + t.half_w)

## True when the player left the lead car's pocket to the SIDE: the car is
## still driving, still ahead or alongside and within range, just no longer
## in line.
func _swung_out(car: Node3D) -> bool:
	if not is_instance_valid(_lead) or not _drivable(_lead):
		return false
	var offset := CrashSystem.player_frame_offset(car, _lead)
	if not offset.is_finite():
		return false
	var gap: float = offset.y - (_half_l(car) + _lead.half_len)
	if gap > DRAFT_RANGE or offset.y < 0.0:
		return false
	return absf(offset.x) > POCKET_FRAC * (_half_w(car) + _lead.half_w)

func _end() -> void:
	RunRewards.slipstream_active = false
	_lead = null
	charge = 0.0
	_grace = 0.0
	if _fx:
		_fx.clear_draft()
	if not active:
		return
	active = false
	held = 0.0
	RiskEvents.slipstream_ended.emit()
