class_name CameraShake
extends Node

## Impact camera shake ("trauma" style): shake(intensity) adds trauma 0..1,
## the offset is MAX_OFFSET * trauma^2 of smooth noise, and trauma decays at
## DECAY per real second - so a hard hit shakes hard and settles fast, and
## small ones barely register. Runs on real time, so it reads the same under
## slow-mo.
##
## The shake moves the whole rendered 3D image (speed_blur.gd's full-screen
## pass, set_shake), not the Camera3D. Shifting the camera itself moves near
## things on screen far more than distant ones, so the car appeared to vibrate
## against a still world; shifting the image moves everything together, which
## is what a shaking camera looks like. It also never touches the chase /
## cockpit / intro camera transforms, and the HUD (drawn above that pass) has
## its own jolt in hud_sway.gd. All offsets are fractions of the screen height.
##
## Rev rumble: a second, continuous channel (not trauma - it doesn't decay)
## for revving in Neutral during the start cinematic (IntroPan.playing). It
## builds from REV_START of the rev range up to the limiter, gets an extra kick
## while bouncing off the limiter, and eases out when the pan hands over.
##
## Speed shake: a third, continuous channel while driving. Nothing below
## SHAKE_MIN_KMH, building to SPEED_MAX_OFFSET at SHAKE_MAX_KMH or at the car's
## own top speed (whichever comes first), with an extra kick while nitro or a
## boost burst is pushing. Scaled by DevConsole.speed_shake
## (a dev console slider, for tuning). It doesn't feed get_hud_shake() - the
## HUD stays steady and readable at speed.

const MAX_OFFSET := 0.022 # of the screen height at full trauma
const FREQUENCY := 22.0 # noise samples per real second
const DECAY := 1.6 # trauma lost per real second

const REV_MAX_OFFSET := 0.0035 # of the screen height at the limiter
const REV_FREQUENCY := 34.0 # buzzier than an impact
const REV_START := 0.3 # fraction of idle..limit where the rumble begins
const REV_LIMITER_AT := 0.96 # above this fraction the engine is on the limiter
const REV_LIMITER_KICK := 0.35
const REV_SMOOTHING := 8.0 # how fast the rumble follows the revs
const REV_HUD_SCALE := 0.45 # rumble's share of the HUD jolt (see get_hud_shake)

## Speed range camera.gd's speed zoom-out runs over (speed_frac()).
const SPEED_FX_MIN_KMH := 80.0
const SPEED_FX_MAX_KMH := 260.0
const SPEED_TO_KMH := 1.10130592 # same conversion speed_blur.gd uses
## Speed shake: builds from SHAKE_MIN_KMH to full at SHAKE_MAX_KMH - and is
## full whenever the car is at its OWN top speed (HighSpeedScorer.at_top_speed),
## however slow that car is.
const SHAKE_MIN_KMH := 100.0
const SHAKE_MAX_KMH := 200.0
const SPEED_MAX_OFFSET := 0.005 # of the screen height at full (x DevConsole.speed_shake)
const SPEED_FREQUENCY := 28.0
const SPEED_BOOST_KICK := 0.5 # added at full nitro / boost burst power
const SPEED_SMOOTHING := 4.0 # how fast the shake follows the speed

var _trauma := 0.0
var _rumble := 0.0 # 0..1, rev rumble level
var _speed := 0.0 # speed shake level (0..1, more with the boost kick / slider)
var _moving := false # an offset is applied (so it gets zeroed once when both channels stop)
var _time := 0.0
var _noise := FastNoiseLite.new()
var _screen: Node # speed_blur.gd's layer - it shifts the image (set_shake)
var _car: RigidBody3D # the player car, looked up again only if it goes away
var _boosters: Array[Node] = [] # its NitroBoost / BoostBurst (both have get_power())

func _ready() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = randi()
	# FastNoiseLite's default frequency is 0.01, which would make the *_FREQUENCY
	# rates above a hundred times slower than they read - a slow drift, not a
	# shake. At 1.0 they are wiggles per real second.
	_noise.frequency = 1.0
	GameState.state_changed.connect(_on_state_changed)

## Leaving the run mid-shake shouldn't leave the lens shifted (the crash
## spin itself may keep shaking).
func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	if new_state in [GameState.State.MENU, GameState.State.GARAGE, GameState.State.CRASHED]:
		stop()

func shake(intensity: float) -> void:
	_trauma = clampf(maxf(_trauma, intensity), 0.0, 1.0)

## How hard the HUD should jolt, 0..1 (UI/hud/hud_sway.gd): impact
## trauma^2 plus a share of the rev rumble.
func get_hud_shake() -> float:
	return clampf(_trauma * _trauma + _rumble * REV_HUD_SCALE, 0.0, 1.0)

func stop() -> void:
	_trauma = 0.0
	_rumble = 0.0
	_speed = 0.0
	_apply(Vector2.ZERO, 0.0)

## 0..1 position of `speed` (world units/s) in the speed zoom-out range.
static func speed_frac(speed: float) -> float:
	return clampf(inverse_lerp(SPEED_FX_MIN_KMH, SPEED_FX_MAX_KMH, speed * SPEED_TO_KMH), 0.0, 1.0)

func _player_car() -> RigidBody3D:
	if not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("player_car") as RigidBody3D
		_boosters.clear()
		if _car:
			for path in ["NitroBoost", "BoostBurst"]:
				var node := _car.get_node_or_null(NodePath(path))
				if node:
					_boosters.append(node)
	return _car

func _process(delta: float) -> void:
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	_rumble = lerpf(_rumble, _rev_target(), 1.0 - exp(-REV_SMOOTHING * real_delta))
	if _rumble < 0.002:
		_rumble = 0.0
	_speed = lerpf(_speed, _speed_target(), 1.0 - exp(-SPEED_SMOOTHING * real_delta))
	if _speed < 0.002:
		_speed = 0.0
	if _trauma <= 0.0 and _rumble <= 0.0 and _speed <= 0.0:
		if _moving:
			_moving = false
			_apply(Vector2.ZERO, 0.0)
		return
	_moving = true
	_time += real_delta
	_trauma = maxf(_trauma - DECAY * real_delta, 0.0)
	var amount := MAX_OFFSET * _trauma * _trauma
	var rev_amount := REV_MAX_OFFSET * _rumble
	var speed_amount := SPEED_MAX_OFFSET * _speed
	var t := _time * FREQUENCY
	var offset := Vector2(_noise.get_noise_2d(t, 0.0), _noise.get_noise_2d(0.0, t)) * amount
	var r := _time * REV_FREQUENCY
	offset += Vector2(_noise.get_noise_2d(r, 500.0), _noise.get_noise_2d(500.0, r)) * rev_amount
	var s := _time * SPEED_FREQUENCY
	offset += Vector2(_noise.get_noise_2d(s, 900.0), _noise.get_noise_2d(900.0, s)) * speed_amount
	# The margin is the most the image can shift right now (noise is within +-1),
	# so it follows the shake's strength smoothly rather than each wiggle.
	_apply(offset, amount + rev_amount + speed_amount)

## Speed shake target from the player car's speed - only while driving.
func _speed_target() -> float:
	if GameState.current != GameState.State.PLAYING or IntroPan.playing:
		return 0.0
	var car := _player_car()
	if car == null:
		return 0.0
	var kmh := car.linear_velocity.length() * SPEED_TO_KMH
	var level := smoothstep(SHAKE_MIN_KMH, SHAKE_MAX_KMH, kmh)
	if HighSpeedScorer.at_top_speed(car):
		level = 1.0
	var boost := 0.0
	for node in _boosters:
		boost = maxf(boost, node.get_power())
	return (level + SPEED_BOOST_KICK * boost) * DevConsole.speed_shake

## Rev rumble target 0..1 from the player car's revs - only during the intro.
func _rev_target() -> float:
	if not IntroPan.playing:
		return 0.0
	var car = _player_car() # untyped so car.gd's rpm vars resolve
	if car == null:
		return 0.0
	var span: float = maxf(car.RPMLimit - car.IdleRPM, 1.0)
	var frac := clampf((car.rpm - car.IdleRPM) / span, 0.0, 1.0)
	var level := smoothstep(REV_START, 1.0, frac)
	if frac >= REV_LIMITER_AT:
		level += REV_LIMITER_KICK
	return clampf(level, 0.0, 1.0)

func _apply(offset: Vector2, margin: float) -> void:
	if not is_instance_valid(_screen):
		_screen = get_tree().get_first_node_in_group("screen_shake") if is_inside_tree() else null
	if _screen:
		_screen.set_shake(offset, margin)
