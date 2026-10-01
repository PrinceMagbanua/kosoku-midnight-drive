class_name EngineDamageFx
extends Node3D

## Engine health feedback for the player car, driven by CarDamageModel's
## chassis state (engine_state()):
## - HEALTHY  (100-50%): nothing
## - SMOKING  (<50%):    thin white wisps that vanish almost at once + faint rattle
## - KNOCKING (<25%):    dark grey smoke + click-clack knock (engine stutters)
## - BURNING  (<10%):    black smoke + flames licking out of the bonnet gap,
##                       heavier misfire stutter + fire crackle
## Cosmetic only - never touches engine power.
##
## Sits on the car (crash_system.gd adds it) at the bonnet - re-placed each
## run by bind(), since the Customize screen can swap the hull. The smoke is
## world-space, so at speed it streams out behind the car.
##
## Audio loops are optional files in SFX_DIR (rattle / knock / fire, .ogg,
## .wav or .mp3) - any that aren't there yet are skipped. The knock stutter
## itself doesn't need a file: it dips the engine sound's pitch_influence the
## same way a backfire does (other_sounds.gd eases it back every tick).

const SFX_DIR := "res://MAIN/sfx/engine_damage/"
const SFX_NAMES := ["rattle", "knock", "fire"]
const SFX_EXTS := [".ogg", ".wav", ".mp3"]
## Loop volume (linear, fraction of SFX volume) per loop, and the state it
## starts at.
const LOOP_VOLUME := {"rattle": 0.35, "knock": 0.6, "fire": 0.5}
const LOOP_FROM := {
	"rattle": CarDamageModel.EngineState.SMOKING,
	"knock": CarDamageModel.EngineState.KNOCKING,
	"fire": CarDamageModel.EngineState.BURNING,
}

## Stutter: seconds between pitch dips (random in range) and dip depth.
const KNOCK_INTERVAL := Vector2(0.18, 0.7)
const KNOCK_DIP := 0.82
const BURN_INTERVAL := Vector2(0.1, 0.4)
const BURN_DIP := 0.65

const SMOKE_SHADER := preload("res://MAIN/misc/tyre smoke/particle_billboard.gdshader")
const SMOKE_TEXTURE := preload("res://MAIN/misc/tyre smoke/smoke.png")
const FLAME_TEXTURE := preload("res://MAIN/misc/backfire_particles/backfire.png")

var _car # car.gd's RigidBody3D - untyped so its script props (rpm/IdleRPM) resolve
var _damage: CarDamageModel
var _state := CarDamageModel.EngineState.HEALTHY
var _wisps: CPUParticles3D
var _smoke: CPUParticles3D
var _black: CPUParticles3D
var _flames: CPUParticles3D
var _loops := {} # name -> AudioStreamPlayer3D (only for files that exist)
var _stutter_timer := 0.0

func _ready() -> void:
	_wisps = _make_smoke(Color(0.9, 0.9, 0.9, 0.35), 14, 0.45, Vector2(0.5, 1.1), 2.5)
	_smoke = _make_smoke(Color(0.22, 0.22, 0.22, 0.6), 30, 1.1, Vector2(0.9, 2.6), 3.5)
	_black = _make_smoke(Color(0.05, 0.05, 0.05, 0.8), 40, 1.5, Vector2(1.2, 3.4), 4.5)
	_flames = _make_flames()
	for n in SFX_NAMES:
		var stream := _load_loop(n)
		if stream == null:
			continue
		var p := AudioStreamPlayer3D.new()
		p.stream = stream
		p.unit_size = 50.0
		add_child(p)
		_loops[n] = p
	_state = CarDamageModel.EngineState.HEALTHY # emitters start off

## Re-places the emitters at `car`'s bonnet. Call at run start.
func bind(car: Node3D, damage: CarDamageModel) -> void:
	_car = car
	_damage = damage
	position = _emit_point(car)
	_set_state(CarDamageModel.EngineState.HEALTHY)

func _physics_process(delta: float) -> void:
	if _damage == null or _car == null:
		return
	var s := GameState.current
	var live := s == GameState.State.PLAYING or s == GameState.State.CRASHING or s == GameState.State.CRASHED
	_set_state(_damage.engine_state() if live else CarDamageModel.EngineState.HEALTHY)
	_update_audio(s == GameState.State.PLAYING)
	if s == GameState.State.PLAYING and _state >= CarDamageModel.EngineState.KNOCKING:
		_stutter(delta / maxf(Engine.time_scale, 0.001))

func _set_state(state: CarDamageModel.EngineState) -> void:
	if state == _state:
		return
	_state = state
	_wisps.emitting = state == CarDamageModel.EngineState.SMOKING
	_smoke.emitting = state == CarDamageModel.EngineState.KNOCKING
	_black.emitting = state == CarDamageModel.EngineState.BURNING
	_flames.emitting = state == CarDamageModel.EngineState.BURNING

func _update_audio(playing: bool) -> void:
	var vol: float = misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume
	var rpm_pitch := 1.0
	if "rpm" in _car and "IdleRPM" in _car:
		rpm_pitch = clampf(absf(_car.rpm) / maxf(_car.IdleRPM, 1.0) * 0.35, 0.6, 2.2)
	for n in _loops:
		var p: AudioStreamPlayer3D = _loops[n]
		var on: bool = playing and _state >= LOOP_FROM[n]
		if on and not p.playing:
			p.play()
		elif not on and p.playing:
			p.stop()
		if on:
			p.volume_db = linear_to_db(clampf(vol * LOOP_VOLUME[n], 0.0001, 1.0))
			if n == "knock":
				p.pitch_scale = rpm_pitch # knocks faster as the engine revs

## Random misfire dips on the engine sound's pitch.
func _stutter(real_delta: float) -> void:
	_stutter_timer -= real_delta
	if _stutter_timer > 0.0:
		return
	var burning := _state == CarDamageModel.EngineState.BURNING
	var iv: Vector2 = BURN_INTERVAL if burning else KNOCK_INTERVAL
	_stutter_timer = randf_range(iv.x, iv.y)
	var engine = _car.get_node_or_null("engine_sound") # crossfade.gd, untyped for pitch_influence
	if engine and "pitch_influence" in engine:
		engine.pitch_influence = minf(engine.pitch_influence, BURN_DIP if burning else KNOCK_DIP)

## Top of the bonnet (car-local), or the front of the hull's bounds for cars
## without a separate bonnet part.
func _emit_point(car: Node3D) -> Vector3:
	var hull := car.get_node_or_null("VoxelCarMesh") as Node3D
	if hull == null:
		return Vector3(0, 1.5, 3.0)
	var to_car := car.global_transform.affine_inverse()
	var bonnet := hull.get_node_or_null(ModularCarBuilder.PART_PREFIX + "Bonnet")
	var box := _bounds(bonnet if bonnet else hull, to_car)
	if box.size == Vector3.ZERO:
		return Vector3(0, 1.5, 3.0)
	if bonnet:
		return Vector3(box.get_center().x, box.end.y, box.get_center().z)
	return Vector3(box.get_center().x, box.position.y + box.size.y * 0.55, box.end.z - box.size.z * 0.2)

func _bounds(root: Node, to_car: Transform3D) -> AABB:
	var box := AABB()
	var have := false
	for mi in StructuredCarParts.mesh_instances(root):
		if mi.mesh == null or mi.has_meta("lens"):
			continue
		var b: AABB = (to_car * mi.global_transform) * mi.mesh.get_aabb()
		box = b if not have else box.merge(b)
		have = true
	return box

func _load_loop(n: String) -> AudioStream:
	for ext in SFX_EXTS:
		var path: String = SFX_DIR + n + ext
		if ResourceLoader.exists(path):
			var stream := load(path) as AudioStream
			if stream and "loop" in stream:
				stream.set("loop", true)
			return stream
	return null

# --- emitters ------------------------------------------------------------

## World-space smoke puffs rising out of the bonnet. `size` = start/end scale
## over each puff's life; `rise` = upward speed.
func _make_smoke(color: Color, amount: int, lifetime: float, size: Vector2, rise: float) -> CPUParticles3D:
	var mat := ShaderMaterial.new()
	mat.shader = SMOKE_SHADER
	mat.set_shader_parameter("albedo", Color.WHITE)
	mat.set_shader_parameter("texture_albedo", SMOKE_TEXTURE)
	mat.set_shader_parameter("particles_anim_h_frames", 1)
	mat.set_shader_parameter("particles_anim_v_frames", 1)
	var quad := QuadMesh.new()
	quad.material = mat
	var p := CPUParticles3D.new()
	p.mesh = quad
	p.amount = amount
	p.lifetime = lifetime
	p.local_coords = false
	p.emitting = false
	p.randomness = 0.4
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	p.emission_sphere_radius = 0.4
	p.direction = Vector3.UP
	p.spread = 25.0
	p.gravity = Vector3(0, rise * 0.5, 0) # a little buoyancy
	p.initial_velocity_min = rise * 0.6
	p.initial_velocity_max = rise
	p.damping_min = 1.0
	p.damping_max = 2.0
	p.angle_min = -180.0
	p.angle_max = 180.0
	p.angular_velocity_min = -40.0
	p.angular_velocity_max = 40.0
	p.scale_amount_min = size.x
	p.scale_amount_max = size.x * 1.3
	var grow := Curve.new()
	grow.max_value = maxf(size.y / size.x, 1.0)
	grow.add_point(Vector2(0.0, 1.0))
	grow.add_point(Vector2(1.0, size.y / size.x))
	p.scale_amount_curve = grow
	p.color = color
	p.color_ramp = _fade_ramp()
	add_child(p)
	return p

func _make_flames() -> CPUParticles3D:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = FLAME_TEXTURE
	var quad := QuadMesh.new()
	quad.size = Vector2(0.9, 1.2)
	quad.material = mat
	var p := CPUParticles3D.new()
	p.mesh = quad
	p.amount = 24
	p.lifetime = 0.35
	p.local_coords = true # flames stay stuck to the bonnet, not trailed
	p.emitting = false
	p.randomness = 0.6
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(0.8, 0.05, 0.6)
	p.direction = Vector3.UP
	p.spread = 15.0
	p.gravity = Vector3(0, 6.0, 0)
	p.initial_velocity_min = 1.5
	p.initial_velocity_max = 3.5
	p.scale_amount_min = 0.6
	p.scale_amount_max = 1.4
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.2))
	p.scale_amount_curve = shrink
	p.color = Color(1.0, 0.55, 0.15)
	p.color_ramp = _fade_ramp()
	add_child(p)
	return p

## Full alpha that fades out over the particle's life.
func _fade_ramp() -> Gradient:
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	return g
