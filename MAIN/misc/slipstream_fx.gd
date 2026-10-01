class_name SlipstreamFx
extends Node3D

## The slipstream "charging" visual (owned by slipstream_scorer.gd): the draft
## pocket behind the lead car drawn as four glowing rails - an outline of the
## tunnel of still air - that grow from the lead car's tail back toward the
## player's nose as the charge builds. They start faint and smoke-white, turn
## cyan on the way, and pulse once the charge is full ("swing out now"). A
## thin stream of warp streaks (WarpStreaks) flows back through the pocket,
## stronger with charge.
##
## The scorer calls set_draft() every physics tick while drafting and
## clear_draft() when it ends; positions are re-read from the two cars every
## rendered frame so the rails stay glued to them.

const RAIL_THICKNESS := 0.07 # world units
const RAIL_LOW := 0.25 # rail heights above each car's origin
const RAIL_HIGH := 1.9
const RAIL_INSET := 0.85 # rails sit at this share of each car's half-width
const ALPHA_EMPTY := 0.25
const ALPHA_FULL := 0.85
const PULSE_RATE := 14.0 # rad/s once full
const PULSE_DEPTH := 0.3
const STREAK_AMOUNT := 16
const STREAK_LIFETIME := 0.3
const STREAK_ALPHA := 0.5

var _car: Node3D
var _lead: Node3D
var _charge := 0.0
var _time := 0.0
var _rails: Array[MeshInstance3D] = []
var _material := StandardMaterial3D.new()
var _streaks: CPUParticles3D
var _streak_material: StandardMaterial3D

func _ready() -> void:
	_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_material.emission_enabled = true
	_material.emission_energy_multiplier = 2.5
	var box := BoxMesh.new() # unit cube - each rail's transform stretches it
	for i in 4:
		var rail := MeshInstance3D.new()
		rail.mesh = box
		rail.material_override = _material
		rail.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		rail.visible = false
		add_child(rail)
		_rails.append(rail)
	_streaks = WarpStreaks.build(STREAK_AMOUNT, STREAK_LIFETIME)
	_streak_material = _streaks.material_override as StandardMaterial3D
	_streaks.emission_ring_inner_radius = 0.0
	_streaks.emission_ring_height = 0.5
	add_child(_streaks)

## `car` is the player, `lead` the traffic car being drafted, `charge` 0..1.
func set_draft(car: Node3D, lead: Node3D, charge: float) -> void:
	_car = car
	_lead = lead
	_charge = charge

func clear_draft() -> void:
	_lead = null
	_charge = 0.0

func _process(delta: float) -> void:
	var on := is_instance_valid(_lead) and is_instance_valid(_car)
	_streaks.emitting = on
	if not on:
		for rail in _rails:
			rail.visible = false
		return
	_time += delta

	var pulse := 1.0
	if _charge >= 1.0:
		pulse = 1.0 - PULSE_DEPTH * (0.5 + 0.5 * sin(_time * PULSE_RATE))
	var col := HudFormat.COL_SMOKE.lerp(HudFormat.COL_CYAN, _charge)
	col.a = lerpf(ALPHA_EMPTY, ALPHA_FULL, _charge) * pulse
	_material.albedo_color = col
	_material.emission = Color(col.r, col.g, col.b)
	_streak_material.albedo_color.a = STREAK_ALPHA * _charge

	# Rail ends: the lead car's tail corners -> the player's nose corners. Both
	# are laid out along the PLAYER's heading (car.gd: forward +Z, left +X) -
	# the two cars are in line, and it avoids depending on how traffic hulls
	# are oriented.
	var fwd: Vector3 = _car.global_basis.z
	fwd.y = 0.0
	if fwd.length_squared() < 0.0001:
		return
	fwd = fwd.normalized()
	var side := Vector3(fwd.z, 0.0, -fwd.x)
	var lead_w: float = float(_lead.get("half_w")) * RAIL_INSET
	var car_w: float = CrashSystem.PLAYER_HALF_W * float(_car.get_meta("hull_w_scale", 1.0)) * RAIL_INSET
	var car_l: float = CrashSystem.PLAYER_HALF_L * float(_car.get_meta("hull_l_scale", 1.0))
	var tail: Vector3 = _lead.global_position - fwd * float(_lead.get("half_len"))
	var nose: Vector3 = _car.global_position + fwd * car_l
	var i := 0
	for height: float in [RAIL_LOW, RAIL_HIGH]:
		for side_sign: float in [-1.0, 1.0]:
			var from: Vector3 = tail + side * (lead_w * side_sign) + Vector3.UP * height
			var to: Vector3 = nose + side * (car_w * side_sign) + Vector3.UP * height
			_place_rail(_rails[i], from, from.lerp(to, _charge))
			i += 1

	# Streaks spawn across the lead car's tail and flow back through the pocket
	# (the emitter shoots along its own -Z, so +Z is aimed down the road).
	_streaks.emission_ring_radius = lead_w
	_streaks.global_transform = Transform3D(Basis(side, Vector3.UP, fwd), tail + Vector3.UP * (RAIL_HIGH * 0.5))

## Stretches a unit cube into a thin bar from `from` to `to`.
func _place_rail(rail: MeshInstance3D, from: Vector3, to: Vector3) -> void:
	var span := to - from
	var length := span.length()
	if length < 0.05:
		rail.visible = false
		return
	var z := span / length
	var x := Vector3.UP.cross(z)
	if x.length_squared() < 0.0001:
		rail.visible = false
		return
	x = x.normalized()
	var y := z.cross(x)
	rail.global_transform = Transform3D(Basis(x * RAIL_THICKNESS, y * RAIL_THICKNESS, z * length), (from + to) * 0.5)
	rail.visible = true
