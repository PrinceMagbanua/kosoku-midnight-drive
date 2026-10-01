extends Node3D

## Distant horizon: two open cylinder bands around the camera, mountains
## behind and a city skyline in front, drawn by skyline.gdshader. They follow
## the active camera every frame, like a skybox, so they are never reached and
## need no streaming. Cost is 2 draw calls and a few hundred triangles in total.
## Both radii must stay under the chase camera's far plane (1000).
## Look (colours, heights, windows) is tuned in the shader's uniforms. Set
## them per band with the exported materials below.

@export var mountain_radius: float = 930.0
@export var city_radius: float = 840.0
## How far each band reaches below and above the horizon (world units).
@export var below_horizon: float = 200.0
@export var above_horizon: float = 320.0

@export var mountain_material: ShaderMaterial
@export var city_material: ShaderMaterial

const SHADER := preload("res://MAIN/misc/skyline.gdshader")
## The city uniforms sea.gdshader shares (skyline_city.gdshaderinc).
const CITY_UNIFORMS := [
	"building_count", "building_min", "building_max", "building_gap_chance",
	"window_color", "window_lit_chance", "window_columns", "window_row_height",
]
const SEA_FIND_TRIES := 10 # frames to look for the sea before giving up (scenes without one)

var _bands: Array[MeshInstance3D] = []
var _sea_material: ShaderMaterial
var _sea_tries := 0
var _sea_sees_skyline := true

func _ready() -> void:
	if mountain_material == null:
		mountain_material = ShaderMaterial.new()
		mountain_material.shader = SHADER
		mountain_material.set_shader_parameter("mode", 0)
		mountain_material.set_shader_parameter("base_color", Color(0.045, 0.05, 0.075))
	if city_material == null:
		city_material = ShaderMaterial.new()
		city_material.shader = SHADER
		city_material.set_shader_parameter("mode", 1)
		city_material.set_shader_parameter("base_color", Color(0.02, 0.022, 0.03))
	_bands.append(_make_band(mountain_radius, mountain_material))
	_bands.append(_make_band(city_radius, city_material))

func _make_band(radius: float, mat: ShaderMaterial) -> MeshInstance3D:
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius
	cyl.bottom_radius = radius
	cyl.height = below_horizon + above_horizon
	cyl.radial_segments = 96
	cyl.rings = 1
	cyl.cap_top = false
	cyl.cap_bottom = false
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# The mesh is centred on its origin, so shift it so the band spans
	# [-below_horizon, +above_horizon], and tell the shader where the horizon is.
	var centre_y: float = (above_horizon - below_horizon) * 0.5
	mi.position.y = centre_y
	mat.set_shader_parameter("horizon_offset", centre_y)
	add_child(mi)
	return mi

func _process(_delta: float) -> void:
	visible = misc_graphics_settings.show_skyline
	_update_sea_reflection()
	if not visible:
		return
	var cam := get_viewport().get_camera_3d()
	if cam:
		global_position = cam.global_position

## The sea (RoadBridge.make_sea) mirrors the city's lit windows using the same
## city function (skyline_city.gdshaderinc). Once it's found, the city
## material's values are copied onto its material so the reflection matches
## however the skyline is tuned; after that only the show/hide state is pushed,
## and only when it changes.
func _update_sea_reflection() -> void:
	if _sea_material == null:
		if _sea_tries >= SEA_FIND_TRIES:
			return
		_sea_tries += 1
		var sea := get_tree().get_first_node_in_group(RoadBridge.SEA_GROUP) as MeshInstance3D
		_sea_material = sea.material_override as ShaderMaterial if sea else null
		if _sea_material == null:
			return
		for key in CITY_UNIFORMS:
			var value: Variant = city_material.get_shader_parameter(key)
			if value != null: # null = never set, the shader default applies to both
				_sea_material.set_shader_parameter(key, value)
		_sea_material.set_shader_parameter("skyline_radius", city_radius)
		_sea_sees_skyline = not visible # force the push below
	if _sea_sees_skyline != visible:
		_sea_sees_skyline = visible
		_sea_material.set_shader_parameter("skyline_visible", 1.0 if visible else 0.0)
