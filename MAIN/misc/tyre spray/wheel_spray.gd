extends Node3D

## Rain spray/mist off a wheel - sibling to tyre_smoke.gd's smoke/smoke_dirt
## instances under wheel.tscn's animation/camber (same attachment point, same
## per-wheel-instance-via-wheel.tscn setup). Unlike tyre_smoke.gd, this is
## NOT gated on slip - real tire spray happens just from rolling through
## standing water at speed, so it's driven purely by Weather.rain_intensity
## and forward speed.
##
## Perf: only the non-steering (rear) wheels spray - front spray is hidden
## behind the rear's anyway, and every transparent quad is overdraw cost.

@onready var velo1 = get_node("../../../velocity")
@onready var wheel_self = get_node("../../..")
@onready var _emitters: Array = [$static/lvl1, $static/lvl2, $static/lvl3]

const MIN_SPEED_LVL1 := 6.0
const MIN_SPEED_LVL2 := 16.0
const MIN_SPEED_LVL3 := 28.0

func _ready() -> void:
	if wheel_self.Steer:
		visible = false
		set_physics_process(false)

func _physics_process(_delta: float) -> void:
	var raining: bool = Weather.rain_intensity > 0.02 and not Weather.sheltered
	visible = VitaVehicleSimulation.misc_smoke and raining

	var velo1_v: Vector3 = wheel_self.velocity
	var speed := velo1_v.length()

	# Higher rain intensity lowers the speed needed to see spray at each
	# level - light drizzle only shows spray at higher speed, a downpour
	# shows it almost immediately once rolling.
	var on_ground: bool = visible and wheel_self.is_colliding()
	var falloff := 2.0 - Weather.rain_intensity
	var wanted := [
		on_ground and speed > MIN_SPEED_LVL1 * falloff,
		on_ground and speed > MIN_SPEED_LVL2 * falloff,
		on_ground and speed > MIN_SPEED_LVL3 * falloff,
	]

	if on_ground:
		$static.global_rotation = velo1.global_rotation
	var direction := velo1_v * 0.85
	var dir_len := direction.length()
	for idx in _emitters.size():
		var p: CPUParticles3D = _emitters[idx]
		if wanted[idx]:
			p.direction = direction
			p.initial_velocity_min = dir_len
			p.initial_velocity_max = dir_len
			p.position.y = -wheel_self.w_size
		if p.emitting != wanted[idx]:
			p.emitting = wanted[idx]
