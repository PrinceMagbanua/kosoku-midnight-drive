class_name CarManifest
extends RefCounted

## Reads the modular Synty car pack's cars_glb_manifest.json - the single
## source of truth for which cars, part slots, variants, wheels, tyres and
## paint textures exist (nothing about the pack is hardcoded elsewhere).
## Paths inside the manifest are relative to ROOT.
##
## A car's customization is a "loadout" Dictionary, the same shape everywhere
## (SaveData stores it per car id, ModularCarBuilder builds from it):
##   {
##     "slots": {"Bonnet": "01", "Spoiler": "", ...}, # "" (NONE) = nothing equipped
##     "wheel": "stock" | "07",                        # STOCK = the base car's own wheels
##     "tyre": "03",                                   # only used with a custom wheel
##     "paint": "PolygonStreetRacer_Texture_01_A.png", # file in TEXTURE_DIR
##     "tint": "light_smoke",                          # WindowTint preset id
##   }
## Always pass stored/edited loadouts through sanitize() - it repairs
## anything stale (a variant that no longer exists, a missing required slot).

const ROOT := "res://assets/cars/Kosoku_Cars_GLB/"
const MANIFEST_PATH := ROOT + "cars_glb_manifest.json"
## Per-part node lists written by the GLB conversion - used to map preset
## entries (prefab node names) back to slot + variant.
const REPORT_PATH := ROOT + "conversion_report.json"
const TEXTURE_DIR := ROOT + "textures/"
const THUMB_DIR := ROOT + "textures/thumbs/"

const STOCK := "stock"
const NONE := ""
const DEFAULT_PRESET := "Preset_01"

## Display/UI order for slots (front of the car to the back, then the rest).
## Slots the manifest has that aren't listed here are appended alphabetically.
const SLOT_ORDER := [
	"Front_Bumper", "Bonnet", "Light_Covers", "Nudge_Bar", "Fenders", "Side_Skirts",
	"Roof", "Roof_Scoop", "Windscreen_Sticker", "Louvers", "Rear_Bumper", "Spoiler",
	"Spoiler_Boot", "Exhaust", "Wheelie_Bars", "Rollcage", "Undercarriage",
]

static var _data: Dictionary = {}
static var _report: Dictionary = {}
static var _index_cache: Dictionary = {}

static func data() -> Dictionary:
	if _data.is_empty():
		_data = _read_json(MANIFEST_PATH)
		_report = _read_json(REPORT_PATH)
	return _data

static func _read_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		push_error("CarManifest: can't read %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

static func has_car(car: String) -> bool:
	return data().get("cars", {}).has(car)

static func _car(car: String) -> Dictionary:
	return data().get("cars", {}).get(car, {})

static func base_path(car: String) -> String:
	return ROOT + str(_car(car).get("base", ""))

## Slots of `car` in SLOT_ORDER.
static func slots(car: String) -> Array[String]:
	var all: Dictionary = _car(car).get("slots", {})
	var out: Array[String] = []
	for s in SLOT_ORDER:
		if all.has(s):
			out.append(s)
	var rest: Array = all.keys().filter(func(s): return not out.has(s))
	rest.sort()
	for s in rest:
		out.append(s)
	return out

static func is_required(car: String, slot: String) -> bool:
	return bool(_slot(car, slot).get("required", false))

## Variant ids ("01", "02", ...) sorted.
static func variants(car: String, slot: String) -> Array[String]:
	var keys: Array = _slot(car, slot).get("variants", {}).keys()
	keys.sort()
	var out: Array[String] = []
	for k in keys:
		out.append(str(k))
	return out

## What the player can pick for a slot: variants, plus NONE first for
## optional slots (required slots would leave holes in the body).
static func options(car: String, slot: String) -> Array[String]:
	var out: Array[String] = []
	if not is_required(car, slot):
		out.append(NONE)
	out.append_array(variants(car, slot))
	return out

static func part_path(car: String, slot: String, variant: String) -> String:
	var rel: String = str(_slot(car, slot).get("variants", {}).get(variant, ""))
	return ROOT + rel if not rel.is_empty() else ""

static func _slot(car: String, slot: String) -> Dictionary:
	return _car(car).get("slots", {}).get(slot, {})

# --- wheels / tyres ---------------------------------------------------------

## "01".."30", parsed from the manifest's file names.
static func wheel_ids() -> Array[String]:
	return _ids(data().get("wheels", []))

static func tyre_ids() -> Array[String]:
	return _ids(data().get("tyres", []))

static func wheel_path(id: String) -> String:
	return _path_for(data().get("wheels", []), id)

static func tyre_path(id: String) -> String:
	return _path_for(data().get("tyres", []), id)

static func _ids(paths: Array) -> Array[String]:
	var out: Array[String] = []
	for p in paths:
		out.append(str(p).get_file().get_basename().get_slice("_", 1))
	return out

static func _path_for(paths: Array, id: String) -> String:
	for p in paths:
		if str(p).get_file().get_basename().get_slice("_", 1) == id:
			return ROOT + str(p)
	return ""

# --- paint ------------------------------------------------------------------

## The 12 palette atlases ("Solid" in the UI).
static func solid_paints() -> Array[String]:
	return _strings(data().get("paint", {}).get("palette_atlases", []))

## The vinyl/livery textures (Pearl_* and Stripes_* are listed separately in
## the manifest and skipped - Pearl needed a Unity-only shader).
static func livery_paints() -> Array[String]:
	return _strings(data().get("paint", {}).get("vinyls", []))

static func all_paints() -> Array[String]:
	var out := solid_paints()
	out.append_array(livery_paints())
	return out

static func texture_path(file: String) -> String:
	return TEXTURE_DIR + file

static func thumb_path(file: String) -> String:
	return THUMB_DIR + file

## "PolygonStreetRacer_Veh_Tex_11_Flames.png" -> "FLAMES",
## "PolygonStreetRacer_Texture_02_B.png" -> "02 B".
static func paint_label(file: String) -> String:
	var stem := file.get_basename()
	for prefix in ["PolygonStreetRacer_Veh_Tex_", "PolygonStreetRacer_Texture_"]:
		if stem.begins_with(prefix):
			stem = stem.substr(prefix.length())
	if file.contains("_Veh_Tex_"):
		stem = stem.substr(stem.find("_") + 1) # drop the leading number
	return stem.replace("_", " ").to_upper()

static func _strings(arr: Array) -> Array[String]:
	var out: Array[String] = []
	for v in arr:
		out.append(str(v))
	return out

# --- loadouts ---------------------------------------------------------------

## A preset (e.g. "Preset_01") as a loadout. Presets list prefab node names,
## including sub-pieces ("Rear_Bumper_01_Exhaust", "Roof_01_Glass",
## "Spoiler_02_Boot") - each is mapped to the part that contains it.
static func preset_loadout(car: String, preset: String = DEFAULT_PRESET, paint: String = "") -> Dictionary:
	return sanitize(car, {"slots": _preset_slots(car, preset), "wheel": STOCK, "tyre": "", "paint": paint}, paint)

static func preset_names(car: String) -> Array[String]:
	var keys: Array = _car(car).get("presets", {}).keys()
	keys.sort()
	var out: Array[String] = []
	for k in keys:
		out.append(str(k))
	return out

## Prefab node name (without "SM_Veh_<car>_") -> [slot, variant], from the
## conversion report's per-part object lists. Falls back to "<Slot>_<NN>".
static func _node_index(car: String) -> Dictionary:
	data()
	if _index_cache.has(car):
		return _index_cache[car]
	var index := {}
	_index_cache[car] = index
	var prefix := "SM_Veh_%s_" % car
	for s in slots(car):
		for v in variants(car, s):
			index["%s_%s" % [s, v]] = [s, v]
			var stem := part_path(car, s, v).get_file().get_basename()
			var objects: Array = _report.get("%s/%s" % [car, stem], {}).get("objects", [])
			for o in objects:
				var name := str(o)
				if name.begins_with(prefix):
					index[name.substr(prefix.length())] = [s, v]
	return index

## Returns a valid copy of `loadout` for `car`: unknown slots dropped, missing
## or invalid entries replaced (required slots fall back to the preset's
## variant, else the first variant), wheel/tyre/paint/tint validated.
static func sanitize(car: String, loadout: Dictionary, default_paint: String = "") -> Dictionary:
	var src_slots: Dictionary = loadout.get("slots", {})
	var out_slots := {}
	var preset_slots: Dictionary = {}
	for s in slots(car):
		var v := str(src_slots.get(s, NONE))
		if not options(car, s).has(v):
			v = NONE
		if v == NONE and is_required(car, s):
			if preset_slots.is_empty():
				preset_slots = _preset_slots(car)
			v = str(preset_slots.get(s, NONE))
			if not variants(car, s).has(v):
				v = variants(car, s)[0]
		out_slots[s] = v

	var wheel := str(loadout.get("wheel", STOCK))
	if wheel != STOCK and not wheel_ids().has(wheel):
		wheel = STOCK
	var tyre := str(loadout.get("tyre", ""))
	if not tyre_ids().has(tyre):
		tyre = tyre_ids()[0] if not tyre_ids().is_empty() else ""
	var paint := str(loadout.get("paint", ""))
	if not all_paints().has(paint):
		paint = default_paint if all_paints().has(default_paint) else solid_paints()[0]
	var tint := str(loadout.get("tint", WindowTint.DEFAULT))
	if not WindowTint.TINTS.has(tint):
		tint = WindowTint.DEFAULT
	return {"slots": out_slots, "wheel": wheel, "tyre": tyre, "paint": paint, "tint": tint}

## Raw slot -> variant of a preset, without sanitizing (sanitize() uses it
## to fill required slots, so it must not call sanitize() itself). Slots the
## preset doesn't mention are absent (= NONE).
static func _preset_slots(car: String, preset: String = DEFAULT_PRESET) -> Dictionary:
	var out := {}
	var index := _node_index(car)
	for e in _car(car).get("presets", {}).get(preset, []):
		var hit: Variant = index.get(str(e))
		if hit != null:
			out[hit[0]] = hit[1]
	return out

## Every part scene path a car can use (for background preloading).
static func all_part_paths(car: String) -> Array[String]:
	var out: Array[String] = []
	for s in slots(car):
		for v in variants(car, s):
			out.append(part_path(car, s, v))
	return out
