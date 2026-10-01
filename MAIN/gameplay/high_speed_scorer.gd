class_name HighSpeedScorer
extends Node

## "TOP SPEED" scoring - holding the car at its own top end: top gear with
## the revs at or above TOP_SPEED_RPM_FRAC of the limiter (so it's relative to
## each car and its upgrades, not a fixed km/h). Every TICK_TIME seconds held
## pays one combo event (TICK_POINTS base, through
## RunRewards.register_score_event, so speed factor / combo multiplier /
## nitro all apply). Dropping out of it ends the session. The seconds held
## also go to RunRewards.add_time("top_speed") for the crash screen.
##
## Anti-farm: these ticks add points and keep the chain alive (the chain timer
## is held while a session is live, like a drift) but do NOT raise the combo
## streak - otherwise just cruising on an empty road would climb to the
## COMBO_CAP multiplier on its own. The multiplier still has to come from
## risk (near-misses, overtakes, drifts, MOVE!).

const TOP_SPEED_RPM_FRAC := 0.92 # of car.gd's RPMLimit, in top gear
const TICK_TIME := 3.0
const TICK_POINTS := 10.0

@export var car_path: NodePath = NodePath("../car")

var active := false
var held := 0.0 # seconds held this session
var _next_tick := TICK_TIME
var _car: RigidBody3D # cached car_path target (looked up again only if it goes away)

func _ready() -> void:
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
	var car := _car
	if car == null:
		return
	var speed: float = car.linear_velocity.length()
	if not at_top_speed(car):
		_end()
		return
	if not active:
		active = true
		held = 0.0
		_next_tick = TICK_TIME
		RunRewards.high_speed_active = true
	held += delta
	RunRewards.add_time("top_speed", delta)
	if held >= _next_tick:
		_next_tick += TICK_TIME
		RunRewards.register_score_event(TICK_POINTS, speed / CrashSystem.REFERENCE_MAX_SPEED, "TOP SPEED", false)
	RiskEvents.high_speed_updated.emit(held)

## `car` is car.gd's RigidBody3D (untyped so its script vars resolve).
static func at_top_speed(car) -> bool:
	return car.gear == car.GearRatios.size() and car.rpm >= car.RPMLimit * TOP_SPEED_RPM_FRAC

func _end() -> void:
	RunRewards.high_speed_active = false
	if not active:
		return
	active = false
	held = 0.0
	RiskEvents.high_speed_ended.emit()
