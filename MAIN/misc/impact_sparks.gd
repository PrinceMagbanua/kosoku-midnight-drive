extends CPUParticles3D

## One-shot spark/debris burst - instantiated fresh at the impact point by
## crash_system.gd, plays once, then frees itself (via the `finished` signal
## CPUParticles3D emits once every particle from a `one_shot` burst has
## completed its lifetime) rather than lingering as a dead node in the tree.
##
## `carry_velocity`: set by the spawner to (a fraction of) the car's velocity
## so the burst travels along with the car at first, instead of being left
## behind the instant it spawns at high speed. The emitter node itself moves
## with it and particles use local coords, so they ride along; it decays by
## `carry_damping` per second so the burst gradually falls behind the car.
var carry_velocity := Vector3.ZERO
var carry_damping := 2.5

func _ready() -> void:
	local_coords = true
	finished.connect(queue_free)
	restart()

func _physics_process(delta: float) -> void:
	if carry_velocity == Vector3.ZERO:
		return
	global_position += carry_velocity * delta
	carry_velocity *= exp(-carry_damping * delta)
