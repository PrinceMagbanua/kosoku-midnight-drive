class_name UpgradeCatalog
extends RefCounted

## Static registry of the garage's upgrades - one tile each in the shop grid.
## Every level has its own gain and cost (see UpgradeRow); the big jumps are
## the milestone levels, priced ~2.3x the level before for ~2-2.5x its gain,
## so they feel like a payoff. Retune here - gameplay reads value_at() through
## SaveData.get_upgrade_value(), never per-tier constants of its own.
##
## Values:
##  accel/topSpeed/handling/braking - stat points (CarStats turns them into
##    physics multipliers; 1 point = ACCEL_BASE/TOP_SPEED_BASE/... ^1).
##  armor - extra HP per body panel (base panel 1.0, CarDamageModel).
##  nitro - boost force at full charge (NitroBoost); level 1 unlocks.
##  nitroFuel - seconds of boost from a full tank (+1 HUD bottle per level).
##  slowmo - 1 - world time scale at full slow-mo (SlowMo); level 1 unlocks.
##  slowmoFuel - real seconds of slow-mo from a full tank.

const ICON_PATH := "res://assets/icons/upgrade-icons/%s.svg"
const REFUND_FRACTION := 0.9

## Small, small, BIG, small, CAPSTONE - shared by the four car stats.
const STAT_STEPS: Array[float] = [0.4, 0.4, 0.8, 0.4, 1.0]

static func get_rows() -> Array[UpgradeRow]:
	var rows: Array[UpgradeRow] = []
	rows.append(_row("accel", "ACCELERATION",
		"Engine and turbo work. Pulls harder out of every gear.",
		UpgradeRow.Display.STAT, "acceleration", 0.0,
		STAT_STEPS, [600, 1000, 2400, 2900, 6500], [3, 5]))
	rows.append(_row("topSpeed", "TOP SPEED",
		"Taller gearing and less drag. Raises the car's top speed.",
		UpgradeRow.Display.STAT, "top speed", 0.0,
		STAT_STEPS, [700, 1200, 2800, 3300, 7500], [3, 5]))
	rows.append(_row("handling", "HANDLING",
		"Stickier tyres and stiffer suspension. More grip through corners and lane changes.",
		UpgradeRow.Display.STAT, "grip", 0.0,
		STAT_STEPS, [750, 1250, 2900, 3500, 8000], [3, 5]))
	rows.append(_row("braking", "BRAKING",
		"Bigger discs and calipers. Stops shorter.",
		UpgradeRow.Display.STAT, "braking", 0.0,
		STAT_STEPS, [600, 1000, 2400, 2900, 6500], [3, 5]))
	rows.append(_row("armor", "ARMOR",
		"Reinforced body panels. Bumpers, bonnet and doors take more hits before they tear off.",
		UpgradeRow.Display.PERCENT, "panel armor", 0.0,
		[0.10, 0.10, 0.20, 0.10, 0.10, 0.20, 0.25], [850, 1450, 3400, 4200, 5500, 9500, 14000], [3, 6]))
	rows.append(_row("nitro", "NITRO",
		"Hold to boost. Near misses and overtakes refill the bottles. Each level pushes harder.",
		UpgradeRow.Display.POWER, "boost power", 0.0,
		[2500.0, 1000.0, 1500.0, 1000.0, 1500.0], [1300, 2200, 5100, 6300, 14000], [3, 5]))
	rows.append(_row("nitroFuel", "NITRO FUEL",
		"Bigger N2O tank: more seconds of boost and an extra bottle on the HUD.",
		UpgradeRow.Display.SECONDS, "of boost", 4.0,
		[1.0, 1.0, 2.0, 2.0], [900, 1550, 3600, 5500], [3]))
	rows.append(_row("slowmo", "SPEEDBREAKER",
		"Hold to slow the world and strafe with A/D. Each level slows time further.",
		UpgradeRow.Display.TIME_SCALE, "World", 0.0,
		[0.45, 0.10, 0.05, 0.10], [1100, 1900, 4400, 6800], [4]))
	rows.append(_row("slowmoFuel", "SPEEDBREAKER TANK",
		"Longer Speedbreaker before the tank runs dry.",
		UpgradeRow.Display.SECONDS, "of slow-mo", 3.0,
		[1.0, 1.0, 1.5, 2.0], [900, 1550, 3600, 5500], [4]))
	return rows

static func _row(id: String, display_name: String, description: String,
		display: UpgradeRow.Display, effect_label: String, base_value: float,
		steps: Array[float], costs: Array[int], milestones: Array[int]) -> UpgradeRow:
	assert(steps.size() == costs.size(), "UpgradeCatalog: %s steps/costs differ" % id)
	var row := UpgradeRow.new()
	row.id = id
	row.display_name = display_name
	row.description = description
	row.display = display
	row.effect_label = effect_label
	row.base_value = base_value
	row.steps = steps
	row.costs = costs
	row.milestones = milestones
	row.refund_fraction = REFUND_FRACTION
	var icon_path := ICON_PATH % id
	if ResourceLoader.exists(icon_path):
		row.icon = load(icon_path)
	return row
