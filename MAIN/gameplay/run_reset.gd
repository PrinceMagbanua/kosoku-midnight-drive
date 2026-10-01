extends Node

## Fixes "Play Endless just continues from the crash point" - nothing
## previously reset the player car's actual position/velocity, the road
## chunks, or the traffic pool when starting a fresh run from the garage,
## even though RunRewards (score/distance) already correctly resets itself
## on the same trigger (it tracks distance relative to wherever the car
## WAS when the run started, so it looked fine on its own, but the world
## itself just kept going from wherever the crash happened).
##
## Same trigger condition RunRewards/CrashSystem already use for "a fresh
## run is starting, not resuming from pause": `new_state == PLAYING and
## old_state != PAUSED`. Runs AFTER those two (Node order in world.tscn),
## so the car's global_position they read on this same signal is unaffected
## either way (they don't depend on where the car physically is).

@export var car_path: NodePath = NodePath("../car")
@export var road_generator_path: NodePath = NodePath("../RoadGenerator")
@export var traffic_manager_path: NodePath = NodePath("../TrafficManager")

## Where the car sits in world.tscn - only the fallback now. A run starts
## parked in the road's lay-by (RoadGenerator.spawn_transform), on whatever
## path that run generated; `_spawn_height` is how far the car's origin rides
## above the road, measured from the scene's own placement.
var _spawn_transform: Transform3D
var _spawn_height := 2.0

func _ready() -> void:
	var car: RigidBody3D = get_node_or_null(car_path)
	if car:
		_spawn_transform = car.global_transform
		var rg: Node = get_node_or_null(road_generator_path)
		if rg and rg.path:
			var d: float = PathTracker.new(rg.path).update(car.global_position)
			_spawn_height = car.global_position.y - rg.path.world_pos(d, 0.0).y
	GameState.state_changed.connect(_on_state_changed)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state != GameState.State.PLAYING or old_state == GameState.State.PAUSED:
		return
	_reset_run()

func _reset_run() -> void:
	var car: RigidBody3D = get_node_or_null(car_path)
	if car == null:
		return
	# The new run's road first (a fresh path every run), so the car can be
	# parked in ITS lay-by. Then the car's own position/velocity -
	# RoadGenerator/TrafficManager's reset functions both read the car's
	# CURRENT position to decide what to rebuild around, so that has to
	# happen before either of them.
	var rg: Node = get_node_or_null(road_generator_path)
	var spawn := _spawn_transform
	if rg and rg.has_method("prepare_run"):
		rg.prepare_run()
		spawn = rg.spawn_transform(_spawn_height)
	car.global_transform = spawn
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	# Freeze the body through the start intro too, not just this one instant -
	# repositioning alone still leaves gravity free to pull it straight back
	# off the map for the ~4s cinematic that follows (input is locked to
	# rev-only then, but the RigidBody3D itself wasn't). IntroPan (same
	# state_changed trigger, always runs alongside this) lifts the freeze the
	# moment the cinematic ends.
	car.freeze = true
	if car.has_method("reset_state"):
		car.reset_state()
	for wheel_name in ["fl", "fr", "rl", "rr"]:
		var wheel: Node = car.get_node_or_null(NodePath(wheel_name))
		if wheel and wheel.has_method("reset_state"):
			wheel.reset_state()
	var nitro: Node = car.get_node_or_null(NodePath("NitroBoost"))
	if nitro and nitro.has_method("reset_state"):
		nitro.reset_state()
	var slowmo: Node = car.get_node_or_null(NodePath("SlowMo"))
	if slowmo and slowmo.has_method("reset_state"):
		slowmo.reset_state()
	var burst: Node = car.get_node_or_null(NodePath("BoostBurst"))
	if burst and burst.has_method("reset_state"):
		burst.reset_state()

	if rg and rg.has_method("reset_chunks"):
		rg.reset_chunks()

	var tm: Node = get_node_or_null(traffic_manager_path)
	if tm and tm.has_method("reset_traffic"):
		tm.reset_traffic()

	# The run's 0 km is where the car now sits. RunRewards hears the same state
	# change first (it's an autoload), while the road tracker still holds the
	# LAST run's position - so its own start mark is stale until this.
	RunRewards.mark_run_start()
