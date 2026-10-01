class_name AlertStack
extends VBoxContainer

## ABS / TCS / ESP text indicators - each fades in when its system is
## intervening and out when it stops. Visible in the editor so it can be
## positioned; hidden at runtime until something fires.

const FADE_IN := 0.06 # seconds
const FADE_OUT := 0.25

@onready var _abs: Label = %AbsLabel
@onready var _tcs: Label = %TcsLabel
@onready var _esp: Label = %EspLabel

func _ready() -> void:
	for l in [_abs, _tcs, _esp]:
		l.modulate.a = 0.0

func update_alerts(abs_on: bool, tcs_on: bool, esp_on: bool, delta: float) -> void:
	_fade(_abs, abs_on, delta)
	_fade(_tcs, tcs_on, delta)
	_fade(_esp, esp_on, delta)

func _fade(label: Label, on: bool, delta: float) -> void:
	var rate := FADE_IN if on else FADE_OUT
	label.modulate.a = move_toward(label.modulate.a, 1.0 if on else 0.0, delta / rate)
