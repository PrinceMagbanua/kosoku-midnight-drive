class_name CarStats
extends RefCounted

## The ONE place that turns the four player-facing stats (1-10) into physics
## multipliers, and folds in the shop upgrades. Everything is relative to the
## coupe's authored config: a stat of 5 means "exactly as authored" (x1.0), so
## the coupe with no upgrades is untouched. Tune the feel HERE.

## Per stat point away from 5, the physics value is multiplied by BASE^(delta).
const ACCEL_BASE := 1.15 # engine torque:      stat 9 -> x1.75, stat 3 -> x0.76
const TOP_SPEED_BASE := 1.068 # gearing/drag:  stat 9 -> x1.30 top speed, stat 6 -> x1.07
const HANDLING_BASE := 1.05 # tyre grip:       stat 9 -> x1.22, stat 4 -> x0.95
const BRAKING_BASE := 1.08 # brake torque:     stat 6 -> x1.08, stat 9 -> x1.36

## Shop upgrade id -> the stat it raises. Its stat points come from the
## upgrade's per-level table (UpgradeCatalog), read via SaveData. They are NOT
## capped at STAT_MAX - every level does something on every car; only the
## garage bars clamp (display()).
const UPGRADE_STAT := {
	"accel": "acceleration",
	"topSpeed": "top_speed",
	"handling": "handling",
	"braking": "braking",
}
const STAT_BASE := {
	"acceleration": ACCEL_BASE,
	"top_speed": TOP_SPEED_BASE,
	"handling": HANDLING_BASE,
	"braking": BRAKING_BASE,
}

const STAT_MIN := 1.0
const STAT_MAX := 10.0

## Base stats of the car itself, as the garage bars show them.
static func base(profile: CarProfile) -> Dictionary:
	return {
		"acceleration": float(profile.acceleration),
		"top_speed": float(profile.top_speed),
		"handling": float(profile.handling),
		"braking": float(profile.braking),
	}

## Points contributed by purchased upgrades (0 with none).
static func upgrade_bonus() -> Dictionary:
	return {
		"acceleration": _bonus("accel"),
		"top_speed": _bonus("topSpeed"),
		"handling": _bonus("handling"),
		"braking": _bonus("braking"),
	}

## Base + upgrades - what the physics uses. Floored at STAT_MIN but not
## capped, so upgrades still count on a car that starts near 10.
static func effective(profile: CarProfile) -> Dictionary:
	var b := base(profile)
	var u := upgrade_bonus()
	var out := {}
	for k in b:
		out[k] = maxf(b[k] + u[k], STAT_MIN)
	return out

## effective() clamped to the 1-10 scale, for the garage stat bars.
static func display(profile: CarProfile) -> Dictionary:
	var out := effective(profile)
	for k in out:
		out[k] = minf(out[k], STAT_MAX)
	return out

## % gain of the physics value an upgrade drives, for `points` of it (the
## stat multipliers are BASE^points, so this is the same on every car).
static func upgrade_gain_pct(upgrade_id: String, points: float) -> float:
	return (pow(STAT_BASE[UPGRADE_STAT[upgrade_id]], points) - 1.0) * 100.0

## Physics multipliers for the given effective stats.
static func multipliers(eff: Dictionary) -> Dictionary:
	var accel: float = pow(ACCEL_BASE, eff.acceleration - 5.0)
	var top: float = pow(TOP_SPEED_BASE, eff.top_speed - 5.0)
	return {
		# Lower final drive raises top speed but cuts wheel torque by the same
		# factor, so engine torque is scaled up by `top` to keep acceleration
		# independent of the top-speed stat.
		"torque": accel * top,
		"final_drive": 1.0 / top,
		"drag": 1.0 / top,
		"grip": pow(HANDLING_BASE, eff.handling - 5.0),
		"brake": pow(BRAKING_BASE, eff.braking - 5.0),
	}

static func _bonus(upgrade_id: String) -> float:
	return SaveData.get_upgrade_value(upgrade_id)
