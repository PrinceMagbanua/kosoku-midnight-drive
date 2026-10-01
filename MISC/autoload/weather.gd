extends Node

## Autoload. Minimal rain system - periodically rolls whether it's raining,
## weighted by the player's current biome (BiomeMap, keyed off RoadGenerator's
## RoadPath - looked up via the "road_generator" group since this is a
## global singleton and can't hold a scene NodePath). Visual-only by design:
## `is_raining`/`rain_intensity` just drive rain particles and wheel spray
## mist (see wheel_spray.gd / traffic_car.gd) - no grip/handling change.
##
## `rain_intensity` ramps rather than snaps, so effects fade in/out instead
## of popping. A DOWNPOUR biome (BiomeMap.get_biome) forces rain on for as
## long as the player is in that region, instead of waiting for a periodic
## roll - the "place where rain is endless" case.

var is_raining: bool = false
var rain_intensity: float = 0.0
## Player is under cover (inside a tunnel) - set every frame by TunnelRig.
## Rain keeps its state (it's still raining outside), but the streaks and the
## player's tyre spray stop.
var sheltered: bool = false

const MIN_STATE_DURATION := 25.0
const MAX_STATE_DURATION := 90.0
const RAIN_RAMP_RATE := 0.3 # intensity change per second

var _state_timer: float = 0.0
var _next_roll_time: float = 4.0

# Rain streaks, built lazily around the player car - see _ensure_rain_emitter.
# Global-space particles (local_coords = false) so the emitter can be
# repositioned onto the car every frame without dragging existing particles
# through the car's own rotation (would look like rain tilting with the car
# on a banked curve otherwise).
#
# Spawning ONLY from a thin slab high overhead (the original approach) meant
# a raindrop had to fall a long way before it reached a height the camera
# actually looks at - and since local_coords=false means a spawned drop does
# NOT travel forward with the car afterward, a fast car simply outran that
# fall time and left every drop's now-visible-height position behind it,
# off-screen, before it ever became visible. Spawning across a tall band
# (RAIN_HEIGHT_MIN..RAIN_HEIGHT_MAX, most of it already at/near camera
# height) means plenty of drops are visible immediately rather than needing
# to fall into view - combined with a much faster fall speed so whatever
# still does fall crosses that band quickly regardless of car speed.
const RAIN_HEIGHT_MIN := -2.0 * RoadMetrics.UNIT_SCALE # slightly below car height - catches the cockpit view too
const RAIN_HEIGHT_MAX := 20.0 * RoadMetrics.UNIT_SCALE
const RAIN_SPAN := 22.0 * RoadMetrics.UNIT_SCALE
var _rain_emitter: CPUParticles3D = null
# The player car and the road generator, looked up again only if they go away.
var _car: Node3D
var _road_gen: Node

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state != GameState.State.PLAYING or old_state == GameState.State.PAUSED:
		return
	# Fresh run - don't carry over whatever was happening on the last one.
	is_raining = false
	rain_intensity = 0.0
	_state_timer = 0.0
	_next_roll_time = randf_range(4.0, 15.0)

func _process(delta: float) -> void:
	if GameState.current != GameState.State.PLAYING:
		return
	var chance := _current_rain_chance()
	if chance >= 0.999:
		is_raining = true
	else:
		_state_timer += delta
		if _state_timer >= _next_roll_time:
			_state_timer = 0.0
			_next_roll_time = randf_range(MIN_STATE_DURATION, MAX_STATE_DURATION)
			is_raining = randf() < chance
	rain_intensity = move_toward(rain_intensity, 1.0 if is_raining else 0.0, delta * RAIN_RAMP_RATE)
	_update_rain_emitter()

## Lazily builds one CPUParticles3D of falling streaks above the player car
## and keeps it centered there every frame - a single shared effect (not
## per-wheel like the spray) since rain itself isn't a per-car detail.
func _update_rain_emitter() -> void:
	if not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("player_car") as Node3D
	var car := _car
	if car == null:
		return
	if _rain_emitter == null or not is_instance_valid(_rain_emitter):
		_rain_emitter = _build_rain_emitter()
		get_tree().root.add_child(_rain_emitter)
	var center_height := (RAIN_HEIGHT_MIN + RAIN_HEIGHT_MAX) / 2.0
	_rain_emitter.global_position = car.global_position + Vector3(0, center_height, 0)
	_rain_emitter.emitting = rain_intensity > 0.02 and not sheltered
	var mat := _rain_emitter.material_override as StandardMaterial3D
	if mat:
		mat.albedo_color.a = clampf(rain_intensity, 0.0, 1.0) * 0.5

func _build_rain_emitter() -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.amount = 350
	p.lifetime = 0.7
	p.local_coords = false
	p.emitting = false
	p.mesh = BoxMesh.new()
	(p.mesh as BoxMesh).size = Vector3(0.03, 1.1, 0.03) * RoadMetrics.UNIT_SCALE
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(RAIN_SPAN, (RAIN_HEIGHT_MAX - RAIN_HEIGHT_MIN) / 2.0, RAIN_SPAN)
	p.direction = Vector3.DOWN
	p.spread = 3.0
	p.gravity = Vector3(0, -90.0 * RoadMetrics.UNIT_SCALE, 0)
	p.initial_velocity_min = 45.0 * RoadMetrics.UNIT_SCALE
	p.initial_velocity_max = 65.0 * RoadMetrics.UNIT_SCALE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(0.75, 0.8, 0.85, 0.0)
	p.material_override = mat
	return p

func _current_rain_chance() -> float:
	if not is_instance_valid(_road_gen):
		_road_gen = get_tree().get_first_node_in_group("road_generator")
	var rg := _road_gen
	if rg == null or rg.tracker == null or rg.path == null:
		return 0.0
	var biome := BiomeMap.get_biome(rg.tracker.dist, rg.path.seed_value)
	return biome.rain_chance
