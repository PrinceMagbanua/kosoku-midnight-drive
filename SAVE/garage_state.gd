class_name GarageState
extends Resource

## Mirrors Voxel Driver's `garageState` (core.js) - persisted separately from
## difficulty/transmission/handling so each can be reset/migrated independently.

@export var cash: int = 0
@export var upgrades: Dictionary = {} ## upgrade id (String) -> tier (int)
@export var paint: String = "stock"
@export var wheel_color: String = "stock"
@export var selected_car_index: int = 0 ## index into CarCatalog.get_profiles()
## Car ids the player owns. Every car counts as owned for now (nothing sells
## them yet) - the garage's BUY button will start writing here later.
## SaveData also adds any free catalog car missing here (older saves).
@export var owned_cars: Array[String] = ["sedan_01", "sports_01", "sports_02", "hatch_01", "muscle_01"]
## Customize screen: car id -> loadout Dictionary (shape documented in
## CarManifest). Cars without an entry use their Preset_01 look.
@export var car_loadouts: Dictionary = {}
@export var furthest_biome_index: int = 0
@export var furthest_dist: float = 0.0
## Upgrade shop layout this save was last migrated to (SaveData.UPGRADE_VERSION).
## 0 = an old save from before the icon-grid shop - SaveData refunds it once.
@export var upgrade_version: int = 0
## One-time tip cards already shown (upgrade ids, e.g. "nitro").
@export var seen_tips: Array[String] = []

func get_upgrade_tier(id: String) -> int:
	return upgrades.get(id, 0)

func set_upgrade_tier(id: String, tier: int) -> void:
	upgrades[id] = tier
