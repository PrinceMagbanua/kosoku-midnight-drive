extends Node3D

## Slow-mo ("Speedbreaker", like NFS) - hold the `slowmo` action (Ctrl) to
## slow the whole world down. Sibling of NitroBoost on the car, same shape:
## a 0..1 tank that drains while active and only refills (slowly) from risk
## events (near-miss/overtake). Gated by shop upgrades like nitro: "slowmo"
## level 1 unlocks it and its value is how much time slows (1 - time scale),
## "slowmoFuel"'s value is tank size (real seconds from full). Both per-level
## tables live in UpgradeCatalog. The tank starts full every run (reset_state(),
## called by run_reset.gd).
##
## The whole world - car included - slows down visually, but the car keeps
## ALL its momentum: the speedo doesn't drop, and speed coming out equals
## speed going in. While active, A/D doesn't turn the car - it strafes it
## sideways along its own X axis.
##
## Everything scales with `_amount` (0..1), which eases in/out over
## BLEND_TIME real seconds so nothing snaps:
## - Time: Engine.time_scale. Godot keeps the same number of physics ticks
##   per real second and just shrinks each tick's delta, so the world slows.
## - Car: wheel.gd and car.gd's aero() push the car with fixed impulses PER
##   TICK (they ignore delta), and wheel.gd divides its measured ground speed
##   by time_scale, so every tick simulates exactly like a normal-speed tick
##   - just drawn at time_scale. Gravity is the one force that DOES scale
##   with delta, so gravity_scale = 1/time_scale keeps it in proportion.
##   No extra downforce/weight is added - the car handles exactly as normal.
## - Strafe: car.gd's steer_locked stops A/D steering (the wheels ease back
##   to centre); instead the car's velocity along its own left/right axis is
##   eased toward the input. Forward speed is never touched. Roll, pitch
##   and yaw spin are bled off so the nose stays pointed ahead while sliding.
## - Audio: AudioServer.playback_speed_scale slows/pitches down every sound
##   (music too), and a low-pass + EQ on the Master bus muffles the
##   mids/treble and lifts the bass - "underwater". Both effects are
##   disabled whenever slow-mo is fully off, so they cost nothing then.
## - Afterimages: every GHOST_INTERVAL real seconds, a see-through copy of
##   the car's meshes is left behind in the world and fades out.
##
## Crash: crash_system.gd owns time_scale during CRASHING (its own 0.15
## slow-mo), so leaving PLAYING ends this instantly and only resets
## time_scale when the new state isn't CRASHING/PAUSED.
##
## Impact slow-mo: crash_system.gd calls impact() when a body panel is torn
## off - IMPACT_HOLD real seconds slowed (deeper for harder hits), then eased
## back to normal over IMPACT_FADE. It shares this script's time_scale,
## gravity compensation and audio slowdown (whichever of the two is slower
## wins), but never the Speedbreaker's strafe/steer lock/afterimages - the
## player keeps normal control. Costs no fuel.

const BLEND_TIME := 0.25 # real seconds to ease fully in/out
# Tank refill per risk event (fraction of a full tank) - kept small on purpose.
const FUEL_NEAR_MISS_CLOSE := 0.015
const FUEL_NEAR_MISS_HAIRLINE := 0.03
const FUEL_NEAR_MISS_IMPOSSIBLE := 0.05
const FUEL_OVERTAKE := 0.005

# Impact slow-mo (real seconds). Time scale lerps from LIGHT to HARD with
# the hit's intensity (0..1).
const IMPACT_HOLD := 0.75
const IMPACT_EASE_IN := 0.06
const IMPACT_FADE := 0.3
const IMPACT_SCALE_LIGHT := 0.45
const IMPACT_SCALE_HARD := 0.2

# Handling.
const STABILIZE_RATE := 6.0 # how fast roll/pitch spin is bled off (per sim second)
const YAW_STABILIZE_RATE := 8.0 # same for yaw, keeps the nose straight while strafing
# Strafe: sideways speed (world units per SIM second - on screen it's this *
# time_scale) at full A/D, and how fast it's reached/released (per real second).
const STRAFE_SPEED := 30.0
const STRAFE_ACCEL := 60.0

# Audio.
const AUDIO_SPEED := 0.6 # playback speed/pitch at full slow-mo
const LOWPASS_CUTOFF_HZ := 700.0
# AudioEffectEQ6 bands: 32, 100, 320, 1000, 3200, 10000 Hz.
const EQ_GAINS_DB: Array[float] = [6.0, 5.0, 1.0, -4.0, -10.0, -14.0]

# Afterimages.
const GHOST_INTERVAL := 0.08 # real seconds between afterimages
const GHOST_LIFETIME := 0.4 # real seconds for one to fade out
const GHOST_MAX := 5
const GHOST_COLOR := Color(0.08, 0.16, 0.32, 0.55) # unshaded, so this is exactly what shows on screen

var _car # car.gd's RigidBody3D - untyped so its script props (Downforce/steer) resolve
var _fuel := 1.0
var _amount := 0.0
var _touching_time := false # true while this has changed time_scale/car/audio
var _impact_elapsed := -1.0 # real seconds since impact(), -1 = none running
var _impact_scale := 1.0

var _base_gravity_scale := 1.0

var _lowpass: AudioEffectLowPassFilter
var _eq: AudioEffectEQ6

var _ghost_timer := 0.0
var _ghosts: Array = [] # [{node: Node3D, mat: StandardMaterial3D, age: float}]

## Remaining tank (0..1), read by live_hud.gd for the SLOW dial.
func get_fuel() -> float:
	return _fuel

## Current blend (0..1) - how "in" slow-mo the game is right now.
func get_amount() -> float:
	return _amount

## Impact slow-mo (see header). `intensity` 0..1. A new impact while one is
## running restarts the hold and keeps the deeper of the two scales.
func impact(intensity: float) -> void:
	var s := lerpf(IMPACT_SCALE_LIGHT, IMPACT_SCALE_HARD, clampf(intensity, 0.0, 1.0))
	_impact_scale = minf(_impact_scale, s) if _impact_elapsed >= 0.0 else s
	_impact_elapsed = 0.0 if _impact_elapsed < 0.0 else minf(_impact_elapsed, IMPACT_EASE_IN)

## Impact blend 0..1 this tick (advances the timer).
func _update_impact(real_delta: float) -> float:
	if _impact_elapsed < 0.0:
		return 0.0
	_impact_elapsed += real_delta
	if _impact_elapsed < IMPACT_EASE_IN:
		return smoothstep(0.0, IMPACT_EASE_IN, _impact_elapsed)
	if _impact_elapsed <= IMPACT_EASE_IN + IMPACT_HOLD:
		return 1.0
	var t := (_impact_elapsed - IMPACT_EASE_IN - IMPACT_HOLD) / IMPACT_FADE
	if t >= 1.0:
		_impact_elapsed = -1.0
		return 0.0
	return 1.0 - smoothstep(0.0, 1.0, t)

func add_fuel(amount: float) -> void:
	_fuel = clampf(_fuel + amount, 0.0, 1.0)

func _on_near_miss(_speed_pct: float, near_miss_tier: int) -> void:
	match near_miss_tier:
		RiskEvents.NearMissTier.IMPOSSIBLE:
			add_fuel(FUEL_NEAR_MISS_IMPOSSIBLE)
		RiskEvents.NearMissTier.HAIRLINE:
			add_fuel(FUEL_NEAR_MISS_HAIRLINE)
		_:
			add_fuel(FUEL_NEAR_MISS_CLOSE)

func _on_overtake(_speed_pct: float) -> void:
	add_fuel(FUEL_OVERTAKE)

## Called by run_reset.gd on a fresh run/restart.
func reset_state() -> void:
	_fuel = 1.0
	_end_now(true)

func _ready() -> void:
	_car = get_parent()
	RiskEvents.near_miss.connect(_on_near_miss)
	RiskEvents.overtake.connect(_on_overtake)
	GameState.state_changed.connect(_on_state_changed)

	_lowpass = AudioEffectLowPassFilter.new()
	_eq = AudioEffectEQ6.new()
	AudioServer.add_bus_effect(0, _lowpass)
	AudioServer.add_bus_effect(0, _eq)
	_set_audio_effects_enabled(false)

func _exit_tree() -> void:
	_end_now(true)
	for i in range(AudioServer.get_bus_effect_count(0) - 1, -1, -1):
		var e := AudioServer.get_bus_effect(0, i)
		if e == _lowpass or e == _eq:
			AudioServer.remove_bus_effect(0, i)
	_clear_ghosts()

func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	if new_state == GameState.State.PLAYING or new_state == GameState.State.PAUSED:
		return
	_end_now(new_state != GameState.State.CRASHING)

func _physics_process(delta: float) -> void:
	if _car == null or GameState.current != GameState.State.PLAYING:
		return
	var real_delta := delta / maxf(Engine.time_scale, 0.001)

	var tier: int = SaveData.get_upgrade_tier("slowmo")
	var active := tier > 0 and Input.is_action_pressed("slowmo") and _fuel > 0.0 and not IntroPan.playing
	if active:
		var drain_time: float = maxf(SaveData.get_upgrade_value("slowmoFuel"), 0.1)
		_fuel = clampf(_fuel - real_delta / drain_time, 0.0, 1.0)
	_amount = move_toward(_amount, 1.0 if active else 0.0, real_delta / BLEND_TIME)
	var impact_blend := _update_impact(real_delta)

	if _amount <= 0.0 and impact_blend <= 0.0:
		if _touching_time:
			_end_now(true)
		return

	if not _touching_time:
		_touching_time = true
		_base_gravity_scale = _car.gravity_scale
		_ghost_timer = 0.0
		_set_audio_effects_enabled(true)
	# Strafe/steer lock are the Speedbreaker's only - an impact slow-mo alone
	# leaves normal steering.
	_car.steer_locked = _amount > 0.0

	var eased := smoothstep(0.0, 1.0, _amount)
	# Tier can be 0 here only while blending out after a sell - use level 1's scale.
	var slowmo_row := SaveData.get_upgrade_row("slowmo")
	var slow_scale: float = 1.0 - slowmo_row.value_at(maxi(tier, 1))
	Engine.time_scale = minf(lerpf(1.0, slow_scale, eased), lerpf(1.0, _impact_scale, impact_blend))
	# Keep gravity in proportion with the car's per-tick forces - see header.
	_car.gravity_scale = _base_gravity_scale / Engine.time_scale
	_apply_audio(maxf(eased, impact_blend))
	if _amount <= 0.0:
		return
	_strafe(eased, real_delta)

	# Stabilizer: bleed off roll/pitch spin, and yaw so the nose stays ahead.
	var up: Vector3 = _car.global_basis.y
	var av: Vector3 = _car.angular_velocity
	var yaw: Vector3 = up * av.dot(up)
	var roll_pitch: Vector3 = av - yaw
	var bleed_rp := 1.0 - exp(-STABILIZE_RATE * eased * delta)
	var bleed_yaw := 1.0 - exp(-YAW_STABILIZE_RATE * eased * delta)
	_car.angular_velocity = av - roll_pitch * bleed_rp - yaw * bleed_yaw

## A/D strafe: eases the car's velocity along its own left/right axis toward
## the input. Only that component is changed, so forward speed is kept. With
## no input the target is 0, so the slide eases out (and is ~0 by the time
## slow-mo has blended out, since the target scales with `eased`).
func _strafe(eased: float, real_delta: float) -> void:
	# Car forward is +Z (basis.z), so its left is +X - same convention as
	# car.gd's steer (negative = left = positive yaw).
	var left_dir: Vector3 = _car.global_basis.x
	left_dir.y = 0.0
	if left_dir.length_squared() < 0.0001:
		return
	left_dir = left_dir.normalized()
	var input := Input.get_axis("right", "left") # +1 = left
	var target := input * STRAFE_SPEED * eased
	var v: Vector3 = _car.linear_velocity
	var cur := v.dot(left_dir)
	var new_lat := move_toward(cur, target, STRAFE_ACCEL * real_delta)
	_car.linear_velocity = v + left_dir * (new_lat - cur)

## Ends slow-mo immediately and puts the car/audio back. `restore_time` is
## false only when entering CRASHING (crash_system.gd sets its own scale).
func _end_now(restore_time: bool) -> void:
	_amount = 0.0
	_impact_elapsed = -1.0
	if not _touching_time:
		return
	_touching_time = false
	if restore_time:
		Engine.time_scale = 1.0
	if is_instance_valid(_car):
		_car.steer_locked = false
		_car.gravity_scale = _base_gravity_scale
	_apply_audio(0.0)
	_set_audio_effects_enabled(false)

func _apply_audio(t: float) -> void:
	AudioServer.playback_speed_scale = lerpf(1.0, AUDIO_SPEED, t)
	if _lowpass:
		# Log-space lerp so the cutoff sweep sounds even.
		_lowpass.cutoff_hz = exp(lerpf(log(20000.0), log(LOWPASS_CUTOFF_HZ), t))
	if _eq:
		for band in EQ_GAINS_DB.size():
			_eq.set_band_gain_db(band, EQ_GAINS_DB[band] * t)

func _set_audio_effects_enabled(on: bool) -> void:
	for i in AudioServer.get_bus_effect_count(0):
		var e := AudioServer.get_bus_effect(0, i)
		if e == _lowpass or e == _eq:
			AudioServer.set_bus_effect_enabled(0, i, on)

# --- afterimages --------------------------------------------------------

func _process(delta: float) -> void:
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	_update_ghosts(real_delta)
	if _amount <= 0.0 or not is_instance_valid(_car):
		return
	_ghost_timer -= real_delta
	if _ghost_timer <= 0.0:
		_ghost_timer = GHOST_INTERVAL
		_spawn_ghost()

func _spawn_ghost() -> void:
	if _ghosts.size() >= GHOST_MAX:
		var oldest: Dictionary = _ghosts.pop_front()
		oldest.node.queue_free()
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.no_depth_test = false
	mat.albedo_color = GHOST_COLOR
	var root := Node3D.new()
	root.name = "SlowMoGhost"
	_car.get_parent().add_child(root)
	for mi in CarMeshUtil.solid_meshes(_car):
		var g := MeshInstance3D.new()
		g.mesh = mi.mesh
		g.material_override = mat
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(g)
		g.global_transform = mi.global_transform
	_ghosts.append({"node": root, "mat": mat, "age": 0.0})

func _update_ghosts(real_delta: float) -> void:
	for i in range(_ghosts.size() - 1, -1, -1):
		var g: Dictionary = _ghosts[i]
		g.age += real_delta
		var t: float = g.age / GHOST_LIFETIME
		if t >= 1.0:
			g.node.queue_free()
			_ghosts.remove_at(i)
		else:
			g.mat.albedo_color.a = GHOST_COLOR.a * (1.0 - t)

func _clear_ghosts() -> void:
	for g in _ghosts:
		if is_instance_valid(g.node):
			g.node.queue_free()
	_ghosts.clear()
