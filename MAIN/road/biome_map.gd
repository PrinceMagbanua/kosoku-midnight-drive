class_name BiomeMap
extends RefCounted

## Minimal biome tagging - divides the road into large contiguous regions
## (REGION_LENGTH each) and deterministically hashes each region (keyed by
## the current run's RoadPath.seed_value, same seeding convention
## road_generator.gd/road_path.gd already use) into a small set of weather
## profiles. Deliberately just "an id + a rain_chance" for now - the
## commented-out "biome tint" idea in road_generator.gd/road_path.gd stays
## out of scope; this only exists to give Weather (autoload) something to
## roll rain odds against, in stable multi-chunk zones rather than a flat
## global timer.
##
## Reads as a "place where rain is endless" when a region rolls DOWNPOUR
## (rain_chance 1.0) - Weather treats that as an immediate, sustained rain
## zone rather than something it merely rolls dice about periodically.

const REGION_LENGTH := 4000.0 * RoadMetrics.UNIT_SCALE

const DOWNPOUR_ROLL := 0.02 # 2% of regions - a sustained "always raining" zone
const RAINY_ROLL := 0.35 # next 33% - elevated chance of a rain shower
# everything else - normal region, rain is rare

## Forest stretches - a separate, shorter zoning from the weather regions
## above, so a forest doesn't always coincide with a weather change.
## Length is a whole number of road chunks (RoadGenerator.CHUNK_LENGTH =
## 112 m) so a forest always starts/ends on a chunk seam. In a forest chunk
## the buildings are dropped and the trees get dense (roadside_trees.gd).
const FOREST_REGION_LENGTH := 112.0 * 14.0 * RoadMetrics.UNIT_SCALE
const FOREST_ROLL := 0.3

static func is_forest(dist: float, seed_value: int) -> bool:
	var region := int(floor(dist / FOREST_REGION_LENGTH))
	var h := hash(Vector2i(region, seed_value ^ 0x5eed))
	return float(absi(h) % 10000) / 10000.0 < FOREST_ROLL

## Soft version of is_forest() for ground colouring: 1 inside a forest region,
## 0 in a city one, ramping linearly over FOREST_BLEND_LENGTH either side of a
## region boundary where the two differ, so grass and city concrete fade
## into each other instead of switching at a hard line.
const FOREST_BLEND_LENGTH := 20.0 * RoadMetrics.UNIT_SCALE

static func forest_weight(dist: float, seed_value: int) -> float:
	var here := 1.0 if is_forest(dist, seed_value) else 0.0
	var start := floorf(dist / FOREST_REGION_LENGTH) * FOREST_REGION_LENGTH
	var from_start := dist - start
	var to_end := start + FOREST_REGION_LENGTH - dist
	if from_start < FOREST_BLEND_LENGTH:
		var prev := 1.0 if is_forest(start - 1.0, seed_value) else 0.0
		return lerpf(prev, here, 0.5 + 0.5 * from_start / FOREST_BLEND_LENGTH)
	if to_end < FOREST_BLEND_LENGTH:
		var next := 1.0 if is_forest(start + FOREST_REGION_LENGTH + 1.0, seed_value) else 0.0
		return lerpf(next, here, 0.5 + 0.5 * to_end / FOREST_BLEND_LENGTH)
	return here

static func get_biome(dist: float, seed_value: int) -> Dictionary:
	var region := int(floor(dist / REGION_LENGTH))
	var h := hash(Vector2i(region, seed_value))
	var roll := float(absi(h) % 10000) / 10000.0
	if roll < DOWNPOUR_ROLL:
		return {"id": "downpour", "rain_chance": 1.0}
	elif roll < RAINY_ROLL:
		return {"id": "rainy", "rain_chance": 0.55}
	else:
		return {"id": "clear", "rain_chance": 0.05}
