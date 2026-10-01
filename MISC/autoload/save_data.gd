extends Node

## Autoload. Owns the player's persisted profile (cash/upgrades/difficulty/
## transmission+handling mode/high score) - the Godot equivalent of Voxel
## Driver's several independent localStorage-backed objects (garageState,
## difficultySettings, transmissionSettings, handlingSettings, highScore),
## just merged into one Resource so there's a single load/save call instead
## of five. Screens read/write `SaveData.game` directly and call `save()`
## whenever a purchase/toggle happens (matches the original's explicit
## save-on-mutation pattern rather than autosaving every frame).

const SAVE_PATH := "user://savegame.tres"
## Bump when the upgrade shop changes shape (see _migrate_upgrades).
const UPGRADE_VERSION := 2
## The pre-grid shop (UPGRADE_ROWS from Voxel Driver), only to refund old
## saves: id -> [base cost, max tier]; tier t cost round(base * 1.7^t).
const _OLD_UPGRADES := {
	"accel": [590, 5], "braking": [590, 5], "handling": [725, 5], "topSpeed": [500, 12],
	"armor": [865, 5], "ramPower": [1000, 3], "insurance": [2090, 3], "hornRange": [725, 3],
	"nitro": [1275, 3], "nitroFuel": [900, 3], "slowmo": [1100, 3], "slowmoFuel": [900, 3],
	"strongerLights": [700, 5], "aggressiveNpcs": [1725, 1], "blockers": [2090, 1],
	"heavyTraffic": [1365, 5], "rainAmount": [1200, 5], "night": [2200, 1],
	"blackoutChance": [1100, 5], "highwayCurves": [2275, 1], "moreHazards": [1180, 3],
}
const _OLD_COST_EXPONENT := 1.7

var game: SaveGame
var upgrade_rows: Array[UpgradeRow] = UpgradeCatalog.get_rows()

func _ready() -> void:
	ensure_loaded()

## Autoload _ready() runs AFTER the main scene's _enter_tree(), so anything
## that needs the save that early (CarProfileApplier) calls this first.
func ensure_loaded() -> void:
	if game == null:
		load_game()

func load_game() -> void:
	if ResourceLoader.exists(SAVE_PATH):
		var loaded := ResourceLoader.load(SAVE_PATH, "SaveGame", ResourceLoader.CACHE_MODE_IGNORE)
		if loaded is SaveGame:
			game = loaded
			_migrate()
			return
	game = new_game()

## A fresh profile, already on the current upgrade layout (so it's never
## mistaken for an old save and "refunded" later).
func new_game() -> SaveGame:
	var g := SaveGame.new()
	g.garage.upgrade_version = UPGRADE_VERSION
	return g

## Older saves list the retired coupe/italia/kamaro as owned - every current
## catalog car is free, so make sure each counts as owned.
func _migrate() -> void:
	for profile in CarCatalog.get_profiles():
		if profile.price == 0 and not game.garage.owned_cars.has(profile.id):
			game.garage.owned_cars.append(profile.id)
	_migrate_upgrades()

## The icon-grid shop replaced every tier table (and dropped the map,
## coming-soon and insurance upgrades): refund everything ever spent on
## upgrades at the old prices, once, and start all levels from 0.
func _migrate_upgrades() -> void:
	var garage := game.garage
	if garage.upgrade_version >= UPGRADE_VERSION:
		return
	var d := game.difficulty
	var tiers: Dictionary = garage.upgrades.duplicate()
	tiers.merge({
		"heavyTraffic": d.heavy_traffic, "rainAmount": d.rain_amount,
		"aggressiveNpcs": d.aggressive_npcs, "night": 1 if d.night else 0,
		"blockers": d.blockers, "highwayCurves": d.highway_curves,
		"moreHazards": d.more_hazards, "blackoutChance": int(d.blackout_chance),
	}, true)
	var refund := 0
	for id in tiers:
		if not _OLD_UPGRADES.has(id):
			continue
		var old: Array = _OLD_UPGRADES[id]
		for t in clampi(int(tiers[id]), 0, old[1]):
			refund += int(round(float(old[0]) * pow(_OLD_COST_EXPONENT, t)))
	garage.cash += refund
	garage.upgrades.clear()
	game.difficulty = DifficultySettings.new()
	garage.upgrade_version = UPGRADE_VERSION
	save()
	if refund > 0:
		print("[SaveData] upgrade shop changed - refunded $%d of old upgrades" % refund)

func save() -> void:
	ResourceSaver.save(game, SAVE_PATH)

## Emitted when the garage picks a different car (see CarProfileApplier).
signal selected_car_changed(index: int)
## Emitted after any upgrade is bought or sold (car stats depend on them).
signal upgrades_changed

func get_selected_car_index() -> int:
	ensure_loaded()
	return clampi(game.garage.selected_car_index, 0, CarCatalog.count() - 1)

func set_selected_car(index: int) -> void:
	ensure_loaded()
	index = clampi(index, 0, CarCatalog.count() - 1)
	if index == game.garage.selected_car_index:
		return
	game.garage.selected_car_index = index
	save()
	selected_car_changed.emit(index)

## Emitted when a car's customization loadout changes (see CarProfileApplier).
signal loadout_changed(car_id: String)

## The car's loadout (CarManifest shape), always valid: the saved one if any,
## else its Preset_01 look. Empty for an old non-modular car.
func get_loadout(car_id: String) -> Dictionary:
	ensure_loaded()
	var profile := CarCatalog.get_profile(CarCatalog.index_of(car_id))
	if profile.id != car_id or profile.manifest_id.is_empty():
		return {}
	var saved: Variant = game.garage.car_loadouts.get(car_id)
	if saved is Dictionary and not (saved as Dictionary).is_empty():
		return CarManifest.sanitize(profile.manifest_id, saved, profile.default_paint)
	return CarManifest.preset_loadout(profile.manifest_id, CarManifest.DEFAULT_PRESET, profile.default_paint)

## Stores a loadout and re-dresses the cars showing it. `persist` = false
## lets the Customize screen update the cars live while editing and write
## the save once on the way out (its Back button calls save()).
func set_loadout(car_id: String, loadout: Dictionary, persist: bool = true) -> void:
	ensure_loaded()
	game.garage.car_loadouts[car_id] = loadout.duplicate(true)
	if persist:
		save()
	loadout_changed.emit(car_id)

func owns_car(id: String) -> bool:
	ensure_loaded()
	return game.garage.owned_cars.has(id)

## Buys the car with this id at its catalog price. Returns false if already
## owned or not affordable. (Every car is pre-owned for now.)
func buy_car(id: String) -> bool:
	ensure_loaded()
	var profile := CarCatalog.get_profile(CarCatalog.index_of(id))
	if owns_car(id) or game.garage.cash < profile.price:
		return false
	game.garage.cash -= profile.price
	game.garage.owned_cars.append(id)
	save()
	return true

func get_upgrade_row(id: String) -> UpgradeRow:
	for row in upgrade_rows:
		if row.id == id:
			return row
	return null

func get_upgrade_tier(id: String) -> int:
	ensure_loaded()
	var row := get_upgrade_row(id)
	if row == null:
		return 0
	return clampi(game.garage.get_upgrade_tier(id), 0, row.max_tier)

## The upgrade's summed effect at its current level (UpgradeRow.value_at) -
## what gameplay reads. 0 for an unknown id.
func get_upgrade_value(id: String) -> float:
	var row := get_upgrade_row(id)
	if row == null:
		return 0.0
	return row.value_at(get_upgrade_tier(id))

func can_afford_upgrade(id: String) -> bool:
	var row := get_upgrade_row(id)
	if row == null:
		return false
	var tier := get_upgrade_tier(id)
	if tier >= row.max_tier:
		return false
	return game.garage.cash >= row.cost_for_tier(tier)

func buy_upgrade(id: String) -> bool:
	if not can_afford_upgrade(id):
		return false
	var row := get_upgrade_row(id)
	var tier := get_upgrade_tier(id)
	game.garage.cash -= row.cost_for_tier(tier)
	game.garage.set_upgrade_tier(id, tier + 1)
	save()
	upgrades_changed.emit()
	return true

func sell_upgrade(id: String) -> bool:
	var row := get_upgrade_row(id)
	if row == null:
		return false
	var tier := get_upgrade_tier(id)
	if tier <= 0:
		return false
	game.garage.cash += row.refund_for_tier(tier - 1)
	game.garage.set_upgrade_tier(id, tier - 1)
	save()
	upgrades_changed.emit()
	return true

## Cash REFUND ALL would give back right now.
func refund_all_total() -> int:
	var total := 0
	for row in upgrade_rows:
		for t in get_upgrade_tier(row.id):
			total += row.refund_for_tier(t)
	return total

## Sells every level of every upgrade. Returns the cash refunded.
func refund_all() -> int:
	var total := refund_all_total()
	if total <= 0:
		return 0
	game.garage.cash += total
	game.garage.upgrades.clear()
	save()
	upgrades_changed.emit()
	return total

func has_seen_tip(id: String) -> bool:
	ensure_loaded()
	return game.garage.seen_tips.has(id)

func mark_tip_seen(id: String) -> void:
	if has_seen_tip(id):
		return
	game.garage.seen_tips.append(id)
	save()

## Dev console "Max all upgrades" - sets a tier directly (no cash involved).
## Caller saves and emits upgrades_changed once after a batch.
func set_upgrade_tier(id: String, tier: int) -> void:
	var row := get_upgrade_row(id)
	if row:
		game.garage.set_upgrade_tier(id, clampi(tier, 0, row.max_tier))
