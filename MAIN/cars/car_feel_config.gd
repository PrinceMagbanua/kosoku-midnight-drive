class_name CarFeelConfig
extends Resource

## Driver-feel values for one car: throttle/brake/handbrake/clutch response
## and steering sensitivity/assistance (the same values the old in-game
## "controls config" debug panel, MISC\debugger.tscn, used to let you
## live-tune - that panel still works for quick testing, but this is now the
## source of truth). Every field's default below IS the base car's authored
## value (from car.gd / base car.tscn), so:
##   - a fresh CarFeelConfig starts identical to the base car,
##   - each field shows a "revert to default" arrow in the inspector once you
##     change it, which snaps that one field back to the base value,
##   - if you ever retune the base car itself, update the matching default
##     here too so they don't silently drift apart.

@export_group("Steering")
@export var steer_sensitivity: float = 1.0
@export var steer_amount_decay: float = 0.015 # understeer help
@export var steering_assistance: float = 0.5
@export var steering_assistance_angular: float = 0.12
@export var keyboard_steer_speed: float = 0.025
@export var keyboard_return_speed: float = 0.05
@export var keyboard_compensate_speed: float = 0.1

@export_group("Throttle")
@export var on_throttle_rate: float = 0.2
@export var off_throttle_rate: float = 0.2
@export var max_throttle: float = 1.0

@export_group("Brake")
@export var on_brake_rate: float = 0.05
@export var off_brake_rate: float = 0.1
@export var max_brake: float = 1.0

@export_group("Handbrake")
@export var on_handbrake_rate: float = 0.2
@export var off_handbrake_rate: float = 0.2
@export var max_handbrake: float = 1.0

@export_group("Clutch")
@export var on_clutch_rate: float = 0.2
@export var off_clutch_rate: float = 0.2
@export var max_clutch: float = 1.0

@export_group("Gearbox")
## 0 = manual, 1 = semi-manual, 2 = auto (GearAssistant[1] on car.gd).
@export_range(0, 2) var gear_assist: int = 2

## field name -> matching car.gd @export name, for apply_to().
const PROP_MAP := {
	"steer_sensitivity": "SteerSensitivity",
	"steer_amount_decay": "SteerAmountDecay",
	"steering_assistance": "SteeringAssistance",
	"steering_assistance_angular": "SteeringAssistanceAngular",
	"keyboard_steer_speed": "KeyboardSteerSpeed",
	"keyboard_return_speed": "KeyboardReturnSpeed",
	"keyboard_compensate_speed": "KeyboardCompensateSpeed",
	"on_throttle_rate": "OnThrottleRate",
	"off_throttle_rate": "OffThrottleRate",
	"max_throttle": "MaxThrottle",
	"on_brake_rate": "OnBrakeRate",
	"off_brake_rate": "OffBrakeRate",
	"max_brake": "MaxBrake",
	"on_handbrake_rate": "OnHandbrakeRate",
	"off_handbrake_rate": "OffHandbrakeRate",
	"max_handbrake": "MaxHandbrake",
	"on_clutch_rate": "OnClutchRate",
	"off_clutch_rate": "OffClutchRate",
	"max_clutch": "MaxClutch",
}

## Writes every field onto the live car node (car.gd exports + GearAssistant).
func apply_to(car: Node3D) -> void:
	for field in PROP_MAP:
		car.set(PROP_MAP[field], get(field))
	car.GearAssistant[1] = gear_assist
