extends Node

## The preview car (`base car.tscn`) needs its real raycast suspension
## (wheel.gd, one script per fr/fl/rr/rl corner) to briefly run so it
## settles into a correct resting pose instead of being permanently stuck at
## the unloaded position - same root cause as the main car's floating-body
## bug, just never settling at all since its physics never runs.
##
## Real bug found and fixed here: this used to set the WHOLE car's
## process_mode to ALWAYS + freeze=false to let it settle - but that also
## re-enabled car.gd's own script (the top-level RigidBody3D script, which
## reads player input/drivetrain state every frame), meaning during the
## settle window the preview car would actually DRIVE if the player pressed
## gas/steer, since car.gd doesn't know or care that it's a decorative menu
## background. Fixed via CarInputLock (car_input_lock.gd) - car.gd's script
## never runs, so it can never read input, while each wheel corner's own
## suspension script keeps running independently. After settling, both go
## back to fully DISABLED (not just INHERIT) so nothing keeps simulating
## once the pose is set - this node calls disable_input() again at that
## point since CarInputLock's own enable_input() restores INHERIT, not
## DISABLED, and this preview car specifically wants to stay fully off.

@export var preview_car_path: NodePath = NodePath("../PreviewCar")
const SETTLE_TIME := 1.5

## Slow constant turntable spin applied AFTER settling - replaces an
## orbiting camera (the camera now sits still; the car rotates in place
## around its own pivot instead, matching the reference three.js garage's
## look).
const SPIN_SPEED := 0.35 # rad/s

## Customize screen: the turntable stops and the car eases back to facing
## its authored heading (yaw 0), so the fixed customize camera viewpoints in
## GaragePreview.tscn (cust_front/rear/side/top) always frame the same part.
const PARK_RATE := 4.0

var _elapsed := 0.0
var _settled := false
var _turntable := true

func set_turntable(enabled: bool) -> void:
	_turntable = enabled

func _ready() -> void:
	var car: RigidBody3D = get_node(preview_car_path)
	car.freeze = false
	CarInputLock.disable_input(car)

## Lets the suspension settle again after the preview car's hull/wheels were
## swapped (CarProfileApplier calls this on a garage car change).
func resettle() -> void:
	var car: RigidBody3D = get_node(preview_car_path)
	_elapsed = 0.0
	_settled = false
	car.freeze = false
	CarInputLock.disable_input(car)

func _physics_process(delta: float) -> void:
	var car: RigidBody3D = get_node(preview_car_path)
	if not _settled:
		_elapsed += delta
		if _elapsed >= SETTLE_TIME:
			car.linear_velocity = Vector3.ZERO
			car.angular_velocity = Vector3.ZERO
			car.freeze = true
			for corner in CarInputLock.WHEEL_CORNERS:
				var w: Node = car.get_node_or_null(corner)
				if w:
					w.process_mode = Node.PROCESS_MODE_DISABLED
			_settled = true
		return
	if _turntable:
		car.rotate_y(SPIN_SPEED * delta)
	else:
		car.rotation.y = lerp_angle(car.rotation.y, 0.0, clampf(delta * PARK_RATE, 0.0, 1.0))
