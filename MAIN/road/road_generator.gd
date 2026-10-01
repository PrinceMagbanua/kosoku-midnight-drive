@tool
extends Node3D

## Procedural highway - MVP port of core.js's road system (buildRoadMesh/
## buildLaneDashes/buildRoadBarrier), now with curves/elevation/banking - see
## the plan file's "curves, elevation/banking, biome tinting, and particle
## effects" section. Scope note: the original generates one 60000-unit mesh
## and windows visibility with setDrawRange - that doesn't work in Godot the
## way it does in three.js (60000 units of resident mesh isn't reasonable
## here), so this instead generates/frees chunks in a sliding window ahead
## of / behind the car, which is the idiomatic Godot equivalent of the same
## "only draw what's near the player" goal.
##
## The actual curve/bank/grade MATH lives in RoadPath (road_path.gd) - a
## lightweight precomputed point array generated once per run, kept
## separate from these 3D mesh chunks (which stay streamed/windowed exactly
## as before). This file just SAMPLES that path (via `RoadPath.world_pos()`)
## to build each chunk's geometry, instead of the old flat `Vector3(x,0,z)`
## math. `PathTracker` (path_tracker.gd) estimates the player's distance
## ALONG the (now curving) path for chunk-window/traffic/scoring purposes,
## since the player is a real free-roaming RigidBody3D (not locked to the
## track like the original's simplified travel model) - "dist" and
## "global_position.z" stopped being interchangeable once the road curves.
##
## Deliberately NOT ported (real scope, not an oversight): exit gantries,
## bridges, toll gates/widening, tunnels - decoration systems layered on top
## of chapter types the original's own geometry doesn't actually need for
## curves/grade/banking (every chapter here is geometrically either
## `sweeper` or `plain`, matching the original's real geometry per the
## research this was based on). Biome tint touches road/shoulder/edge-line/
## guardrail color only, NOT fog/sky/light (confirmed out of the original's
## own scope too).
##
## `@tool`: `@tool` mode builds a small static preview around the origin so
## scale/curve/banking is visible and checkable in the editor viewport
## without pressing Play. The preview chunks are never `owner`-assigned, so
## they render live but are never written into world.tscn.
##
## Lane count/width live in RoadMetrics (road_metrics.gd), not here - the
## traffic system needs the exact same numbers and Voxel Driver has a
## documented regression from those two ever drifting apart.

## Streetlight fake-cone tuning - exposed here (Inspector, select the
## RoadGenerator node) instead of hardcoded, so this can be tuned by eye
## without editing code. After changing a value, use the "Rebuild Editor
## Preview" button below to see it in the editor's static preview chunks -
## `_ready()` only builds those once, so a plain property change alone
## won't refresh them on its own.
@export_group("Streetlights")
@export var streetlight_cone_angle_deg: float = 18.0
@export_range(0.0, 1.0) var streetlight_cone_apex_alpha: float = 0.0
@export_range(0.0, 1.0) var streetlight_cone_base_alpha: float = 0.22
@export var streetlight_cone_color: Color = Color(1.0, 0.85, 0.55)
## Lamp head brightness. Bloom (world.tscn's Environment glow) only picks up
## pixels brighter than its HDR threshold (1.0 by default), so this needs to
## sit well above 1 for the heads to visibly glow - was 1.2, barely at it.
@export_range(0.0, 16.0) var streetlight_glow_energy: float = 4.0
## Real SpotLight3D under each lamp head, pointing straight down (see
## _make_streetlight()). Off = fake cone only, as before.
@export var streetlight_real_light: bool = true
@export_range(0.0, 16.0) var streetlight_light_energy: float = 2.0
## spot_range = lamp height * this - a bit over 1 so the pool reaches the road.
@export var streetlight_light_range_mult: float = 1.6
@export_range(1.0, 89.0) var streetlight_light_angle_deg: float = 55.0
## Camera distance (units) where a lamp's light starts fading out; fully gone
## ~100 units later, so far-off lamps cost nothing.
@export var streetlight_light_fade_begin: float = 250.0
@export_tool_button("Rebuild Editor Preview") var rebuild_preview_button: Callable = _rebuild_editor_preview

## Which building set lines the road: the night-city towers
## (assets/buildings/night/) or the original Voxel Driver pack. Hit
## "Rebuild Editor Preview" after toggling to see it in the editor.
@export_group("Buildings")
@export var use_night_buildings: bool = true

## Sparse fallen leaves on the shoulders (see road_leaves.gd). Only affects
## chunks built after a change - hit "Rebuild Editor Preview" in the editor.
@export_group("Road Leaves")
@export var road_leaves_enabled: bool = true
@export_range(0.0, 4.0) var road_leaf_density: float = 1.0

## The Akashi-style suspension bridge (road_suspension.gd). Only affects the
## NEXT run (or "Rebuild Editor Preview" in the editor).
@export_group("Suspension Bridge")
## How many of a run's sea bridges - the first ones planned - are suspension
## bridges; the rest stay plain viaducts.
@export_range(0, 8) var suspension_bridges: int = 1
## The beads of light along the two main cables.
@export var bridge_cable_light_color: Color = Color(0.85, 0.95, 1.0)
@export_range(0.0, 16.0) var bridge_cable_light_energy: float = 5.0
## Floodlighting on the towers (0 = unlit).
@export_range(0.0, 4.0) var bridge_tower_light_energy: float = 0.8

## Tunnels / sea bridges / overpasses - planned per run by RoadLayout. Only
## affects the NEXT run (or "Rebuild Editor Preview" in the editor).
@export_group("Road Features")
@export var first_feature_m: float = 1500.0
@export var feature_gap_min_m: float = 1500.0
@export var feature_gap_max_m: float = 3500.0
## Share of features that are tunnels (the rest are sea bridges).
@export_range(0.0, 1.0) var tunnel_weight: float = 0.55
## Straight (optionally diagonal) flyovers - see road_overpass.gd.
@export var overpasses_enabled: bool = true
## Testing aid: put this feature ~350 m after the start of every run (and in
## the editor preview when "Preview At Feature" is on).
@export var debug_first_feature: RoadLayout.Feature = RoadLayout.Feature.RANDOM
## Editor preview only: build the preview chunks around the first planned
## feature (its lane taper) instead of around the origin.
@export var preview_at_feature: bool = false

const UNIT_SCALE := RoadMetrics.UNIT_SCALE
const LANES := RoadMetrics.LANES
const ROAD_HALF_WIDTH := RoadMetrics.ROAD_HALF_WIDTH
const LANE_WIDTH := RoadMetrics.LANE_WIDTH
const SHOULDER_HALF_WIDTH := ROAD_HALF_WIDTH + 2.2 * UNIT_SCALE
const FENCE_HALF_WIDTH := SHOULDER_HALF_WIDTH + 0.35 * UNIT_SCALE

const ROAD_SURFACE_SHADER := preload("res://MAIN/road/road_surface.gdshader")
const BARRIER_SHADER := preload("res://MAIN/road/barrier_concrete.gdshader")
# One material shared by every barrier wall (all its params are uniform
# defaults) - tune it in barrier_concrete.gdshader's uniform defaults.
var _barrier_material: ShaderMaterial = _make_barrier_material()

static func _make_barrier_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = BARRIER_SHADER
	return mat

# Shared by every delineator - tune in delineator.gdshader's uniform defaults.
var _delineator_material: ShaderMaterial = _make_delineator_material()

static func _make_delineator_material() -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = DELINEATOR_SHADER
	return mat

# CHUNK_LENGTH is now a span of DIST (arc-length along the path), not raw
# world Z - deliberately == 8 * RoadPath.SEG_LEN, so each chunk covers
# exactly 8 path-point rows.
const CHUNK_LENGTH := 112.0 * UNIT_SCALE
const GENERATE_AHEAD := 600.0 * UNIT_SCALE
const REMOVE_BEHIND := 150.0 * UNIT_SCALE

# How many sub-samples to take per RoadPath row when building the ribbon
# mesh/ground collision. RoadPath.road_frame() now reconstructs a smooth
# Hermite curve BETWEEN stored points (see road_path.gd) instead of a
# straight lerp - but that only matters if something actually samples INSIDE
# a row. The old per-row quad (corners only at each row's two endpoints)
# would still chord straight across a row's span even with a curved
# road_frame() underneath, since it never evaluates any distance strictly
# between them. This subdivides each row into ROW_SUBDIVISIONS smaller
# quads instead, so the built mesh/collision actually traces the curve.
const ROW_SUBDIVISIONS := 4

const DASH_LEN := 2.4 * UNIT_SCALE
const DASH_GAP := 2.2 * UNIT_SCALE
const DASH_WIDTH := 0.22 * UNIT_SCALE
const DASH_HEIGHT := 0.02 * UNIT_SCALE
const DASH_STEP := DASH_LEN + DASH_GAP

# Jersey barrier (RoadBarriers JERSEY) - one continuous extruded wall per side,
# swept along the path like the road ribbon rather than a row of box segments.
# FENCE_PROFILE is its cross-section, a Jersey-barrier-ish shape: (u, h) with
# u = offset outward from FENCE_HALF_WIDTH and h = height above the ground,
# listed inner-bottom -> over the top -> outer-bottom. Bottom starts slightly
# below ground so no seam shows where it meets the grass.
const FENCE_HEIGHT := 1.1 * UNIT_SCALE
const FENCE_PROFILE: Array[Vector2] = [
	Vector2(-0.30 * UNIT_SCALE, -0.05 * UNIT_SCALE),
	Vector2(-0.24 * UNIT_SCALE, 0.25 * UNIT_SCALE),
	Vector2(-0.10 * UNIT_SCALE, FENCE_HEIGHT),
	Vector2(0.10 * UNIT_SCALE, FENCE_HEIGHT),
	Vector2(0.24 * UNIT_SCALE, 0.25 * UNIT_SCALE),
	Vector2(0.30 * UNIT_SCALE, -0.05 * UNIT_SCALE),
]


const WALL_HEIGHT := 2.0 * UNIT_SCALE
const WALL_THICKNESS := 0.3 * UNIT_SCALE

# Roadside ground bands (grass/sidewalk) - core.js's buildRoadside(), simple
# flat colored ribbons here rather than textured meshes.
const GRASS_HALF_WIDTH := FENCE_HALF_WIDTH + 3.0 * UNIT_SCALE
const SIDEWALK_HALF_WIDTH := GRASS_HALF_WIDTH + 2.0 * UNIT_SCALE

# Level ground beyond the sidewalk (see _ground_pos / _build_terrain_mesh):
# lateral distances (from the sidewalk edge outward) where the terrain's
# vertex colour steps, out to the far edge.
const TERRAIN_BANDS: Array[float] = [60.0 * UNIT_SCALE, 160.0 * UNIT_SCALE, 400.0 * UNIT_SCALE]
# Finer version near hill tunnels, so the hill's flanks come out round.
const TERRAIN_FINE_BANDS: Array[float] = [
	6.0 * UNIT_SCALE, 12.0 * UNIT_SCALE, 20.0 * UNIT_SCALE, 30.0 * UNIT_SCALE, 42.0 * UNIT_SCALE,
	56.0 * UNIT_SCALE, 72.0 * UNIT_SCALE, 92.0 * UNIT_SCALE, 120.0 * UNIT_SCALE, 160.0 * UNIT_SCALE,
	400.0 * UNIT_SCALE,
]
const TERRAIN_NEAR_COLOR := Color(0.16, 0.32, 0.14) # same green as the road-side grass band
const TERRAIN_FAR_COLOR := Color(0.09, 0.19, 0.09)
# City stretches (anything that isn't a forest - that's where the buildings
# are) get dark grey ground instead of grass. Blended by BiomeMap.forest_weight,
# and the urban amount is also written to vertex COLOR.a so
# road_surface.gdshader draws concrete detail there instead of grass detail.
const TERRAIN_URBAN_NEAR_COLOR := Color(0.20, 0.20, 0.21)
const TERRAIN_URBAN_FAR_COLOR := Color(0.12, 0.12, 0.13)

# Buildings - real Voxel Driver assets (assets/buildings/), restricted to
# exactly the set building-overrides.json (Voxel Driver project root) marks
# eligible - most of the pack is in its "excluded" list (bad scale/visual
# issues per the original's own hand-tuning) and must NOT be shown. Footprint
# scaling matches js/voxel-assets.js's buildVoxelBuilding() exactly: each
# building scales uniformly so max(nativeWidth, nativeDepth) hits a target
# footprint - the override value where building-overrides.json specifies
# one, else a random pick in [BUILDING_TARGET_FOOTPRINT_MIN, _MAX]. Overlap
# avoidance (buildBuildings()'s per-side footprint-aware spacing) is NOT
# ported - fixed spacing + jitter instead, not worth the complexity for how
# visually similar the result is; occasional close spacing is acceptable.
const BUILDING_OFFSET := SIDEWALK_HALF_WIDTH + 0.4 * UNIT_SCALE
const BUILDING_SPACING := 15.0 * UNIT_SCALE
const BUILDING_SPAWN_CHANCE := 0.55
const BUILDING_SINK := 0.05 * UNIT_SCALE # how far a building base is pushed into the ground so no seam shows
const BUILDING_TARGET_FOOTPRINT_MIN := 15.0 # metres, matches voxel-assets.js
const BUILDING_TARGET_FOOTPRINT_MAX := 23.0

const BUILDING_SPECS: Array[Dictionary] = [
	{"name": "building-carwash", "scene": preload("res://assets/buildings/building-carwash.glb")},
	{"name": "building-hospital", "scene": preload("res://assets/buildings/building-hospital.glb")},
	{"name": "building-office", "scene": preload("res://assets/buildings/building-office.glb")},
	{"name": "building-office-big", "scene": preload("res://assets/buildings/building-office-big.glb")},
	{"name": "building-office-big-old", "scene": preload("res://assets/buildings/building-office-big-old.glb")},
	{"name": "building-office-pyramid", "scene": preload("res://assets/buildings/building-office-pyramid.glb")},
	{"name": "building-office-rounded", "scene": preload("res://assets/buildings/building-office-rounded.glb")},
	{"name": "building-office-tall", "scene": preload("res://assets/buildings/building-office-tall.glb")},
	{"name": "building-policestation", "scene": preload("res://assets/buildings/building-policestation.glb")},
	{"name": "data-center", "scene": preload("res://assets/buildings/data-center.glb")},
	{"name": "industry-factory", "scene": preload("res://assets/buildings/industry-factory.glb")},
]

# Night-city towers - split out of a single "Background_Night_Buildings"
# scene (originals in assets/buildings/buildings-test/, Draco-compressed so
# Godot can't import them). These are decompressed copies re-pivoted so the
# base centre sits at the origin, same convention as the set above. No
# footprint overrides - they use the random target range.
const NIGHT_BUILDING_SPECS: Array[Dictionary] = [
	{"name": "building-night-01", "scene": preload("res://assets/buildings/night/building-night-01.glb")},
	{"name": "building-night-02", "scene": preload("res://assets/buildings/night/building-night-02.glb")},
	{"name": "building-night-03", "scene": preload("res://assets/buildings/night/building-night-03.glb")},
	{"name": "building-night-04", "scene": preload("res://assets/buildings/night/building-night-04.glb")},
	{"name": "building-night-05", "scene": preload("res://assets/buildings/night/building-night-05.glb")},
	{"name": "building-night-06", "scene": preload("res://assets/buildings/night/building-night-06.glb")},
	{"name": "building-night-07", "scene": preload("res://assets/buildings/night/building-night-07.glb")},
	{"name": "building-night-08", "scene": preload("res://assets/buildings/night/building-night-08.glb")},
	{"name": "building-night-09", "scene": preload("res://assets/buildings/night/building-night-09.glb")},
	{"name": "building-night-10", "scene": preload("res://assets/buildings/night/building-night-10.glb")},
	{"name": "building-night-11", "scene": preload("res://assets/buildings/night/building-night-11.glb")},
	{"name": "building-night-12", "scene": preload("res://assets/buildings/night/building-night-12.glb")},
	{"name": "building-night-13", "scene": preload("res://assets/buildings/night/building-night-13.glb")},
]

const BUILDING_FOOTPRINT_OVERRIDES := {
	"building-hospital": 15.0,
	"building-office-big": 19.0,
	"building-office-pyramid": 18.5,
	"building-office-rounded": 17.5,
	"building-office-tall": 19.5,
	"building-office": 20.5,
	"data-center": 25.0,
	"industry-factory": 23.5,
}

# Streetlights - no model exists in the source asset pack, so this is a
# simple procedural pole+lamp prop: a real downward SpotLight3D plus a fake
# translucent cone for the beam (see _make_streetlight()).
# Expressway scale: ~12 m mounting height (~8-9x the car's height), one pole
# per side every STREETLIGHT_SPACING, the two sides staggered by half that.
const STREETLIGHT_SPACING := 112.0 * UNIT_SCALE
const STREETLIGHT_HEIGHT := 12.0 * UNIT_SCALE

# Yellow retroreflective delineators on the barriers' road-facing side, only
# through curves (see RoadBarriers._delineators / delineator.gdshader).
const DELINEATOR_SHADER := preload("res://MAIN/road/delineator.gdshader")
const DELINEATOR_SPACING := 6.0 * UNIT_SCALE
# |curvature| (rad per unit of path distance) above which a curve gets markers -
# a quarter of the path generator's peak sustained curvature.
const DELINEATOR_CURVE_THRESHOLD := RoadPath.CURVE_MAX_DHEADING / RoadPath.SEG_LEN * 0.25
const DELINEATOR_HEIGHT := 0.7 * UNIT_SCALE # centre height on the barrier face
const DELINEATOR_SIZE := Vector3(0.35, 0.45, 0.03) * UNIT_SCALE # width (along road), height, thickness
const DELINEATOR_YAW_DEG := 45.0 # how far each plate turns off the wall toward approaching traffic
# Player headlight pose fed to delineator.gdshader, in the car's local space
# (car drives along its own +Z; front axle sits at z=3.8 in base car.tscn).
const HEADLIGHT_LOCAL_OFFSET := Vector3(0.0, 0.6, 3.8)

const EDITOR_PREVIEW_FIRST := -1
const EDITOR_PREVIEW_LAST := 3

const GROUND_SURFACE_SCRIPT := preload("res://MAIN/ground_surface_variables.gd")

@export var car_path: NodePath = NodePath("../car")

var _chunks: Dictionary = {} # chunk index (int) -> Node3D
var path: RoadPath = null
var tracker: PathTracker = null
## This run's feature plan (tunnels, bridges, overpasses, lane closures,
## barrier types) - see road_layout.gd. Read by traffic, drift scoring,
## weather and TunnelRig too.
var layout: RoadLayout = null
var _sea: MeshInstance3D = null # camera-following sea plane, shown near bridges (RoadBridge)
## Built suspension bridges, bridge ramp_start -> node (RoadSuspension.update).
var suspension_nodes: Dictionary = {}
var _perf: Node = null # PerfMonitor autoload (absent in the editor)

# Building layout is seeded per-chunk-index (see _build_chunk below) so it's
# stable within a run regardless of drive direction - but combined with
# _run_seed (randomized fresh each run, both here and in reset_chunks()) so
# a given chunk index actually looks different from one run to the next,
# per user request, rather than always retracing the exact same layout.
var _run_seed: int = 0

func _ready() -> void:
	if not Engine.is_editor_hint():
		add_to_group("road_generator") # Weather (autoload) looks this up to read `path`/`tracker.dist`
	_perf = get_node_or_null("/root/PerfMonitor")
	_run_seed = randi()
	_new_path(randi())
	tracker = PathTracker.new(path, 0.0)
	_sea = RoadBridge.make_sea()
	add_child(_sea)
	if not Engine.is_editor_hint():
		var rig := TunnelRig.new()
		rig.name = "TunnelRig"
		add_child(rig)
	if Engine.is_editor_hint():
		# No car driving the headlight pose in the editor - keep reflectors dark.
		_delineator_material.set_shader_parameter("headlight_on", false)
		_build_editor_preview()

## Plans this run's features, then generates the path that follows the plan
## (bridges bend its grade), then lets the plan read the finished heights.
func _new_path(seed: int) -> void:
	RoadSuspension.clear(self) # they belong to the old layout
	layout = RoadLayout.new(seed, RoadPath.TOTAL_LENGTH, {
		"first_feature_m": first_feature_m,
		"gap_min_m": feature_gap_min_m,
		"gap_max_m": feature_gap_max_m,
		"tunnel_weight": tunnel_weight,
		"debug_first": debug_first_feature,
		"overpasses": overpasses_enabled,
		"suspension_bridges": suspension_bridges,
	})
	path = RoadPath.new(seed, RoadPath.TOTAL_LENGTH, layout)
	layout.bind_path(path)

## Bound to the "Rebuild Editor Preview" Inspector button - frees and
## regenerates every preview chunk, so a change to the streetlight cone
## tuning above (or anything else chunk-related) actually shows up without
## having to close and reopen the scene. Re-plans the path too, so Road
## Features changes show up.
func _rebuild_editor_preview() -> void:
	if not Engine.is_editor_hint():
		return
	for i in _chunks.keys().duplicate():
		_chunks[i].queue_free()
	_chunks.clear()
	_shared_res.clear() # pick up changed streetlight tuning
	_new_path(randi())
	tracker = PathTracker.new(path, 0.0)
	_build_editor_preview()

func _build_editor_preview() -> void:
	var first := EDITOR_PREVIEW_FIRST
	var last := EDITOR_PREVIEW_LAST
	if preview_at_feature:
		var focus := -1.0
		if not layout.tunnels.is_empty():
			focus = layout.tunnels[0].portal_in - 200.0 * UNIT_SCALE
		if not layout.bridges.is_empty() and (focus < 0.0 or layout.bridges[0].ramp_start < focus):
			focus = layout.bridges[0].sea_start - 250.0 * UNIT_SCALE
		if focus >= 0.0:
			first = int(floor(focus / CHUNK_LENGTH))
			last = first + 6
	for i in range(first, last + 1):
		_chunks[i] = _build_chunk(i)
	_pump_build_queue(-1)
	# No game camera in the editor - park the sea under the preview if it's a bridge.
	var mid: float = (float(first) + float(last + 1)) * 0.5 * CHUNK_LENGTH
	var b: Dictionary = layout.bridge_at(mid, RoadBridge.SEA_SHOW_PAD)
	_sea.visible = not b.is_empty()
	if _sea.visible:
		var p: Vector3 = path.world_pos(mid, 0.0)
		_sea.position = Vector3(p.x, b.sea_y, p.z)
		RoadBridge.clip_sea(self, _sea, b)
	RoadSuspension.update(self, mid)

var _car: Node3D = null # cached car_path target (looked up again only if it goes away)

func _physics_process(_delta: float) -> void:
	if Engine.is_editor_hint():
		return
	if not is_instance_valid(_car):
		_car = get_node_or_null(car_path)
	var car := _car
	if car == null:
		return
	tracker.update(car.global_position)
	_update_delineator_headlight(car)
	_sync_chunks_to(tracker.dist) # its build stages report to PerfMonitor themselves
	_apply_tree_settings()
	var sea_dist: float = tracker.dist if is_nan(warmup_sea_dist) else warmup_sea_dist
	RoadBridge.update_sea(self, _sea, sea_dist, get_viewport().get_camera_3d())
	RoadSuspension.update(self, sea_dist)

# --- Loading-screen shader warm-up (LoadingScreen) --------------------------

## While set, the sea shows for this road distance instead of the player's,
## so the loading screen's warm-up camera can see it at a bridge far ahead.
var warmup_sea_dist: float = NAN

## Sets warmup_sea_dist (NAN = back to normal) and places the sea for the
## current camera right away - the next physics tick may be frames off. A
## suspension bridge there is built for the shot too (RoadSuspension).
func set_warmup_sea(dist: float) -> void:
	warmup_sea_dist = dist
	var at: float = tracker.dist if is_nan(dist) else dist
	RoadBridge.update_sea(self, _sea, at, get_viewport().get_camera_3d())
	RoadSuspension.update(self, at)

## Builds chunk `index` completely, right now, outside the streaming window,
## so a feature far down the road (tunnel, bridge) can be drawn once behind
## the loading screen. Null if that chunk is already streamed in. The caller
## frees it.
func build_warmup_chunk(index: int) -> Node3D:
	if _chunks.has(index):
		return null
	var chunk := _build_chunk(index)
	_pump_build_queue(-1)
	return chunk

## Feeds the player's headlight pose to the shared delineator material, so
## reflectors inside the beam flare (see delineator.gdshader). One material
## for every chunk, so this is a single update per frame.
func _update_delineator_headlight(car: Node3D) -> void:
	var xf: Transform3D = car.global_transform
	_delineator_material.set_shader_parameter("headlight_pos", xf * HEADLIGHT_LOCAL_OFFSET)
	_delineator_material.set_shader_parameter("headlight_dir", xf.basis.z.normalized())

func _sync_chunks_to(dist: float) -> void:
	var first_needed: int = int(floor((dist - REMOVE_BEHIND) / CHUNK_LENGTH))
	var last_needed: int = int(floor((dist + GENERATE_AHEAD) / CHUNK_LENGTH))
	var here: int = int(floor(dist / CHUNK_LENGTH))

	for i in range(first_needed, last_needed + 1):
		if not _chunks.has(i):
			_chunks[i] = _build_chunk(i)
			# The car's own chunk and its neighbours can't wait for staging -
			# it needs that collision now (fresh spawn, teleport, reset).
			if absi(i - here) <= 1:
				_pump_build_queue(-1)

	for i in _chunks.keys().duplicate():
		if i < first_needed or i > last_needed:
			_chunks[i].queue_free()
			_chunks.erase(i)

	_pump_build_queue(BUILD_BUDGET_USEC)

## Chunk building is staged: _build_chunk only creates the chunk body and
## queues its pieces (collision, ribbon, terrain, barriers, structures, lights,
## buildings, trees); this runs queued pieces until `budget_usec` of this frame
## is used (always at least one; -1 = run everything now). Chunks are built
## GENERATE_AHEAD in front of the car, so a chunk filling in over a few
## frames happens far off, and one heavy chunk (a tunnel hill, a viaduct)
## no longer lands in a single frame. Pieces of a chunk freed before they ran
## are skipped.
const BUILD_BUDGET_USEC := 4000
var _build_queue: Array[Array] = [] # [chunk, stage name, Callable]

func _pump_build_queue(budget_usec: int) -> void:
	var t0 := Time.get_ticks_usec()
	while not _build_queue.is_empty():
		var job: Array = _build_queue.pop_front()
		var chunk: Node = job[0]
		if is_instance_valid(chunk) and not chunk.is_queued_for_deletion():
			var label: String = "road: " + String(job[1])
			if _perf:
				_perf.begin(label)
			job[2].call()
			if _perf:
				_perf.end(label)
				_perf.note("%s %s" % [chunk.name, job[1]])
		if budget_usec >= 0 and Time.get_ticks_usec() - t0 >= budget_usec:
			break

var _run_prepared := false

## First half of a fresh run's reset: a new path and layout, the tracker parked
## at the run's start point, and every old chunk freed. After this,
## spawn_transform() says where the car goes.
func prepare_run() -> void:
	_run_seed = randi() # fresh building layout this run, not the same one every time
	_new_path(randi())
	tracker = PathTracker.new(path, RoadLayout.spawn_dist())
	for i in _chunks.keys().duplicate():
		_chunks[i].queue_free()
	_chunks.clear()
	_run_prepared = true

## Where a run starts: parked in the lay-by (RoadLayout.spawn_dist /
## spawn_lateral), facing down the road and sitting flat on the surface
## (which may be banked or on a grade there). `height` is how far the car's
## origin rides above the road.
func spawn_transform(height: float) -> Transform3D:
	var d: float = RoadLayout.spawn_dist()
	var lat: float = RoadLayout.spawn_lateral()
	var fwd: Vector3 = (path.world_pos(d + 1.0, lat) - path.world_pos(d - 1.0, lat)).normalized()
	# +lateral is the car's left (+X); forward is +Z.
	var left: Vector3 = (path.world_pos(d, lat + 1.0) - path.world_pos(d, lat - 1.0)).normalized()
	var up: Vector3 = fwd.cross(left).normalized()
	left = up.cross(fwd).normalized()
	return Transform3D(Basis(left, up, fwd), path.world_pos(d, lat) + up * height)

## Called by run_reset.gd when a fresh run starts (garage -> Play Endless,
## after a crash) - regenerates a FRESH RoadPath (new seed, so the actual
## curve/elevation/biome layout is genuinely different this run, not just
## the buildings/traffic) and rebuilds the chunk window fresh around the
## car's (already-reset) spawn position, in one immediate pass, rather than
## relying on _physics_process to incrementally converge over several
## frames (which would show missing road/a visible pop as ~600 units worth
## of chunks all materialize piecemeal).
##
## run_reset.gd calls prepare_run() first (new path, old chunks freed), parks
## the car at spawn_transform() on that new path, then calls this to build the
## window around it. Called on its own it prepares the run itself.
func reset_chunks() -> void:
	if not _run_prepared:
		prepare_run()
	_run_prepared = false
	var car: Node3D = get_node_or_null(car_path)
	if car:
		tracker.update(car.global_position)
	_sync_chunks_to(tracker.dist)
	_pump_build_queue(-1) # a fresh run shows its whole window at once

func _build_chunk(index: int) -> Node3D:
	var chunk := StaticBody3D.new()
	chunk.set_script(GROUND_SURFACE_SCRIPT)
	chunk.name = "RoadChunk_%d" % index
	add_child(chunk)
	# Chunk itself stays at identity transform - curves mean each chunk's
	# geometry is genuinely unique now, not a translated copy of a canonical
	# straight shape, so every position below is computed directly in
	# world/path space via path.world_pos(dist, lateral) rather than a flat
	# local Vector3(x, 0, z).

	var start_dist: float = float(index) * CHUNK_LENGTH
	var end_dist: float = start_dist + CHUNK_LENGTH
	# One collision/mesh row per path point (CHUNK_LENGTH == 8*SEG_LEN by
	# construction) - fine enough subdivision that the curve/bank/grade
	# within one chunk reads as smooth, not faceted.
	var rows: int = int(round(CHUNK_LENGTH / RoadPath.SEG_LEN))

	# Seeded per-chunk-index (not a shared streaming RNG) so a chunk's
	# building layout stays identical whether the player is driving forward
	# past it for the first time or has backed up and re-entered it.
	# Forest stretches (BiomeMap.is_forest) swap the buildings for dense trees;
	# RoadLayout can force either look around a tunnel.
	var forest := _is_forest_chunk(start_dist + CHUNK_LENGTH * 0.5)
	var jobs: Array = [
		["collision", _stage_collision.bind(chunk, start_dist, rows)],
		["ribbon", _stage_ribbon.bind(chunk, start_dist, rows)],
		["terrain", _stage_terrain.bind(chunk, start_dist, rows)],
		["barriers", _stage_barriers.bind(chunk, start_dist, end_dist)],
		["structures", _stage_structures.bind(chunk, start_dist, end_dist)],
		["streetlights", _stage_streetlights.bind(chunk, start_dist, end_dist)],
	]
	if not forest:
		jobs.append(["buildings", _stage_buildings.bind(chunk, index, start_dist, end_dist)])
	jobs.append(["trees", _stage_trees.bind(chunk, index, start_dist, end_dist, forest)])
	for j in jobs:
		_build_queue.append([chunk, j[0], j[1]])
	return chunk

# --- chunk build stages (queued by _build_chunk, run by _pump_build_queue) ---

func _stage_collision(chunk: StaticBody3D, start_dist: float, rows: int) -> void:
	_build_collision(chunk, start_dist, rows)

func _stage_ribbon(chunk: Node3D, start_dist: float, rows: int) -> void:
	chunk.add_child(_build_ribbon_mesh(start_dist, rows))

func _stage_terrain(chunk: Node3D, start_dist: float, rows: int) -> void:
	var terrain := _build_terrain_mesh(start_dist, rows)
	if terrain:
		chunk.add_child(terrain)

func _stage_barriers(chunk: Node3D, start_dist: float, end_dist: float) -> void:
	chunk.add_child(_build_lane_dashes(start_dist, end_dist))
	for side in [-1.0, 1.0]:
		RoadBarriers.build(self, chunk, start_dist, end_dist, side)

func _stage_structures(chunk: Node3D, start_dist: float, end_dist: float) -> void:
	RoadTunnel.build(self, chunk, start_dist, end_dist)
	RoadBridge.build(self, chunk, start_dist, end_dist)
	RoadOverpass.build(self, chunk, start_dist, end_dist)
	RoadLayby.build(self, chunk, start_dist, end_dist)

func _stage_streetlights(chunk: Node3D, start_dist: float, end_dist: float) -> void:
	chunk.add_child(_build_streetlights(start_dist, end_dist))

func _stage_buildings(chunk: Node3D, index: int, start_dist: float, end_dist: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(index) ^ _run_seed
	chunk.add_child(_build_buildings(start_dist, end_dist, rng))

## Own RNG streams so adding/tuning trees or leaves never reshuffles the buildings.
func _stage_trees(chunk: Node3D, index: int, start_dist: float, end_dist: float, forest: bool) -> void:
	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = hash(index) ^ _run_seed ^ 0x7733
	chunk.add_child(RoadsideTrees.build(self, start_dist, end_dist, tree_rng, forest,
		_setting("tree_density", 1.0), _setting("show_trees", true), _setting("tree_shadows", false)))
	if road_leaves_enabled:
		var leaf_rng := RandomNumberGenerator.new()
		leaf_rng.seed = hash(index) ^ _run_seed ^ 0x1EAF
		var leaves := RoadLeaves.build(self, start_dist, end_dist, leaf_rng, forest, road_leaf_density)
		if leaves:
			chunk.add_child(leaves)

## Reads misc_graphics_settings (autoload) - which doesn't exist in the
## editor preview, so fall back to the default there.
var _settings: Node = null

func _setting(name: String, fallback: Variant) -> Variant:
	if _settings == null:
		_settings = get_node_or_null("/root/misc_graphics_settings")
	return _settings.get(name) if _settings else fallback

## Pushes the live tree toggles (Graphics Config panel) onto every existing
## tree batch - only when one actually changes, not every frame.
var _applied_tree_visible: bool = true
var _applied_tree_shadows: bool = false

func _apply_tree_settings() -> void:
	var vis: bool = _setting("show_trees", true)
	var shadows: bool = _setting("tree_shadows", false)
	if vis == _applied_tree_visible and shadows == _applied_tree_shadows:
		return
	_applied_tree_visible = vis
	_applied_tree_shadows = shadows
	for mmi in get_tree().get_nodes_in_group("roadside_trees"):
		mmi.visible = vis
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## Ground collision: ONE ConcavePolygonShape3D ("trimesh") per chunk, built
## from the exact same per-row corner points _build_ribbon_mesh uses for the
## visual surface - collision follows the road's real pitch (grade) AND roll
## (bank) exactly, matching what's drawn, same as the previous per-row
## ConvexPolygonShape3D approach, just as a single shape instead of `rows`
## separate ones.
##
## Previously deliberately avoided (a single trimesh per chunk) due to
## godotengine/godot#100539 - RayCast3D unreliably detecting
## ConcavePolygonShape3D collision built from a procedural ArrayMesh, which
## this project's entire suspension (wheel.gd) depends on via RayCast3D.
## Re-tested directly against this project's own actual Godot version
## (4.7.2) and configured physics backend (GodotPhysics3D, project.godot) -
## the issue is still open upstream, but a headless test firing 1300+
## raycasts at a trimesh built with this exact technique (curved+banked
## rows, including exactly at row seams) against this engine build found
## ZERO missed raycasts. A ~9% "wrong height" rate initially looked
## concerning, but a flat/planar control quad (same construction technique,
## zero curvature) came back at 0 error - proving those weren't a
## RayCast3D/trimesh bug at all, just the ordinary approximation error of
## triangulating a non-planar (curved+banked) quad along one diagonal - the
## same faceting the road-smoothness discussion is already about, present
## equally in the old per-row convex shapes, not specific to trimesh.
## Re-verify this choice if this project's Godot version or physics backend
## ever changes.
##
## Guardrail walls stay as separate per-row ConvexPolygonShape3D boxes
## (below) - simple vertical stoppers with no curvature-smoothness need, not
## worth folding into the same trimesh.
func _build_collision(chunk: StaticBody3D, start_dist: float, rows: int) -> void:
	# Faces straight into the shape - no throwaway ArrayMesh in between. Each
	# sub-row's leading edge is the previous one's trailing edge, so every
	# edge point is sampled once.
	var sub_len: float = RoadPath.SEG_LEN / float(ROW_SUBDIVISIONS)
	var sub_count: int = rows * ROW_SUBDIVISIONS
	var faces := PackedVector3Array()
	faces.resize(sub_count * 6)
	var a0: Vector3 = path.world_pos(start_dist, layout.shoulder_edge(start_dist, -1.0))
	var b0: Vector3 = path.world_pos(start_dist, layout.shoulder_edge(start_dist, 1.0))
	for sub in range(sub_count):
		var d1: float = start_dist + float(sub + 1) * sub_len
		var a1: Vector3 = path.world_pos(d1, layout.shoulder_edge(d1, -1.0))
		var b1: Vector3 = path.world_pos(d1, layout.shoulder_edge(d1, 1.0))
		var k: int = sub * 6
		faces[k] = a0; faces[k + 1] = b0; faces[k + 2] = b1
		faces[k + 3] = a0; faces[k + 4] = b1; faces[k + 5] = a1
		a0 = a1
		b0 = b1
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	var ground_collision := CollisionShape3D.new()
	ground_collision.shape = shape
	chunk.add_child(ground_collision)

	for row in range(rows):
		var d0: float = start_dist + float(row) * RoadPath.SEG_LEN
		var d1: float = d0 + RoadPath.SEG_LEN

		# Guardrail walls - same per-row real-corner technique. Extends
		# straight up in world Y (not perpendicular to the banked surface) -
		# doesn't need to be perfectly plumb-with-the-tilt to do its actual
		# job (physically stopping the car at the shoulder edge). Follows the
		# layout's shoulder edge, so it angles in with a lane closure and
		# doubles as the tunnel walls' collision.
		for side in [-1.0, 1.0]:
			var w0: Vector3 = path.world_pos(d0, layout.shoulder_edge(d0, side))
			var w1: Vector3 = path.world_pos(d1, layout.shoulder_edge(d1, side))
			var up := Vector3(0, WALL_HEIGHT, 0)
			var thickness := Vector3(WALL_THICKNESS * -side, 0, 0) # toward road center, just needs any nonzero volume
			var wall_shape := ConvexPolygonShape3D.new()
			wall_shape.points = PackedVector3Array([
				w0, w1, w0 + up, w1 + up,
				w0 + thickness, w1 + thickness, w0 + up + thickness, w1 + up + thickness,
			])
			var wall_collision := CollisionShape3D.new()
			wall_collision.shape = wall_shape
			chunk.add_child(wall_collision)

## Position at (dist, lateral) on the road's EDGE level - for anything that
## stands on the road structure itself: barriers, viaduct deck lips,
## delineators, deck-mounted poles. The road banks (world_pos rolls the whole
## cross-section), but a barrier must stand plumb, so beyond the shoulder
## edge this keeps world_pos's horizontal position but pins the height to that
## side's shoulder edge: level across, meets the banked road with no step,
## follows the road's elevation along its length. Inside the shoulder it is
## exactly world_pos (banked road surface). The shoulder edge comes from
## RoadLayout, so it follows lane closures.
func _edge_level_pos(dist: float, lateral: float) -> Vector3:
	var p: Vector3 = path.world_pos(dist, lateral)
	var edge: float = layout.shoulder_edge(dist, 1.0 if lateral >= 0.0 else -1.0)
	if absf(lateral) <= absf(edge):
		return p
	p.y = path.world_pos(dist, edge).y
	return p

## Where the GROUND is - terrain, grass/sidewalk bands, buildings, trees. At
## grade that's the level ground of _edge_level_pos (you can't stand a
## building on the banked road), raised by RoadLayout.lift() for trench lids
## and tunnel hills. Over a tunnel it's a lid spanning the road too; under a
## viaduct it's the flat land the ramp climbed away from, kept below the deck.
func _ground_pos(dist: float, lateral: float) -> Vector3:
	var mode: int = layout.surface_mode(dist)
	var p: Vector3 = path.world_pos(dist, lateral)
	var edge: float = layout.shoulder_edge(dist, 1.0 if lateral >= 0.0 else -1.0)
	var on_road: bool = absf(lateral) <= absf(edge)
	if mode == RoadLayout.Surface.AT_GRADE and on_road:
		return p
	var edge_y: float
	if mode == RoadLayout.Surface.COVERED:
		edge_y = maxf(path.world_pos(dist, layout.shoulder_edge(dist, -1.0)).y,
			path.world_pos(dist, layout.shoulder_edge(dist, 1.0)).y)
	else:
		edge_y = path.world_pos(dist, edge).y
	var land: float = layout.land_level(dist, edge_y)
	if not is_nan(land):
		p.y = minf(land, p.y - RoadLayout.UNDER_ROAD_DROP) if on_road else land
		return p
	p.y = edge_y + layout.lift(dist, lateral)
	return p

## _ground_pos for a ribbon/terrain mesh row belonging to a sub-row of surface
## `mode`. The ground steps at a tunnel portal, so a row sitting on one takes
## its HEIGHT from its own side of it (RoadLayout.portal_side): lid height for
## the tunnel's rows, the open ground for the road's. Everywhere else this is
## exactly _ground_pos.
func _row_ground_pos(dist: float, lateral: float, mode: int) -> Vector3:
	var side_dist: float = layout.portal_side(dist, mode == RoadLayout.Surface.COVERED)
	var p: Vector3 = _ground_pos(side_dist, lateral)
	if side_dist != dist:
		var at: Vector3 = path.world_pos(dist, lateral)
		p.x = at.x
		p.z = at.z
	return p

## Horizontal unit vector toward +lateral at `dist` (never picks up bank/grade).
func _right_dir(dist: float) -> Vector3:
	var h: float = path.road_frame(dist).heading
	return Vector3(cos(h), 0.0, -sin(h))

const LANE_COLOR := Color(0.16, 0.16, 0.175)
const SHOULDER_COLOR := Color(0.21, 0.20, 0.19)
const SIDEWALK_COLOR := Color(0.42, 0.41, 0.38)
## The starting lay-by's surface (UK emergency-area orange). The shader still
## adds its cracks / streaks / gravel over it.
const LAYBY_COLOR := Color(0.62, 0.34, 0.15)
## How far inside the shader's paved range the lay-by's UVs start (world units).
const LAYBY_UV_INSET := 0.5
## Viaduct deck surface beyond the shoulder edge, under the barrier.
const DECK_LIP := 0.9 * UNIT_SCALE

var _road_materials: Dictionary = {} # bool (in tunnel) -> ShaderMaterial

## One shared road material for open road and one for inside tunnels (same
## shader, fake sodium lighting switched on) - every param is chunk-independent.
func _road_material(tunnel: bool) -> ShaderMaterial:
	if not _road_materials.has(tunnel):
		var mat := ShaderMaterial.new()
		mat.shader = ROAD_SURFACE_SHADER
		mat.set_shader_parameter("road_half_width", ROAD_HALF_WIDTH)
		mat.set_shader_parameter("shoulder_half_width", SHOULDER_HALF_WIDTH)
		mat.set_shader_parameter("grass_half_width", GRASS_HALF_WIDTH)
		mat.set_shader_parameter("sidewalk_half_width", SIDEWALK_HALF_WIDTH)
		if tunnel:
			mat.set_shader_parameter("tunnel_glow", RoadTunnel.ROAD_GLOW)
			mat.set_shader_parameter("tunnel_light_color", RoadTunnel.LAMP_COLOR)
			mat.set_shader_parameter("lamp_spacing", RoadTunnel.LAMP_SPACING)
		_road_materials[tunnel] = mat
	return _road_materials[tunnel]

## One cross-section row of the road ribbon at `dist`: parallel arrays of
## lateral offsets, positions and vertex colours, left to right (increasing
## lateral). What it spans depends on the surface mode (see RoadLayout):
## at grade - sidewalk/grass bands, shoulders, lanes (and a closing lane's
## hatched area); in a tunnel - just the paved road; on a viaduct - the road
## plus a short deck lip under each barrier.
func _ribbon_row(dist: float, mode: int) -> Dictionary:
	var rs: float = layout.shoulder_edge(dist, -1.0)
	var le: float = layout.lane_edge(dist, 1.0)
	var he: float = layout.hatch_edge(dist, 1.0)
	var ls: float = layout.shoulder_edge(dist, 1.0)
	var urban: float = _urban_amount(dist)
	var ground := _ground_color(GRASS_HALF_WIDTH, urban)
	var lats: Array = []
	var cols: Array = []
	var ground_side: Array = [] # true = off-road point (use _ground_pos / _edge_level_pos)
	# UV.y per point. road_surface.gdshader reads it as "lateral position on a
	# NORMAL road" to tell lanes / shoulder / grass / footpath apart, so it's
	# the raw lateral everywhere except around the starting lay-by (below).
	var uvy: Array = []
	if mode == RoadLayout.Surface.AT_GRADE:
		# The starting lay-by (RoadLayout.layby_width) pushes the right side's
		# footpath and grass strip outward by `bay` and fills the space with
		# its own paved band, from the bay's outer edge (rs) in to the normal
		# shoulder line. Points are doubled where the colour changes, so the
		# bay's orange has crisp edges instead of blending into its neighbours
		# (the zero-width band between a pair is skipped by the mesh builder -
		# as is the whole bay band wherever bay == 0).
		var bay: float = layout.layby_width(dist)
		var mouth: float = -SHOULDER_HALF_WIDTH # the normal shoulder line
		lats.append_array([-SIDEWALK_HALF_WIDTH - bay, -GRASS_HALF_WIDTH - bay, rs, rs, mouth, mouth])
		cols.append_array([SIDEWALK_COLOR, ground, SHOULDER_COLOR, LAYBY_COLOR, LAYBY_COLOR, SHOULDER_COLOR])
		ground_side.append_array([true, true, false, false, false, false])
		# Footpath and grass keep their normal-road UVs so the shader still
		# draws them as footpath and grass. The bay's UVs sit inside the
		# shader's paved range across its whole width. The shoulder's outer
		# edge normally fades into grass; next to the bay it's pulled just
		# inside the paved range instead (eased in over the first unit of bay).
		var inside: float = LAYBY_UV_INSET * clampf(bay, 0.0, 1.0)
		uvy.append_array([-SIDEWALK_HALF_WIDTH, -GRASS_HALF_WIDTH, -SHOULDER_HALF_WIDTH,
			-SHOULDER_HALF_WIDTH + LAYBY_UV_INSET, -SHOULDER_HALF_WIDTH + LAYBY_UV_INSET + bay,
			-SHOULDER_HALF_WIDTH + inside])
	else:
		if mode != RoadLayout.Surface.COVERED:
			lats.append(rs - DECK_LIP)
			cols.append(SIDEWALK_COLOR)
			ground_side.append(true)
			uvy.append(rs - DECK_LIP)
		lats.append(rs)
		cols.append(SHOULDER_COLOR)
		ground_side.append(false)
		uvy.append(rs)
	lats.append_array([RoadMetrics.RIGHT_EDGE, le, he, ls])
	cols.append_array([LANE_COLOR, LANE_COLOR, LANE_COLOR, SHOULDER_COLOR])
	ground_side.append_array([false, false, false, false])
	uvy.append_array([RoadMetrics.RIGHT_EDGE, le, he, ls])
	if mode == RoadLayout.Surface.AT_GRADE:
		lats.append_array([GRASS_HALF_WIDTH, SIDEWALK_HALF_WIDTH])
		cols.append_array([ground, SIDEWALK_COLOR])
		ground_side.append_array([true, true])
		uvy.append_array([GRASS_HALF_WIDTH, SIDEWALK_HALF_WIDTH])
	elif mode != RoadLayout.Surface.COVERED:
		lats.append(ls + DECK_LIP)
		cols.append(SIDEWALK_COLOR)
		ground_side.append(true)
		uvy.append(ls + DECK_LIP)
	var pos: Array = []
	for i in lats.size():
		if not ground_side[i]:
			pos.append(path.world_pos(dist, lats[i]))
		elif mode == RoadLayout.Surface.AT_GRADE:
			pos.append(_row_ground_pos(dist, lats[i], mode))
		else:
			pos.append(_edge_level_pos(dist, lats[i]))
		cols[i] = Color(cols[i], urban) # alpha = urban amount, read by the shader
	return {"lats": lats, "uvy": uvy, "pos": pos, "cols": cols, "hatch": Vector2(le, he)}

func _build_ribbon_mesh(start_dist: float, rows: int) -> MeshInstance3D:
	# Tunnel stretches go in their own surface so they can get the tunnel-lit
	# material; everything else shares the normal one.
	var tools := {false: SurfaceTool.new(), true: SurfaceTool.new()}
	var used := {false: false, true: false}
	for k in tools:
		tools[k].begin(Mesh.PRIMITIVE_TRIANGLES)

	# Build sub-row-by-sub-row (ROW_SUBDIVISIONS samples per RoadPath point
	# spacing - see that constant's own note on why this matters now that
	# road_frame() reconstructs a real curve between points), band-by-band
	# within each sub-row - same banked-cross-section technique as the
	# original's buildRoadMesh/buildFlatRibbon, just applied to every band in
	# one pass instead of one ribbon per band.
	var dists := _sub_row_dists(start_dist, rows)
	# A sub-row's far edge is the next one's near edge - reused unless the
	# surface mode (which decides the row's bands) changes between them.
	var prev_row: Dictionary = {}
	var prev_mode: int = -1
	for sub in range(dists.size() - 1):
		var d0: float = dists[sub]
		var d1: float = dists[sub + 1]
		var mode: int = layout.surface_mode((d0 + d1) * 0.5)
		var tunnel: bool = mode == RoadLayout.Surface.COVERED
		var st: SurfaceTool = tools[tunnel]
		used[tunnel] = true
		var r0 := prev_row if mode == prev_mode else _ribbon_row(d0, mode)
		var r1 := _ribbon_row(d1, mode)
		prev_row = r1
		prev_mode = mode
		for band in range(r0.lats.size() - 1):
			# Zero-width bands (the hatch strip when no lane is closing).
			if absf(r0.lats[band + 1] - r0.lats[band]) < 0.001 and absf(r1.lats[band + 1] - r1.lats[band]) < 0.001:
				continue
			# UV.x = distance along the path, UV.y = raw lateral offset (world
			# units, signed) - not a 0-1 texture coordinate. The surface shader
			# (road_surface.gdshader) uses UV.x directly as continuous noise
			# input (so cracks/streaks/gravel never seam at chunk boundaries,
			# since it's real world distance, not chunk-local) and UV.y against
			# ROAD_HALF_WIDTH/SHOULDER_HALF_WIDTH to mask which bands get which
			# detail, instead of guessing from vertex color. UV2 = the closing
			# lane's hatched strip (lane edge, hatch edge) for the paint.
			_ribbon_vertex(st, d0, r0, band)
			_ribbon_vertex(st, d0, r0, band + 1)
			_ribbon_vertex(st, d1, r1, band + 1)
			_ribbon_vertex(st, d0, r0, band)
			_ribbon_vertex(st, d1, r1, band + 1)
			_ribbon_vertex(st, d1, r1, band)

	var mesh := ArrayMesh.new()
	var mi := MeshInstance3D.new()
	for tunnel in [false, true]:
		if used[tunnel]:
			tools[tunnel].generate_normals()
			tools[tunnel].commit(mesh)
			mi.mesh = mesh
			mi.set_surface_override_material(mesh.get_surface_count() - 1, _road_material(tunnel))
	return mi

## Sub-row boundaries for the ribbon/terrain of the chunk starting at
## `start_dist`: ROW_SUBDIVISIONS per RoadPath row, plus any tunnel portal
## inside the chunk. A sub-row takes its surface mode from its midpoint, so
## one that straddled a portal used to run the tunnel lid from road level at
## one end up to lid height at the other - a sheet of "road" standing across
## the tunnel mouth. Cut at the portal, the lid starts flush with the headwall.
func _sub_row_dists(start_dist: float, rows: int) -> PackedFloat64Array:
	var sub_len: float = RoadPath.SEG_LEN / float(ROW_SUBDIVISIONS)
	var sub_count: int = rows * ROW_SUBDIVISIONS
	var portals: Array[float] = layout.portals_between(start_dist, start_dist + float(sub_count) * sub_len)
	var dists := PackedFloat64Array()
	var next := 0
	for sub in range(sub_count + 1):
		var d: float = start_dist + float(sub) * sub_len
		while next < portals.size() and portals[next] < d + RoadLayout.PORTAL_EPS:
			# One that lands on a regular boundary is already a cut.
			if portals[next] < d - RoadLayout.PORTAL_EPS:
				dists.append(portals[next])
			next += 1
		dists.append(d)
	return dists

func _ribbon_vertex(st: SurfaceTool, d: float, row: Dictionary, i: int) -> void:
	st.set_color(row.cols[i])
	st.set_uv(Vector2(d, row.uvy[i]))
	st.set_uv2(row.hatch)
	st.set_normal(Vector3.UP)
	st.add_vertex(row.pos[i])

## Terrain lateral samples (unsigned, increasing) for one side. Starts at the
## sidewalk edge at grade; over a tunnel lid / under a viaduct it starts at
## the road centre (nothing else covers it there). Hill tunnels need fine
## samples so the hill's flanks are actually round.
func _terrain_edges(dist: float, mode: int, side: float, fine: bool) -> Array[float]:
	var e: Array[float] = []
	if mode == RoadLayout.Surface.COVERED or mode == RoadLayout.Surface.ELEVATED:
		e.append(0.0)
		e.append(absf(layout.shoulder_edge(dist, side)))
	# The footpath's outer edge - pushed out with it around the starting lay-by.
	e.append(SIDEWALK_HALF_WIDTH + layout.verge_shift(dist, side))
	for band_width in (TERRAIN_FINE_BANDS if fine else TERRAIN_BANDS):
		e.append(SIDEWALK_HALF_WIDTH + band_width)
	return e

## One terrain cross-section on `side` at `dist`: signed laterals, ground
## positions and colours, in _terrain_edges order.
func _terrain_row(dist: float, mode: int, side: float, fine: bool) -> Dictionary:
	var urban: float = _urban_amount(dist)
	var lats: Array[float] = []
	var uvy: Array[float] = []
	var pos: Array[Vector3] = []
	var cols: Array[Color] = []
	var shifted_edge: float = SIDEWALK_HALF_WIDTH + layout.verge_shift(dist, side)
	for e in _terrain_edges(dist, mode, side, fine):
		var x: float = side * e
		lats.append(x)
		# The shifted footpath edge keeps its normal-road UV, matching the
		# ribbon's vertex there (see _ribbon_row).
		uvy.append(side * SIDEWALK_HALF_WIDTH if is_equal_approx(e, shifted_edge) else x)
		pos.append(_row_ground_pos(dist, x, mode))
		cols.append(_ground_color(x, urban))
	return {"lats": lats, "uvy": uvy, "pos": pos, "cols": cols}

func _terrain_vertex(st: SurfaceTool, d: float, row: Dictionary, i: int) -> void:
	st.set_color(row.cols[i])
	st.set_uv(Vector2(d, row.uvy[i]))
	st.add_vertex(row.pos[i])

## Flat ground (green in forests, grey concrete in the city - see
## _ground_color) stretching out from the sidewalk on both sides so the
## buildings have something to stand on (previously the ribbon simply ended at
## the sidewalk and the buildings hung in the void beyond it). Follows
## _ground_pos, so it rises into trench lids and tunnel hills and drops to the
## land under a viaduct; none is built over the sea. Same per-sub-row spacing
## as the ribbon so the shared edge has no cracks; same road shader (UV.y =
## raw lateral, past the shoulder => unpaved). No collision - the guardrail
## walls keep the car on the road.
func _build_terrain_mesh(start_dist: float, rows: int) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mid: float = start_dist + CHUNK_LENGTH * 0.5
	var t: Dictionary = layout.tunnel_at(mid, CHUNK_LENGTH)
	var fine: bool = not t.is_empty() and t.style == RoadLayout.Portal.HILL
	var dists := _sub_row_dists(start_dist, rows) # same cuts as the ribbon
	var count := 0
	for side in [-1.0, 1.0]:
		# Same near/far edge reuse as the ribbon (edges depend on the mode).
		var prev_row: Dictionary = {}
		var prev_mode: int = -1
		for sub in range(dists.size() - 1):
			var d0: float = dists[sub]
			var d1: float = dists[sub + 1]
			var mode: int = layout.surface_mode((d0 + d1) * 0.5)
			if mode == RoadLayout.Surface.SEA:
				prev_mode = -1
				continue
			var r0 := prev_row if mode == prev_mode else _terrain_row(d0, mode, side, fine)
			var r1 := _terrain_row(d1, mode, side, fine)
			prev_row = r1
			prev_mode = mode
			for band in range(r0.lats.size() - 1):
				# Lower lateral first on both sides, so the winding matches the road ribbon's.
				var lo: int = band + 1 if side < 0.0 else band
				var hi: int = band if side < 0.0 else band + 1
				_terrain_vertex(st, d0, r0, lo)
				_terrain_vertex(st, d0, r0, hi)
				_terrain_vertex(st, d1, r1, hi)
				_terrain_vertex(st, d0, r0, lo)
				_terrain_vertex(st, d1, r1, hi)
				_terrain_vertex(st, d1, r1, lo)
				count += 1
	if count == 0:
		return null
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = _road_material(false)
	return mi

## 0 in a forest .. 1 in a city stretch, blended at the region boundaries.
## RoadLayout can force either look around a tunnel (grassy hill, city lid).
func _urban_amount(dist: float) -> float:
	var urban: float = 1.0 - BiomeMap.forest_weight(dist, path.seed_value)
	var ov: Vector2 = layout.biome_override(dist)
	if ov.y > 0.0:
		urban = lerpf(urban, 1.0 - ov.x, ov.y)
	return urban

## Forest (trees, no buildings) or city chunk - BiomeMap's call unless the
## layout forces one around a tunnel.
func _is_forest_chunk(dist: float) -> bool:
	var ov: Vector2 = layout.biome_override(dist)
	if ov.y > 0.5:
		return ov.x > 0.5
	return BiomeMap.is_forest(dist, path.seed_value)

## Whether a roadside tree may stand at (dist, lateral): never over the sea,
## never on the road (a closing lane moves the barrier in - the grass strip
## stays put, so this only bites inside tunnels), not right beside a viaduct
## (the canopy would poke through the deck), and not under an overpass.
const TREE_VIADUCT_CLEAR := 4.0 * UNIT_SCALE
const LAYBY_TREE_CLEAR := 1.5 * UNIT_SCALE

func _tree_ok(dist: float, lateral: float) -> bool:
	var mode: int = layout.surface_mode(dist)
	if mode == RoadLayout.Surface.SEA:
		return false
	if absf(lateral) < absf(layout.shoulder_edge(dist, signf(lateral))) + 1.0 * UNIT_SCALE:
		return false
	# Around the starting lay-by: nothing on its grass strip or footpath, or
	# right behind its fence.
	var shift: float = layout.verge_shift(dist, signf(lateral))
	if shift > 0.0 and absf(lateral) < SIDEWALK_HALF_WIDTH + shift + LAYBY_TREE_CLEAR:
		return false
	if mode == RoadLayout.Surface.ELEVATED and absf(lateral) < SIDEWALK_HALF_WIDTH + TREE_VIADUCT_CLEAR:
		return false
	return not layout.overpass_blocks(dist, lateral, RoadLayout.OVERPASS_KEEP_CLEAR)

## Off-road ground colour: green in forests, dark grey in city stretches
## (blended by BiomeMap.forest_weight), fading darker with distance from the
## sidewalk. Alpha = urban amount (0 forest .. 1 city), read by the shader.
func _ground_color(lateral: float, urban: float) -> Color:
	var far_t: float = clampf((absf(lateral) - SIDEWALK_HALF_WIDTH) / TERRAIN_BANDS[TERRAIN_BANDS.size() - 1], 0.0, 1.0)
	var grass := TERRAIN_NEAR_COLOR.lerp(TERRAIN_FAR_COLOR, far_t)
	var city := TERRAIN_URBAN_NEAR_COLOR.lerp(TERRAIN_URBAN_FAR_COLOR, far_t)
	return Color(grass.lerp(city, urban), urban)

## Lane divider dashes. Divider k (between lanes k-1 and k) only where lane k
## is fully painted - it stops where a closing lane's taper begins.
func _build_lane_dashes(start_dist: float, end_dist: float) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = _shared("dash_mesh")

	var per_divider: int = int(CHUNK_LENGTH / DASH_STEP)
	var xforms: Array[Transform3D] = []
	for k in range(1, LANES):
		var x: float = RoadMetrics.RIGHT_EDGE + float(k) * LANE_WIDTH
		var s := start_dist
		for n in range(per_divider):
			var d: float = s + DASH_LEN / 2.0
			if layout.lanes_painted(d) >= float(k + 1) - 0.001:
				var f := path.road_frame(d)
				xforms.append(Transform3D(Basis(Vector3.UP, f.heading), path.world_pos(d, x)))
			s += DASH_STEP
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _shared("dash_mat")
	return mmi

## Meshes / materials every chunk reuses instead of building its own copy.
## Cleared by "Rebuild Editor Preview" (the streetlight ones read the
## Inspector tuning when built).
var _shared_res: Dictionary = {}

const LAMP_HEAD_SIZE := Vector3(0.5, 0.3, 0.5) * UNIT_SCALE

func _shared(key: String) -> Resource:
	if _shared_res.has(key):
		return _shared_res[key]
	var r: Resource
	match key:
		"dash_mesh":
			var box := BoxMesh.new()
			box.size = Vector3(DASH_WIDTH, DASH_HEIGHT, DASH_LEN)
			r = box
		"dash_mat":
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.9, 0.9, 0.85)
			r = m
		"lamp_frame_left", "lamp_frame_right":
			# Arm reaches toward the road: -lateral from the left (+) side.
			r = _build_streetlight_frame(-1.0 if key == "lamp_frame_left" else 1.0)
		"lamp_pole_mat":
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(0.15, 0.15, 0.17)
			r = m
		"lamp_head":
			var box := BoxMesh.new()
			box.size = LAMP_HEAD_SIZE
			r = box
		"lamp_head_mat":
			var m := StandardMaterial3D.new()
			m.albedo_color = Color(1.0, 0.95, 0.75)
			m.emission_enabled = true
			m.emission = Color(1.0, 0.9, 0.6)
			m.emission_energy_multiplier = streetlight_glow_energy
			r = m
		"lamp_cone":
			r = _build_fake_light_cone(STREETLIGHT_HEIGHT - ARM_DROP, streetlight_cone_angle_deg, streetlight_cone_color)
		"lamp_cone_mat":
			var m := StandardMaterial3D.new()
			m.vertex_color_use_as_albedo = true
			m.albedo_color = Color(1, 1, 1, 1)
			m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			m.cull_mode = BaseMaterial3D.CULL_DISABLED
			r = m
	_shared_res[key] = r
	return r

const ARM_REACH_FRAC := 0.6 # how far the arm extends across the road, as a fraction of ROAD_HALF_WIDTH
const ARM_DROP := 0.6 * UNIT_SCALE # how far the lamp hangs below the arm at its tip

func _build_streetlights(start_dist: float, end_dist: float) -> Node3D:
	var container := Node3D.new()
	container.name = "Streetlights"
	for side in [-1.0, 1.0]:
		# Placed on global multiples of the spacing (not a per-chunk count) so
		# the two sides' half-spacing stagger holds across chunk borders.
		var offset: float = 0.0 if side < 0.0 else STREETLIGHT_SPACING / 2.0
		var d: float = ceilf((start_dist - offset) / STREETLIGHT_SPACING) * STREETLIGHT_SPACING + offset
		while d < end_dist:
			# Skipped inside tunnels, next to overpasses (the arm would punch
			# through the deck) and where a trench's retaining walls have risen
			# above the pole; on viaducts it stands on the deck lip just
			# outside the barrier instead of on the (distant) ground.
			var mode: int = layout.surface_mode(d)
			var skip: bool = mode == RoadLayout.Surface.COVERED \
				or layout.overpass_blocks(d, side * SIDEWALK_HALF_WIDTH, STREETLIGHT_OVERPASS_CLEAR) \
				or layout.lift(d, side * SIDEWALK_HALF_WIDTH) > STREETLIGHT_MAX_LIFT
			if not skip:
				var base: Vector3
				if mode == RoadLayout.Surface.AT_GRADE:
					base = _ground_pos(d, side * (SIDEWALK_HALF_WIDTH + 0.6 * UNIT_SCALE + layout.verge_shift(d, side)))
				else:
					base = _edge_level_pos(d, layout.shoulder_edge(d, side) + side * (DECK_LIP - 0.2 * UNIT_SCALE))
				var f := path.road_frame(d)
				var lamp := _make_streetlight(side)
				container.add_child(lamp)
				lamp.transform = Transform3D(Basis(Vector3.UP, f.heading), base)
			d += STREETLIGHT_SPACING
	return container

const STREETLIGHT_OVERPASS_CLEAR := 10.0 * UNIT_SCALE
const STREETLIGHT_MAX_LIFT := 2.0 * UNIT_SCALE

## Highway-style cantilever pole - a real roadside light isn't a straight
## pole with a lamp on top (that's a pedestrian streetlamp); it plants
## beside the road and reaches an arm OVER the road so the fixture actually
## hangs above the lanes, not above the sidewalk. Shape reads as an
## "upside-down L": vertical pole, horizontal arm at the top bending toward
## the road, then a short drop at the tip where the lamp head hangs.
## `side` is the same -1/+1 `_build_streetlights()` uses for which shoulder
## this pole sits on - the arm always bends the opposite way (toward x=0,
## the road center).
func _make_streetlight(side: float) -> Node3D:
	var root := Node3D.new()
	var toward_road: float = -side # arm direction: away from the sidewalk, over the road
	var arm_length: float = ROAD_HALF_WIDTH * ARM_REACH_FRAC
	var lamp_x: float = toward_road * arm_length
	var lamp_y: float = STREETLIGHT_HEIGHT - ARM_DROP

	# Pole + arm + drop are one shared mesh per side (one draw call, not three).
	var frame := MeshInstance3D.new()
	frame.mesh = _shared("lamp_frame_left" if side > 0.0 else "lamp_frame_right")
	frame.material_override = _shared("lamp_pole_mat")
	root.add_child(frame)

	var head := MeshInstance3D.new()
	head.mesh = _shared("lamp_head")
	head.position = Vector3(lamp_x, lamp_y, 0)
	head.material_override = _shared("lamp_head_mat")
	root.add_child(head)

	# Real light: a downward SpotLight3D at the lamp head. Earlier this was
	# fake-cone-only because ~8 lights per chunk crowded the gl_compatibility
	# per-mesh light cap and squeezed out the player's headlight. With
	# STREETLIGHT_SPACING == CHUNK_LENGTH it's now 1 per side per chunk (so
	# each road mesh sees ~2-4) and max_lights_per_object is 50. A spot (not
	# omni) only reaches meshes under it - road, sidewalk, passing cars - not
	# the buildings behind the pole. No shadows, and distance fade drops far
	# lamps entirely.
	if streetlight_real_light:
		var light := SpotLight3D.new()
		light.position = Vector3(lamp_x, lamp_y - LAMP_HEAD_SIZE.y * 0.5, 0)
		light.rotation.x = -PI / 2.0 # -Z (spot direction) -> straight down
		light.light_color = streetlight_cone_color
		light.light_energy = streetlight_light_energy
		light.spot_range = lamp_y * streetlight_light_range_mult
		light.spot_angle = streetlight_light_angle_deg
		light.spot_attenuation = 0.8
		light.shadow_enabled = false
		light.distance_fade_enabled = true
		light.distance_fade_begin = streetlight_light_fade_begin
		light.distance_fade_length = 100.0
		root.add_child(light)

	# Plus the fake translucent cone for the visible beam in the air - apex at
	# the lamp head (over the road, at the end of the arm).
	var cone := MeshInstance3D.new()
	cone.mesh = _shared("lamp_cone")
	cone.material_override = _shared("lamp_cone_mat")
	cone.position = Vector3(lamp_x, 0, 0)
	root.add_child(cone)

	return root

## The pole, the arm reaching over the road and the short drop to the lamp
## head, merged into one mesh (origin at the pole's foot).
func _build_streetlight_frame(toward_road: float) -> ArrayMesh:
	var arm_length: float = ROAD_HALF_WIDTH * ARM_REACH_FRAC
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(_lamp_cylinder(0.045, 0.065, STREETLIGHT_HEIGHT), 0,
		Transform3D(Basis.IDENTITY, Vector3(0, STREETLIGHT_HEIGHT / 2.0, 0)))
	# CylinderMesh's own axis is Y; the arm is turned to lie flat (along X)
	# reaching from the pole top toward the road, shifted so it starts AT the pole.
	st.append_from(_lamp_cylinder(0.035, 0.035, arm_length), 0,
		Transform3D(Basis.from_euler(Vector3(0, 0, -PI / 2.0 * toward_road)),
			Vector3(toward_road * arm_length / 2.0, STREETLIGHT_HEIGHT, 0)))
	st.append_from(_lamp_cylinder(0.03, 0.03, ARM_DROP), 0,
		Transform3D(Basis.IDENTITY, Vector3(toward_road * arm_length, STREETLIGHT_HEIGHT - ARM_DROP / 2.0, 0)))
	return st.commit()

## Radii in metres. 12 sides - the pole is a few cm thick, the default 64 is wasted.
static func _lamp_cylinder(top_r: float, bottom_r: float, height: float) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r * UNIT_SCALE
	c.bottom_radius = bottom_r * UNIT_SCALE
	c.height = height
	c.radial_segments = 12
	c.rings = 1
	return c

## A translucent, unshaded cone mesh - apex at `height` above this node's
## origin, extending straight down to the ground (y=0), spread by
## `half_angle_deg`. Built directly (no Light3D, no transform tricks) since
## this is a purely visual stand-in, not a real light.
##
## Gradient via vertex color alpha (not a texture) - the apex end (near the
## fixture) is nearly invisible, fading IN toward the base (the ground),
## so it reads as "light landing on the road" rather than a visible solid
## funnel hanging in the air the whole way up. (Material: _shared "lamp_cone_mat".)
func _build_fake_light_cone(height: float, half_angle_deg: float, color: Color) -> ArrayMesh:
	var radius: float = height * tan(deg_to_rad(half_angle_deg))
	var segments := 16
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := Vector3(0, height, 0)
	var apex_color := Color(color.r, color.g, color.b, streetlight_cone_apex_alpha)
	var base_color := Color(color.r, color.g, color.b, streetlight_cone_base_alpha)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0 := Vector3(cos(a0) * radius, 0.0, sin(a0) * radius)
		var p1 := Vector3(cos(a1) * radius, 0.0, sin(a1) * radius)
		st.set_color(apex_color); st.add_vertex(apex)
		st.set_color(base_color); st.add_vertex(p0)
		st.set_color(base_color); st.add_vertex(p1)
	return st.commit()

var _building_aabb_cache: Dictionary = {} # PackedScene -> native AABB (unscaled, metres)

func _building_specs() -> Array[Dictionary]:
	return NIGHT_BUILDING_SPECS if use_night_buildings else BUILDING_SPECS

func _native_aabb(scene: PackedScene) -> AABB:
	if _building_aabb_cache.has(scene):
		return _building_aabb_cache[scene]
	var probe: Node3D = scene.instantiate()
	var aabb := _combined_aabb(probe, Transform3D.IDENTITY)
	_building_aabb_cache[scene] = aabb
	probe.queue_free()
	return aabb

func _native_footprint(scene: PackedScene) -> float:
	var aabb := _native_aabb(scene)
	return maxf(aabb.size.x, aabb.size.z)

func _combined_aabb(node: Node3D, parent_xform: Transform3D) -> AABB:
	var xform := parent_xform * node.transform
	var result := AABB()
	var has_any := false
	if node is MeshInstance3D and node.mesh:
		result = xform * node.mesh.get_aabb()
		has_any = true
	for child in node.get_children():
		if child is Node3D:
			var child_aabb := _combined_aabb(child, xform)
			if not has_any:
				result = child_aabb
				has_any = true
			elif child_aabb.size != Vector3.ZERO:
				result = result.merge(child_aabb)
	return result

func _build_buildings(start_dist: float, end_dist: float, rng: RandomNumberGenerator) -> Node3D:
	var container := Node3D.new()
	container.name = "Buildings"
	for side in [-1.0, 1.0]:
		var s := start_dist
		while s < end_dist:
			if rng.randf() < BUILDING_SPAWN_CHANCE:
				var specs := _building_specs()
				var spec: Dictionary = specs[rng.randi_range(0, specs.size() - 1)]
				var native_footprint: float = _native_footprint(spec.scene)
				var target_footprint: float = BUILDING_FOOTPRINT_OVERRIDES.get(
					spec.name,
					BUILDING_TARGET_FOOTPRINT_MIN + rng.randf() * (BUILDING_TARGET_FOOTPRINT_MAX - BUILDING_TARGET_FOOTPRINT_MIN)
				)
				var scale_factor: float = (target_footprint / native_footprint) * UNIT_SCALE
				var d: float = s + rng.randf() * 8.0 * UNIT_SCALE
				var lateral: float = side * (BUILDING_OFFSET + target_footprint * UNIT_SCALE * 0.5 + rng.randf() * 10.0 * UNIT_SCALE)
				# RoadLayout keeps hills, the open sea and overpass decks clear.
				var radius: float = target_footprint * UNIT_SCALE * 0.75 # half the diagonal, roughly
				if not layout.buildings_allowed(d, lateral, radius) or layout.surface_mode(d) == RoadLayout.Surface.SEA:
					s += BUILDING_SPACING
					continue
				var inst: Node3D = spec.scene.instantiate()
				container.add_child(inst)
				inst.scale = Vector3.ONE * scale_factor
				var f := path.road_frame(d)
				# The building stands on the LEVEL ground beside the road
				# (_ground_pos), rotated ONLY to heading - no roll from bank,
				# matching the original's yaw-only convention for every rigid
				# prop. Its base (native y = 0) is set to the LOWEST ground
				# height anywhere under its footprint (sampled along the
				# road, worst case = its longer side), sunk a touch: on a
				# graded road the uphill part sits slightly into the slope
				# instead of any corner hanging in the air.
				var half_run: float = native_footprint * 0.5 * scale_factor
				var base_y: float = INF
				for k in [-1.0, -0.5, 0.0, 0.5, 1.0]:
					base_y = minf(base_y, _ground_pos(d + k * half_run, lateral).y)
				var ground := _ground_pos(d, lateral)
				inst.position = Vector3(ground.x, base_y - BUILDING_SINK, ground.z)
				# +PI here (was missing) - user fixed this exact same facing
				# issue in the original Voxel Driver three.js project too;
				# without it, buildings face away from the road instead of
				# toward it.
				inst.rotation.y = f.heading + (PI / 2.0) * side + PI
			s += BUILDING_SPACING
	return container
