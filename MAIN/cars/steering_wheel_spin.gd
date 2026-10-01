@tool
extends Node3D

## Spins the cabin steering wheel with the car's steering. Sits on the
## "SteeringPivot" node ModularCarBuilder puts at the wheel's hub, whose local
## +Z is the steering column (pointing forward, away from the driver) - so a
## positive angle about it turns the rim clockwise as the driver sees it.
##
## Same mapping as the debug HUD's steering wheel graphic (debug.gd):
## car.steer (-1 full left .. +1 full right) * 380 degrees.
##
## @tool so it also turns in a car's interior scene preview, where the
## interior root (car_interior.gd) stands in for the car with its own `steer`.

const DEGREES_AT_FULL_LOCK := 380.0

var _car: Node
var _rest: Basis

func _ready() -> void:
	_rest = basis
	# The hull is built before it joins the car, so find the car lazily.
	_car = _find_car()

func _process(_delta: float) -> void:
	if _car == null or not is_instance_valid(_car):
		_car = _find_car()
		if _car == null:
			return
	var angle := deg_to_rad(float(_car.get("steer")) * DEGREES_AT_FULL_LOCK)
	basis = _rest * Basis(Vector3.BACK, angle)

func _find_car() -> Node:
	var n := get_parent()
	while n != null:
		if "steer" in n:
			return n
		n = n.get_parent()
	return null
