extends CanvasLayer

## Full-screen speed-up blur, driven by the player car's own speed - reads
## the RigidBody3D tagged "player_car" (same group RunRewards/CrashSystem
## already use to find it) rather than a NodePath, so this works regardless
## of where `car` sits in world.tscn. Intensity also gets an extra push
## while nitro_boost.gd's "nitro" input action is held, so a nitro burst
## visibly kicks the blur harder than plain speed alone would.
##
## `layer = -10` (SpeedBlur.tscn) is load-bearing, not arbitrary: this rect
## samples SCREEN_TEXTURE (whatever has already been drawn), so it must draw
## before ANY UI or the UI ends up baked into the blurred result. The debug
## tachometer HUD (MISC/debugger.tscn) is a plain Control with no CanvasLayer
## of its own, so it sits at the default layer 0 - this has to render before
## that (and before LiveHud at layer 3, and the menu screens at layer 4+) to
## keep the odometer/gear-menu/score readouts sharp and only blur the 3D
## world behind them.

const MIN_SPEED_KMH := 100.0 # blur starts fading in above this
const MAX_SPEED_KMH := 300.0 # blur reaches full intensity at/above this
const SPEED_TO_KMH := 1.10130592 # same conversion debug.gd's speedo uses
const SMOOTH_RATE := 4.0 # exponential smoothing, avoids a jittery blur
const NITRO_BOOST := 0.2 # extra intensity added on top while nitro is held

## Crash desaturation: during CRASHING the world fades to CRASH_SATURATION
## over CrashSystem.CRASH_SLOWMO_DURATION (real seconds), so it lands fully
## black-and-white right as the crash popup appears. Stays that way behind
## the popup (tree is paused there, so _process stops and the value holds),
## and snaps back to full color on leaving CRASHED.
const CRASH_SATURATION := 0.1

@onready var _rect: ColorRect = $Rect

var _car: RigidBody3D
var _nitro: Node
var _burst: Node
var _intensity := 0.0
var _crash_fade := 0.0 # 0 = full color, 1 = fully desaturated

## camera_shake.gd finds this node through the group to shake the image.
const SHAKE_GROUP := "screen_shake"

func _ready() -> void:
	add_to_group(SHAKE_GROUP)
	GameState.state_changed.connect(_on_state_changed)
	var cars := get_tree().get_nodes_in_group("player_car")
	if not cars.is_empty():
		_car = cars[0]
		_nitro = _car.get_node_or_null(NodePath("NitroBoost"))
		_burst = _car.get_node_or_null(NodePath("BoostBurst"))

func _process(delta: float) -> void:
	if _car == null:
		var cars := get_tree().get_nodes_in_group("player_car")
		if cars.is_empty():
			return
		_car = cars[0]
		_nitro = _car.get_node_or_null(NodePath("NitroBoost"))
		_burst = _car.get_node_or_null(NodePath("BoostBurst"))

	var speed_kmh: float = _car.linear_velocity.length() * SPEED_TO_KMH
	var target: float = clampf(inverse_lerp(MIN_SPEED_KMH, MAX_SPEED_KMH, speed_kmh), 0.0, 1.0)
	# Reads the actual eased power (which is 0 once the tank is empty), not
	# raw input - otherwise mashing an empty nitro tank would still kick the
	# blur even though nothing is actually boosting.
	# A boost burst (boost_burst.gd) kicks it the same way.
	if (_nitro and _nitro.get_power() > 0.0) or (_burst and _burst.get_power() > 0.0):
		target = clampf(target + NITRO_BOOST, 0.0, 1.0)

	_intensity += (target - _intensity) * clampf(SMOOTH_RATE * delta, 0.0, 1.0)
	_rect.material.set_shader_parameter("intensity", _intensity)

	if GameState.current == GameState.State.CRASHING:
		# `delta` is scaled by the crash slow-mo; undo that so the fade runs
		# on the same real-time clock as crash_system.gd's own timer.
		var real_delta := delta / maxf(Engine.time_scale, 0.001)
		_crash_fade = minf(_crash_fade + real_delta / CrashSystem.CRASH_SLOWMO_DURATION, 1.0)
		_apply_saturation()

func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	if new_state == GameState.State.CRASHED:
		_crash_fade = 1.0
	elif new_state != GameState.State.CRASHING:
		_crash_fade = 0.0
	_apply_saturation()

## Camera shake: shifts the whole 3D image by `offset` (fractions of the screen
## height, both axes). `margin` is the largest shift possible right now (see
## the shader's shake_margin). Everything above this layer - the HUD - stays put.
func set_shake(offset: Vector2, margin: float) -> void:
	_rect.material.set_shader_parameter("shake", offset)
	_rect.material.set_shader_parameter("shake_margin", margin)

func _apply_saturation() -> void:
	var eased := smoothstep(0.0, 1.0, _crash_fade)
	_rect.material.set_shader_parameter("saturation", lerpf(1.0, CRASH_SATURATION, eased))
