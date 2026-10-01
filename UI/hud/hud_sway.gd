class_name HudSway
extends Node

## Makes the HUD feel mounted in a moving car: each HUD group lags against
## the player car's G-forces on a critically-damped spring, and jolts with
## the camera shake (impacts, and the rev rumble during the start pan). Groups move by different amounts (`depths`), so
## the big speedometer drifts most and the top-left text least - parallax
## that reads as depth. Buttons live in a group with depth 0 (never move).
##
## Direction: cornering right slides the HUD left (it "stays behind"),
## braking lifts it, accelerating sinks it. Flip the signs of PX_PER_G to
## invert.
##
## G-force comes from the car's velocity change per PHYSICS step (sim time),
## so slow-mo doesn't read as a huge deceleration. The spring runs on real
## time. Off (eases back to still) when misc_graphics_settings.hud_sway is
## false or outside PLAYING.

const G := 9.81
const PX_PER_G := Vector2(-11.0, 9.0) # x: lateral, y: longitudinal
const MAX_PX := 10.0
const STIFFNESS := 60.0 # spring k; critically damped, ~0.25s to settle
const ACCEL_SMOOTHING := 10.0 # low-pass on the raw per-step acceleration
const SPIKE_G := 6.0 # a velocity jump bigger than this is a teleport/reset - ignored
const JOLT_PX := 9.0 # at full camera shake (CameraShake.get_hud_shake)
const JOLT_FREQUENCY := 18.0

## Paths to the HUD groups this moves, each with its parallax depth.
@export var groups: Array[NodePath] = []
@export var depths: Array[float] = []
## Set by live_hud.gd (it already finds the CrashSystem).
var crash_system: Node

var _car: RigidBody3D
var _prev_velocity := Vector3.ZERO
var _g := Vector2.ZERO # smoothed (lateral, longitudinal) in G
var _offset := Vector2.ZERO
var _offset_velocity := Vector2.ZERO
var _time := 0.0
var _noise := FastNoiseLite.new()

func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.0 # so JOLT_FREQUENCY is wiggles per second (the default 0.01 is a slow drift)

func _physics_process(delta: float) -> void:
	if not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("player_car") as RigidBody3D
		if _car == null:
			return
		_prev_velocity = _car.linear_velocity
	var v := _car.linear_velocity
	var accel := (v - _prev_velocity) / maxf(delta, 0.0001) / RoadMetrics.UNIT_SCALE / G
	_prev_velocity = v
	if accel.length() > SPIKE_G:
		return
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var right := cam.global_basis.x
	var forward := -cam.global_basis.z
	forward.y = 0.0
	forward = forward.normalized()
	var raw := Vector2(accel.dot(right), accel.dot(forward))
	_g = _g.lerp(raw, 1.0 - exp(-ACCEL_SMOOTHING * delta))

func _process(delta: float) -> void:
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	var active: bool = misc_graphics_settings.hud_sway and GameState.current in [GameState.State.PLAYING, GameState.State.CRASHING]
	# DevConsole.hud_sway: tuning multiplier (dev console slider) on the lean and its cap.
	var target := (_g * PX_PER_G * DevConsole.hud_sway).limit_length(MAX_PX * DevConsole.hud_sway) if active else Vector2.ZERO

	# Critically damped spring (semi-implicit Euler, real time).
	var k := STIFFNESS
	_offset_velocity += ((target - _offset) * k - _offset_velocity * 2.0 * sqrt(k)) * real_delta
	_offset += _offset_velocity * real_delta

	var jolt := Vector2.ZERO
	if active:
		if is_instance_valid(crash_system):
			var shake: float = crash_system.get_hud_shake()
			if shake > 0.0:
				_time += real_delta * JOLT_FREQUENCY
				jolt = Vector2(_noise.get_noise_2d(_time, 0.0), _noise.get_noise_2d(0.0, _time)) * JOLT_PX * shake

	for i in groups.size():
		var group := get_node_or_null(groups[i]) as Control
		if group:
			var depth: float = depths[i] if i < depths.size() else 1.0
			group.position = (_offset + jolt) * depth
