class_name CarCatalog
extends RefCounted

## Static registry of the selectable cars, in garage order (same pattern as
## UpgradeCatalog). Each car is a CarProfile .tres in MAIN/cars/profiles/,
## editable directly in the Godot inspector. The garage offers the five
## modular (customizable) cars (sports_02 is the AE86, built on Hatch_01's part set);
## coupe.tres is kept on disk but no longer
## listed. The coupe is still the physics reference: its
## authored 5/5/5/5 config is the baseline CarStats measures from, and base
## car.tscn is built around its hull (see CarConfigurator). To add a car,
## duplicate a .tres, set its id/hull_scene/manifest_id/stats, and add it to
## the list below.

const PROFILE_PATHS := [
	"res://MAIN/cars/profiles/sedan_01.tres",
	"res://MAIN/cars/profiles/sports_01.tres",
	"res://MAIN/cars/profiles/sports_02.tres",
	"res://MAIN/cars/profiles/hatch_01.tres",
	"res://MAIN/cars/profiles/muscle_01.tres",
]

static var _profiles: Array[CarProfile] = []

static func get_profiles() -> Array[CarProfile]:
	if _profiles.is_empty():
		for path in PROFILE_PATHS:
			_profiles.append(load(path) as CarProfile)
	return _profiles

static func count() -> int:
	return get_profiles().size()

## Out-of-range indices are clamped, so a stale saved index can't crash.
static func get_profile(index: int) -> CarProfile:
	var profiles := get_profiles()
	return profiles[clampi(index, 0, profiles.size() - 1)]

static func index_of(id: String) -> int:
	var profiles := get_profiles()
	for i in profiles.size():
		if profiles[i].id == id:
			return i
	return 0
