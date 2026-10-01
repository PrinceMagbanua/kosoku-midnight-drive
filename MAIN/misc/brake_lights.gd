extends Node3D

## Finds the actual rearlight_L/rearlight_R meshes inside whichever hull is
## assigned (VoxelCarMesh) and gives each an emissive material - same
## "use the model's own named parts" approach as headlight_lights.gd, via
## StructuredCarParts (structured_car_parts.gd). Each rear light also gets
## a wide, shadowless SpotLight3D aimed backward so it casts a red glow onto
## the road behind the car. A spot rather than an omni: an omni lit the
## underbody and rear wheels too, which a real tail lamp can't reach.
##
## Reactive: dim baseline (always-on taillight, like a real car) that
## brightens when the car's own `brakepedal` is actually pressed - reads
## the value straight off the parent car node each frame rather than a
## separate tracked flag, so it can't drift from the real pedal state.

@export var hull_path: NodePath = NodePath("../VoxelCarMesh")

const DIM_ENERGY := 1.2
const BRAKE_ENERGY := 3.5
const BRAKE_THRESHOLD := 0.1

# Real SpotLight3D cast onto the surroundings (separate from the mesh's own
# emission energy above). Short range keeps it cheap in gl_compatibility's
# per-mesh light budget, like HeadlightSpec's traffic tier.
const LIGHT_DIM_ENERGY := 0.6
const LIGHT_BRAKE_ENERGY := 2.5
const LIGHT_RANGE := 8.0
const LIGHT_SPOT_ANGLE := 65.0 # half-angle from centre to edge, so ~130 deg wide
const LIGHT_DOWNWARD_TILT_DEG := -70.0 # same sign convention as headlight_lights.gd

# Braking was going white, not brighter red - a high enough emission energy
# multiplier saturates all 3 channels past 1.0 after tonemapping, and a
# fully-saturated color reads as white regardless of its original hue. The
# real fix isn't a bigger multiplier, it's a genuinely lighter red (mixed
# toward white by a modest amount, not blasted with energy) alongside a
# much more modest energy bump.
const DIM_COLOR := StructuredCarParts.REARLIGHT_COLOR
const BRAKE_COLOR := Color(1.0, 0.42, 0.42) # REARLIGHT_COLOR lightened, still clearly red

var _car: Node
var _lights: Array[MeshInstance3D] = []
var _spots: Array[SpotLight3D] = []
## "L"/"R" -> {"light": SpotLight3D, "mesh": the lens MeshInstance3D}.
var _by_side := {}

## Re-binds to the (possibly swapped) hull's rear lights. The SpotLights live
## under this node, not the hull, so the old ones are freed here explicitly.
func rebuild() -> void:
	_ready()

func _ready() -> void:
	_lights.clear()
	for old in _spots:
		if is_instance_valid(old):
			old.queue_free()
	_spots.clear()
	_by_side.clear()
	_car = get_parent()
	var hull: Node3D = get_node_or_null(hull_path)
	if hull == null:
		return
	_attach(StructuredCarParts.find_part(hull, ["rearlight_l"]), "L")
	_attach(StructuredCarParts.find_part(hull, ["rearlight_r"]), "R")

func _attach(mesh_node: Node3D, side: String) -> void:
	if mesh_node == null or not (mesh_node is MeshInstance3D) or (mesh_node as MeshInstance3D).mesh == null:
		return
	var mesh_instance := mesh_node as MeshInstance3D
	var mat := StandardMaterial3D.new()
	mat.emission_enabled = true
	mat.emission = DIM_COLOR
	mat.emission_energy_multiplier = DIM_ENERGY
	mat.albedo_color = DIM_COLOR
	mesh_instance.material_override = mat
	_lights.append(mesh_instance)

	var light := SpotLight3D.new()
	light.light_color = DIM_COLOR
	light.light_energy = LIGHT_DIM_ENERGY
	light.spot_range = LIGHT_RANGE
	light.spot_angle = LIGHT_SPOT_ANGLE
	light.spot_angle_attenuation = 1.5
	light.shadow_enabled = false
	# Same placement as headlight_lights.gd: centre of the lens geometry (the
	# mesh origin isn't where the lens is), parented to THIS node rather than
	# the mesh so the cockpit camera hiding the hull doesn't switch it off.
	var local_aabb: AABB = mesh_instance.mesh.get_aabb()
	# A SpotLight3D shines along its local -Z, which is already the car's rear
	# (headlight_lights.gd needs a PI yaw to face +Z forward) - so only the
	# downward pitch is needed here.
	var aim := Basis(Vector3(1, 0, 0), deg_to_rad(LIGHT_DOWNWARD_TILT_DEG))
	var in_mesh := Transform3D(aim, local_aabb.position + local_aabb.size / 2.0)
	add_child(light)
	light.transform = global_transform.affine_inverse() * mesh_instance.global_transform * in_mesh
	_spots.append(light)
	_by_side[side] = {"light": light, "mesh": mesh_instance}

## Damage (CarPartDetacher) - same API as headlight_lights.gd.
func break_side(side: String) -> bool:
	return LightBreak.break_side(_by_side, side)

func lens_center(side: String) -> Vector3:
	return LightBreak.lens_center(_by_side, side)

func lens_mesh(side: String) -> MeshInstance3D:
	return _by_side[side].mesh if _by_side.has(side) else null

func restore() -> void:
	LightBreak.restore(_by_side)

func _process(_delta: float) -> void:
	if _lights.is_empty() or _car == null:
		return
	# Space is bound to "handbrake" (handbrakepull), not "brake" - both light up.
	var braking: bool = ("brakepedal" in _car and _car.brakepedal > BRAKE_THRESHOLD) \
		or ("handbrakepull" in _car and _car.handbrakepull > BRAKE_THRESHOLD)
	var color: Color = BRAKE_COLOR if braking else DIM_COLOR
	var energy: float = BRAKE_ENERGY if braking else DIM_ENERGY
	for l in _lights:
		if is_instance_valid(l) and l.material_override:
			l.material_override.emission = color
			l.material_override.emission_energy_multiplier = energy
	var light_energy: float = LIGHT_BRAKE_ENERGY if braking else LIGHT_DIM_ENERGY
	for o in _spots:
		if is_instance_valid(o):
			o.light_energy = light_energy
