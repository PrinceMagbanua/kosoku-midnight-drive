extends MultiMeshInstance3D

## Thin smoke/haze hanging over the road ahead of the player, which the car
## drives through. Deliberately cheap:
## - One MultiMesh = one draw call for every puff, unshaded, no shadows.
## - A fixed pool of `puff_count` puffs placed at distances along the road
##   (RoadGenerator's RoadPath). A puff only gets touched when the player
##   passes it - it's recycled to the far end of the window. Density is per
##   distance, not per second, so it looks the same at 50 or 300 km/h.
## - Billboarding/drift/fading all happen in road_haze.gdshader; the
##   near fade removes a puff before it can fill the screen (overdraw).
## Finds RoadGenerator via its "road_generator" group, same as Weather.
##
## Smoke only exists in zones along the road, laid out fresh per run:
## clear stretch -> smoke zone -> clear stretch -> ... Each smoke zone is
## either a long patch (patch_length_min..max) or, patch_chance of the time
## otherwise, a short cluster of about `cluster_puffs` puffs. Puffs recycled
## into a clear stretch are just hidden (scale 0), so zone edges stay put in
## the world and smoke appears at the far end as you approach a patch.
##
## Tuning: select the RoadHaze node in world.tscn. Tint/opacity apply live.

const UNIT_SCALE := RoadMetrics.UNIT_SCALE
const HAZE_SHADER := preload("res://MAIN/misc/road_haze.gdshader")
const PUFF_TEXTURE := preload("res://MAIN/misc/tyre smoke/smoke.png")

@export_group("Look")
@export var tint: Color = Color(0.55, 0.58, 0.65):
	set(v):
		tint = v
		_update_material()
@export_range(0.0, 1.0) var opacity: float = 0.05:
	set(v):
		opacity = v
		_update_material()
@export var size_min: float = 7.0 * UNIT_SCALE
@export var size_max: float = 14.0 * UNIT_SCALE
@export var height_min: float = 0.5 * UNIT_SCALE
@export var height_max: float = 2.5 * UNIT_SCALE
@export var lateral_spread: float = RoadMetrics.ROAD_HALF_WIDTH * 1.3

@export_group("Density")
## Puffs in the visible window at once (inside a smoke patch).
@export var puff_count: int = 14
## Window of road (world units along the path) kept filled with puffs.
@export var ahead_distance: float = 130.0 * UNIT_SCALE
@export var behind_distance: float = 4.0 * UNIT_SCALE

@export_group("Zones (metres)")
@export var clear_length_min: float = 500.0
@export var clear_length_max: float = 1500.0
@export var patch_length_min: float = 500.0
@export var patch_length_max: float = 1000.0
## Chance a smoke zone is a long patch rather than a short cluster.
@export_range(0.0, 1.0) var patch_chance: float = 0.5
## Roughly how many puffs a short cluster has.
@export var cluster_puffs: int = 20

var _rg: Node
var _path: RoadPath
var _dists := PackedFloat32Array()
var _last_dist := 0.0
var _mat: ShaderMaterial

# Smoke zones as [start, end) intervals in world units along the path,
# generated lazily ahead of the player.
var _zone_starts := PackedFloat32Array()
var _zone_ends := PackedFloat32Array()
var _zones_generated_to := 0.0
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = quad
	mm.instance_count = puff_count
	mm.visible_instance_count = 0 # nothing drawn until the road exists
	multimesh = mm

	_mat = ShaderMaterial.new()
	_mat.shader = HAZE_SHADER
	_mat.set_shader_parameter("puff_texture", PUFF_TEXTURE)
	_mat.set_shader_parameter("far_fade_start", ahead_distance * 0.7)
	_mat.set_shader_parameter("far_fade_end", ahead_distance)
	material_override = _mat
	_update_material()
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Billboarding happens in the shader, outside the instances' own AABB.
	extra_cull_margin = size_max
	_dists.resize(puff_count)

func _update_material() -> void:
	if _mat == null:
		return
	_mat.set_shader_parameter("tint", tint)
	_mat.set_shader_parameter("opacity", opacity)

func _process(_delta: float) -> void:
	if _rg == null or not is_instance_valid(_rg):
		_rg = get_tree().get_first_node_in_group("road_generator")
		if _rg == null:
			return
	if _rg.path == null or _rg.tracker == null:
		return
	var d: float = _rg.tracker.dist

	# New run (RoadGenerator builds a fresh RoadPath): new zone layout, and
	# re-scatter the whole window. A big jump in distance re-scatters too.
	if _rg.path != _path:
		_path = _rg.path
		_reset_zones()
		_scatter(d)
	elif absf(d - _last_dist) > ahead_distance * 0.5:
		_scatter(d)
	else:
		for i in puff_count:
			if _dists[i] < d - behind_distance:
				_place(i, d + ahead_distance * randf_range(0.85, 1.0))
	_last_dist = d

func _scatter(d: float) -> void:
	for i in puff_count:
		_place(i, d + randf_range(behind_distance, ahead_distance))
	multimesh.visible_instance_count = -1

func _place(i: int, dist: float) -> void:
	dist = minf(dist, _path.total_length())
	_dists[i] = dist
	if not _is_smoky(dist):
		multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3.ZERO))
		return
	var pos: Vector3 = _path.world_pos(dist, randf_range(-lateral_spread, lateral_spread))
	pos.y += randf_range(height_min, height_max)
	var s: float = randf_range(size_min, size_max)
	multimesh.set_instance_transform(i, Transform3D(Basis().scaled(Vector3(s, s, s)), pos))

func _reset_zones() -> void:
	_zone_starts.clear()
	_zone_ends.clear()
	_zones_generated_to = 0.0
	_rng.randomize()

func _is_smoky(dist: float) -> bool:
	while _zones_generated_to <= dist:
		_generate_next_zone()
	var i: int = _zone_starts.bsearch(dist, false) - 1
	return i >= 0 and dist < _zone_ends[i]

func _generate_next_zone() -> void:
	var start: float = _zones_generated_to + _rng.randf_range(clear_length_min, clear_length_max) * UNIT_SCALE
	var length: float
	if _rng.randf() < patch_chance:
		length = _rng.randf_range(patch_length_min, patch_length_max) * UNIT_SCALE
	else:
		# Puffs are spaced ~ahead_distance / puff_count apart along the road.
		length = float(cluster_puffs) * ahead_distance / float(puff_count)
	_zone_starts.append(start)
	_zone_ends.append(start + length)
	_zones_generated_to = start + length
