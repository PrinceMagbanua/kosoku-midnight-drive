extends Node3D

## Nitro boost - Voxel Driver's `main.js` had "hold Shift for a speed burst",
## gated by a purchasable nitro upgrade tier (already modeled in SaveData's
## UpgradeCatalog). Shift itself is already bound to `clutch` in this
## project's own manual-transmission control scheme, so nitro is bound to
## the free `nitro` action (N key) instead - same gating, different key.
##
## THIRD design for how nitro actually moves the car - the first two both
## had real, now-understood problems:
## 1. `apply_central_force()` (original g-rcp2-era attempt) - felt weak,
##    reverted, because a raw force competes against car.gd's own
##    drivetrain/drag forces, which are large enough here to mostly absorb
##    a modest added force.
## 2. Directly adding to `linear_velocity` every frame (tried next) - felt
##    strong, but caused a real, serious bug: this completely bypasses
##    wheel.gd's tire/slip model. wheel.gd computes grip from the
##    DIFFERENCE between wheel rotation speed and actual chassis velocity -
##    injecting raw chassis velocity every frame without ever spinning the
##    wheels up to match builds a growing, artificial "slip debt" the whole
##    time nitro is held (matching user-observed symptoms: the weight-
##    distribution readout pegging to an extreme, the car visibly sinking/
##    squatting uniformly under the phantom slip forces) - then the instant
##    nitro releases, the tires suddenly "catch up" to the real chassis
##    speed all at once, a violent correction (matching "loses momentum and
##    breaks the car" the instant you let go).
## 3. (Current) `apply_central_force()` again, but tuned up front, and
##    flattened to the horizontal plane (see below) - a real force works
##    WITH the wheel/tire model instead of bypassing it (the wheels'
##    existing rotational/traction physics naturally keep up with a
##    continuous force the same way they do with normal engine torque), so
##    no slip debt can accumulate. The force (the "nitro" upgrade's value,
##    UpgradeCatalog) is deliberately large to make sure it's still felt on
##    top of the existing drivetrain/drag forces that made the ORIGINAL
##    force-based attempt feel weak - retune it there by feel.
##
## Flattened to the horizontal plane for the same reason as before: the
## car's actual current forward (global_transform.basis.z) includes
## whatever pitch/roll it has from the road/suspension at that instant - on
## a downhill grade or mid-bank, that has a real downward component, so a
## force applied along it would still shove the car into the ground.
##
## Charge-up ramp (0..1 via smoothstep over CHARGE_TIME seconds of
## CONTINUOUS hold, resetting instantly on release) - so mashing the key
## barely does anything but holding it rewards a real hold, not a tap. Fire
## particle visual scales with the same charge level.
##
## Reuses `fire.tscn` (the project's existing backfire particle scene) for
## a visual burst, as a SEPARATE instance from the "fire" node already
## wired to car.gd's exhaust backfire logic, so nitro and backfire don't
## fight over the same emitter's `emitting` flag.
##
## FUEL (per user request - "make the Nitro something you deplete"): a 0..1
## tank, drained while boosting, independent of the charge-up ramp above
## (charge is "how hard is it pushing RIGHT NOW", fuel is "how much boost is
## left"). There is NO passive refill anymore - the tank only fills from risk
## events (RiskEvents near_miss / overtake, see add_fuel()), so taking risks
## is the only way to earn more boost. Two upgrades: "nitro" is the boost's
## force (level 1 unlocks it), "nitroFuel" is tank size (its value = seconds
## of continuous boost from full). Both per-level tables live in
## UpgradeCatalog. A dry
## tank gates `active` like not owning the upgrade (no force, no fire, no
## sound) until a risk event puts fuel back.
##
## Warp streaks (per user request - "particles when you try and go to the
## speed of light"): a second, separate particle effect from the exhaust
## fire - elongated bright streaks radiating out from the car, fading in
## with power, meant to read as "everything's blurring past" rather than
## "the exhaust is burning." Built by WarpStreaks (shared with boost_burst.gd).

@export var fire_path: NodePath = NodePath("../NitroFire")
const CHARGE_TIME := 0.5 # seconds of continuous hold to reach full power
const FIRE_SCALE_MIN := 0.35 # visual scale at the moment nitro is first pressed (charge=0)

# Fuel (fraction of a full tank) earned per risk event - tuning knobs.
const FUEL_NEAR_MISS_CLOSE := 0.015
const FUEL_NEAR_MISS_HAIRLINE := 0.03
const FUEL_NEAR_MISS_IMPOSSIBLE := 0.05
const FUEL_OVERTAKE := 0.005

const SFX_START := preload("res://MAIN/sfx/nitro-start.ogg")
const SFX_HOLD := preload("res://MAIN/sfx/nitro-hold.ogg")

var _car: RigidBody3D
var _fire: CPUParticles3D
var _fire_base_scale: Vector3 = Vector3.ONE
var _warp: CPUParticles3D
var _warp_material: StandardMaterial3D
var _start_player: AudioStreamPlayer
var _hold_player: AudioStreamPlayer
var _charge: float = 0.0 # 0..1, resets to 0 on release
var _fuel: float = 1.0 # 0..1
var _was_active: bool = false

## Current eased power level (0..1), read by live_hud.gd for the HUD's
## nitro readout - the same smoothstep-eased value actually applied to the
## car's force each frame, not the raw linear _charge.
func get_power() -> float:
	return smoothstep(0.0, 1.0, _charge)

## Remaining fuel (0..1), read by live_hud.gd for the HUD's tank readout.
func get_fuel() -> float:
	return _fuel

## True while the boost is firing (read by live_hud.gd to hold the bottles bright).
func is_active() -> bool:
	return _was_active

## Adds `amount` (fraction of a full tank), clamped to 0..1.
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

## Called by run_reset.gd alongside car.gd's own reset_state() on a fresh
## run/restart - a crash shouldn't leave the player stuck with whatever tank
## level they happened to have when they hit something.
func reset_state() -> void:
	_fuel = 1.0
	_charge = 0.0
	_was_active = false
	if _hold_player:
		_hold_player.stop()

func _ready() -> void:
	_car = get_parent() as RigidBody3D
	_fire = get_node_or_null(fire_path)
	if _fire:
		_fire_base_scale = _fire.scale
	_warp = WarpStreaks.build()
	_warp_material = _warp.material_override as StandardMaterial3D
	add_child(_warp)
	RiskEvents.near_miss.connect(_on_near_miss)
	RiskEvents.overtake.connect(_on_overtake)
	_start_player = AudioStreamPlayer.new()
	_start_player.stream = SFX_START
	add_child(_start_player)
	_hold_player = AudioStreamPlayer.new()
	_hold_player.stream = SFX_HOLD
	if _hold_player.stream:
		_hold_player.stream.loop = true
	add_child(_hold_player)

func _physics_process(delta: float) -> void:
	if _car == null:
		return
	var tier: int = SaveData.get_upgrade_tier("nitro")
	var active: bool = tier > 0 and Input.is_action_pressed("nitro") and _fuel > 0.0 and not IntroPan.playing

	if active:
		var drain_time: float = maxf(SaveData.get_upgrade_value("nitroFuel"), 0.1)
		_fuel = clampf(_fuel - delta / drain_time, 0.0, 1.0)

	var sfx_db := linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume, 0.0001, 1.0))
	if active and not _was_active:
		_start_player.volume_db = sfx_db
		_start_player.play()
		_hold_player.volume_db = sfx_db
		_hold_player.play()
	elif not active and _was_active:
		_hold_player.stop()
	elif active:
		_hold_player.volume_db = sfx_db # live-updates if the slider moves mid-hold
	_was_active = active

	if not active:
		_charge = 0.0
		if _fire:
			_fire.emitting = false
		_warp.emitting = false
		return

	_charge = clampf(_charge + delta / CHARGE_TIME, 0.0, 1.0)
	var power: float = smoothstep(0.0, 1.0, _charge)

	if _fire:
		_fire.emitting = true
		_fire.scale = _fire_base_scale * lerpf(FIRE_SCALE_MIN, 1.0, power)

	_warp.emitting = power > 0.35
	_warp.speed_scale = lerpf(0.6, 1.6, power)
	if _warp_material:
		_warp_material.albedo_color.a = lerpf(0.0, 0.8, inverse_lerp(0.35, 1.0, power))

	# Flattened to the horizontal plane - see header note. A car pitched
	# fully vertical (forward.y == ±1) has no horizontal component to
	# normalize; skip applying boost that one frame rather than divide by
	# ~0, which shouldn't happen in normal play anyway.
	var forward: Vector3 = _car.global_transform.basis.z
	forward.y = 0.0
	if forward.length_squared() < 0.0001:
		return
	forward = forward.normalized()
	_car.apply_central_force(forward * (SaveData.get_upgrade_value("nitro") * power))
