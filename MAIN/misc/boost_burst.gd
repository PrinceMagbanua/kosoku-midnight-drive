extends Node3D

## Boost burst - a short, free kick of speed for taking a risk. Sibling of
## NitroBoost on the car, but nothing to buy and no tank: it just fires.
## Triggers:
## - RiskEvents.near_miss at HAIRLINE or IMPOSSIBLE (a plain NEAR MISS only
##   scores and refills nitro, as before).
## - RiskEvents.slipstream_boost - swinging out of a charged slipstream
##   (slipstream_scorer.gd), sized by the charge.
##
## The push is a real force along the car's flattened forward axis, the same
## way nitro_boost.gd does it and for the same reasons (see its header: never
## write linear_velocity, never push along the pitched forward axis). It
## starts at BURST_FORCE * strength and eases out to zero over BURST_TIME, so
## there's a kick up front and nothing to snap back when it ends. A new burst
## while one is running restarts it at the stronger of the two.
##
## What it looks like:
## - Warp streaks (WarpStreaks, the nitro "wormhole" effect): a denser,
##   shorter-lived ring for the first STREAK_FRAC of the burst.
## - Shine: a bright band that runs over the car from nose to tail once
##   (boost_shine.gdshader as material_overlay on the car's solid meshes),
##   SHINE_TIME long. Skipped in cockpit view - from inside, it would just
##   flash the cabin.
## - speed_blur.gd and camera_shake.gd read get_power() for their own kick.

const BURST_TIME := 0.9 # seconds
const BURST_FORCE := 6000.0 # forward force at the start of a full-strength burst - main feel knob
const STRENGTH_HAIRLINE := 0.6
const STRENGTH_IMPOSSIBLE := 1.0
const STRENGTH_MIN := 0.3 # weakest burst that still fires

const STREAK_AMOUNT := 90
const STREAK_LIFETIME := 0.22
const STREAK_FRAC := 0.6 # share of the burst the streaks keep spawning for
const STREAK_ALPHA := 0.9

const SHINE_SHADER := preload("res://MAIN/misc/boost_shine.gdshader")
const SHINE_TIME := 0.4 # seconds for the band to cross the car
const SHINE_WIDTH := 1.3 # band half-width, world units
const SHINE_REACH := 1.7 # sweep travel each way, in car half-lengths (see _update_shine)
const SHINE_COLOR := Color(0.75, 0.95, 1.0)
const SHINE_STRENGTH := 1.6

const SFX := preload("res://MAIN/sfx/nitro-start.ogg")
const SFX_PITCH := 1.5
const SFX_VOLUME := 0.6 # linear, fraction of the normal SFX volume

var _car: RigidBody3D
var _time := -1.0 # seconds into the burst, -1 = none running
var _strength := 0.0
var _streaks: CPUParticles3D
var _streak_material: StandardMaterial3D
var _shine := ShaderMaterial.new()
var _shine_time := -1.0 # seconds into the sweep, -1 = none running
var _shine_meshes: Array[MeshInstance3D] = []
var _sfx: AudioStreamPlayer

## How hard the burst is pushing right now, 0..1.
func get_power() -> float:
	if _time < 0.0:
		return 0.0
	var k := 1.0 - _time / BURST_TIME
	return _strength * k * k

func _ready() -> void:
	_car = get_parent() as RigidBody3D
	_streaks = WarpStreaks.build(STREAK_AMOUNT, STREAK_LIFETIME)
	_streak_material = _streaks.material_override as StandardMaterial3D
	_streaks.speed_scale = 1.6
	add_child(_streaks)
	_shine.shader = SHINE_SHADER
	_shine.set_shader_parameter("width", SHINE_WIDTH)
	_shine.set_shader_parameter("color", SHINE_COLOR)
	_shine.set_shader_parameter("strength", SHINE_STRENGTH)
	_sfx = AudioStreamPlayer.new()
	_sfx.stream = SFX
	_sfx.pitch_scale = SFX_PITCH
	add_child(_sfx)
	RiskEvents.near_miss.connect(_on_near_miss)
	RiskEvents.slipstream_boost.connect(fire)
	GameState.state_changed.connect(_on_state_changed)

func _on_near_miss(_speed_pct: float, tier: int) -> void:
	match tier:
		RiskEvents.NearMissTier.IMPOSSIBLE:
			fire(STRENGTH_IMPOSSIBLE)
		RiskEvents.NearMissTier.HAIRLINE:
			fire(STRENGTH_HAIRLINE)

## Starts a burst. `strength` 0..1.
func fire(strength: float) -> void:
	if _car == null or GameState.current != GameState.State.PLAYING or IntroPan.playing:
		return
	var s := clampf(strength, STRENGTH_MIN, 1.0)
	_strength = maxf(s, get_power())
	_time = 0.0
	_sfx.volume_db = linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume * SFX_VOLUME, 0.0001, 1.0))
	_sfx.play()
	_start_shine()

## Called by run_reset.gd on a fresh run/restart.
func reset_state() -> void:
	_time = -1.0
	_strength = 0.0
	_streaks.emitting = false
	_end_shine()

## Leaving the run mid-burst (crash, garage) shouldn't leave the shine on.
func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	if new_state != GameState.State.PLAYING and new_state != GameState.State.PAUSED:
		reset_state()

func _physics_process(delta: float) -> void:
	if _time < 0.0 or _car == null:
		return
	_time += delta
	if _time >= BURST_TIME:
		_time = -1.0
		_streaks.emitting = false
		return
	_streaks.emitting = _time < BURST_TIME * STREAK_FRAC
	_streak_material.albedo_color.a = STREAK_ALPHA * _strength * (1.0 - _time / BURST_TIME)

	# Flattened to the horizontal plane - see nitro_boost.gd's header.
	var forward: Vector3 = _car.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	_car.apply_central_force(forward.normalized() * (BURST_FORCE * get_power()))

# --- shine sweep ----------------------------------------------------------

func _start_shine() -> void:
	_end_shine()
	var cam := get_viewport().get_camera_3d()
	if cam and cam.global_position.distance_to(_car.global_position) < CrashSystem.PLAYER_HALF_L:
		return # cockpit view
	_shine_meshes = CarMeshUtil.solid_meshes(_car)
	for mi in _shine_meshes:
		mi.material_overlay = _shine
	_shine_time = 0.0
	_update_shine()

func _end_shine() -> void:
	_shine_time = -1.0
	for mi in _shine_meshes:
		# A panel torn off mid-sweep is still valid (it's flying); a rebuilt hull isn't.
		if is_instance_valid(mi) and mi.material_overlay == _shine:
			mi.material_overlay = null
	_shine_meshes.clear()

func _process(delta: float) -> void:
	if _shine_time < 0.0:
		return
	_shine_time += delta
	if _shine_time >= SHINE_TIME or not is_instance_valid(_car):
		_end_shine()
		return
	_update_shine()

## Band position: from just ahead of the nose to just past the tail. The
## car's origin isn't its middle (the nose reaches further than the tail), so
## the sweep covers SHINE_REACH half-lengths either way to clear both ends.
func _update_shine() -> void:
	var forward: Vector3 = _car.global_basis.z.normalized()
	var reach: float = CrashSystem.PLAYER_HALF_L * float(_car.get_meta("hull_l_scale", 1.0)) * SHINE_REACH + SHINE_WIDTH
	_shine.set_shader_parameter("car_origin", _car.global_position)
	_shine.set_shader_parameter("car_forward", forward)
	_shine.set_shader_parameter("sweep", lerpf(reach, -reach, _shine_time / SHINE_TIME))
