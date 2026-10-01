class_name UpgradeRow
extends Resource

## One purchasable upgrade in the garage's icon grid (see
## SAVE/upgrade_catalog.gd). Every level has its own cost and its own gain, so
## levels can be uneven (small, small, BIG, small, CAPSTONE) - gameplay reads
## the summed result through value_at() / SaveData.get_upgrade_value().

## How effect_text() describes the value.
## STAT: stat points, shown as the physics % gain (CarStats.upgrade_gain_pct).
## PERCENT: a fraction shown as +N% (armor HP).
## POWER: level 1 unlocks, later levels shown relative to level 1 (nitro force).
## SECONDS: seconds of tank.
## TIME_SCALE: level 1 unlocks; value is 1 - world speed (Speedbreaker).
enum Display { STAT, PERCENT, POWER, SECONDS, TIME_SCALE }

@export var id: String
@export var display_name: String
@export_multiline var description: String = ""
## Cost of each level (index 0 = level 1). Its size is the level count.
@export var costs: Array[int] = []
## What each level adds (index 0 = level 1), on top of base_value.
@export var steps: Array[float] = []
## The value with no levels bought.
@export var base_value: float = 0.0
## Levels that are the big jumps - drawn as wider pips on the tile.
@export var milestones: Array[int] = []
@export var display: Display = Display.PERCENT
## Noun for effect_text(), e.g. "top speed", "panel armor", "of boost".
@export var effect_label: String = ""
@export var refund_fraction: float = 0.9
@export var icon: Texture2D

var max_tier: int:
	get:
		return costs.size()

func cost_for_tier(tier: int) -> int:
	return costs[tier]

## Cash back for selling level `tier + 1` (index like cost_for_tier).
func refund_for_tier(tier: int) -> int:
	return int(round(costs[tier] * refund_fraction))

func value_at(tier: int) -> float:
	var v := base_value
	for i in mini(tier, steps.size()):
		v += steps[i]
	return v

## Player-facing effect at `tier`, e.g. "+5.4% top speed", "LOCKED".
func effect_text(tier: int) -> String:
	var v := value_at(tier)
	match display:
		Display.STAT:
			if tier == 0:
				return "STOCK"
			return "+%s%% %s" % [_num(CarStats.upgrade_gain_pct(id, v)), effect_label]
		Display.PERCENT:
			if tier == 0:
				return "STOCK"
			return "+%d%% %s" % [roundi(v * 100.0), effect_label]
		Display.POWER:
			if tier == 0:
				return "LOCKED"
			if tier == 1:
				return "UNLOCKED"
			return "+%d%% %s" % [roundi((v / value_at(1) - 1.0) * 100.0), effect_label]
		Display.SECONDS:
			return "%s s %s" % [_num(v), effect_label]
		Display.TIME_SCALE:
			if tier == 0:
				return "LOCKED"
			return "%s at %d%% speed" % [effect_label, roundi((1.0 - v) * 100.0)]
	return ""

## One decimal only when it isn't a whole number ("6", "5.4").
static func _num(x: float) -> String:
	var r := snappedf(x, 0.1)
	return str(int(r)) if is_equal_approx(r, roundf(r)) else "%.1f" % r
