extends Node

## Slow Night -> Dawn -> Sunset loop with no bright day. Each phase takes a
## third of `cycle_length`; for the last `blend_fraction` of a phase the
## sky fades into the next one (Sunset wraps back to Night).
##
## Lives as a child of the WorldEnvironment (NightEnvironment.tscn), like
## FogBand, and edits whatever Environment / sky ShaderMaterial that node
## currently uses - so it drives the override world.tscn carries. The Night
## keyframe is read from that live look in _ready(), so tuning the night
## sky in world.tscn keeps working as before; Dawn and Sunset are the
## exports below. Sky.gdshader itself is untouched - only its uniforms move.
##
## The LIGHT follows the sky too: each phase has an ambient colour/energy and
## a moonlight colour/energy, blended the same way, so the road and cars pick
## up the phase's tint (cool blue at night and dawn, warm at sunset). Night's
## come from the live Environment and the moonlight node like the rest of the
## night look. `brightness` multiplies the ambient and moon energy of every
## phase - the one knob for lighter/darker overall.
##
## Pausable on purpose: the tree is paused in the menu, garage, pause and
## crash screens, so the clock only advances while driving. Every fresh run
## (same trigger as RunReset) starts at a random point in the cycle.

const SKY_KEYS := [
	"zenith_tint", "horizon_tint", "horizon_glow_tint", "horizon_glow_strength",
	"cloud_tint", "star_brightness", "galaxy_strength",
]

@export var cycle_length: float = 360.0
@export_range(0.0, 1.0) var blend_fraction: float = 0.5
@export var moonlight_path: NodePath = NodePath("../moonlight")
## Overall light level: multiplies ambient and moonlight energy in every phase.
@export_range(0.0, 4.0, 0.05) var brightness: float = 1.0

@export_group("Dawn")
@export var dawn_zenith_tint: Color = Color(0.03, 0.06, 0.13)
@export var dawn_horizon_tint: Color = Color(0.06, 0.1, 0.17)
@export var dawn_horizon_glow_tint: Color = Color(0.1, 0.18, 0.28)
@export_range(0.0, 2.0) var dawn_horizon_glow_strength: float = 0.3
@export var dawn_cloud_tint: Color = Color(0.09, 0.11, 0.16)
@export_range(0.0, 3.0) var dawn_star_brightness: float = 0.8
@export_range(0.0, 1.0) var dawn_galaxy_strength: float = 0.02
@export var dawn_fog_light_color: Color = Color(0.05, 0.07, 0.1)
@export var dawn_ambient_color: Color = Color(0.1, 0.15, 0.24)
@export var dawn_ambient_energy: float = 1.0
@export var dawn_moon_color: Color = Color(0.75, 0.85, 1.0)
@export var dawn_moon_energy: float = 0.18

@export_group("Sunset")
@export var sunset_zenith_tint: Color = Color(0.05, 0.025, 0.08)
@export var sunset_horizon_tint: Color = Color(0.16, 0.06, 0.07)
@export var sunset_horizon_glow_tint: Color = Color(0.4, 0.14, 0.08)
@export_range(0.0, 2.0) var sunset_horizon_glow_strength: float = 0.35
@export var sunset_cloud_tint: Color = Color(0.14, 0.08, 0.1)
@export_range(0.0, 3.0) var sunset_star_brightness: float = 0.4
@export_range(0.0, 1.0) var sunset_galaxy_strength: float = 0.0
@export var sunset_fog_light_color: Color = Color(0.09, 0.05, 0.05)
@export var sunset_ambient_color: Color = Color(0.22, 0.13, 0.11)
@export var sunset_ambient_energy: float = 1.0
@export var sunset_moon_color: Color = Color(1.0, 0.8, 0.65)
@export var sunset_moon_energy: float = 0.16

var _keys: Array[Dictionary] = []
var _t: float = 0.0
var _moon: DirectionalLight3D # the moonlight node, fetched once in _ready

func _ready() -> void:
	var sky_mat := _sky_material()
	var env := _environment()
	if sky_mat == null or env == null:
		return
	_moon = get_node_or_null(moonlight_path) as DirectionalLight3D
	var moon := _moon
	var night := {}
	for key in SKY_KEYS:
		night[key] = _as_color_or_float(sky_mat.get_shader_parameter(key))
	night["fog_light_color"] = env.fog_light_color
	night["ambient_color"] = env.ambient_light_color
	night["ambient_energy"] = env.ambient_light_energy
	night["moon_color"] = moon.light_color if moon else Color.WHITE
	night["moon_energy"] = moon.light_energy if moon else 0.0
	_keys = [night, _dawn_key(), _sunset_key()]
	GameState.state_changed.connect(_on_state_changed)
	_randomize_phase()

func _process(delta: float) -> void:
	if _keys.is_empty() or cycle_length <= 0.0:
		return
	_t = fposmod(_t + delta, cycle_length)
	_apply()

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state != GameState.State.PLAYING or old_state == GameState.State.PAUSED:
		return
	_randomize_phase()

func _randomize_phase() -> void:
	_t = randf() * cycle_length
	_apply()

func _apply() -> void:
	var sky_mat := _sky_material()
	var env := _environment()
	if sky_mat == null or env == null:
		return
	var p := fposmod(_t / cycle_length, 1.0) * 3.0
	var phase := mini(int(p), 2)
	var w := smoothstep(1.0 - blend_fraction, 1.0, p - phase)
	var from: Dictionary = _keys[phase]
	var to: Dictionary = _keys[(phase + 1) % 3]
	for key in SKY_KEYS:
		sky_mat.set_shader_parameter(key, _blend(from[key], to[key], w))
	env.fog_light_color = _blend(from["fog_light_color"], to["fog_light_color"], w)
	env.ambient_light_color = _blend(from["ambient_color"], to["ambient_color"], w)
	env.ambient_light_energy = _blend(from["ambient_energy"], to["ambient_energy"], w) * brightness
	if _moon:
		_moon.light_color = _blend(from["moon_color"], to["moon_color"], w)
		_moon.light_energy = _blend(from["moon_energy"], to["moon_energy"], w) * brightness

func _dawn_key() -> Dictionary:
	return {
		"zenith_tint": dawn_zenith_tint,
		"horizon_tint": dawn_horizon_tint,
		"horizon_glow_tint": dawn_horizon_glow_tint,
		"horizon_glow_strength": dawn_horizon_glow_strength,
		"cloud_tint": dawn_cloud_tint,
		"star_brightness": dawn_star_brightness,
		"galaxy_strength": dawn_galaxy_strength,
		"fog_light_color": dawn_fog_light_color,
		"ambient_color": dawn_ambient_color,
		"ambient_energy": dawn_ambient_energy,
		"moon_color": dawn_moon_color,
		"moon_energy": dawn_moon_energy,
	}

func _sunset_key() -> Dictionary:
	return {
		"zenith_tint": sunset_zenith_tint,
		"horizon_tint": sunset_horizon_tint,
		"horizon_glow_tint": sunset_horizon_glow_tint,
		"horizon_glow_strength": sunset_horizon_glow_strength,
		"cloud_tint": sunset_cloud_tint,
		"star_brightness": sunset_star_brightness,
		"galaxy_strength": sunset_galaxy_strength,
		"fog_light_color": sunset_fog_light_color,
		"ambient_color": sunset_ambient_color,
		"ambient_energy": sunset_ambient_energy,
		"moon_color": sunset_moon_color,
		"moon_energy": sunset_moon_energy,
	}

func _environment() -> Environment:
	var world_env := get_parent() as WorldEnvironment
	return world_env.environment if world_env else null

func _sky_material() -> ShaderMaterial:
	var env := _environment()
	if env == null or env.sky == null:
		return null
	return env.sky.sky_material as ShaderMaterial

## vec3 uniforms can come back as Vector3 when the material never set them.
func _as_color_or_float(v: Variant) -> Variant:
	if v is Vector3:
		return Color(v.x, v.y, v.z)
	return v

func _blend(a: Variant, b: Variant, w: float) -> Variant:
	if a is Color:
		return (a as Color).lerp(b, w)
	return lerpf(a, b, w)
