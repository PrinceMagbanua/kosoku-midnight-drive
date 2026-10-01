class_name SpeedReadout
extends Control

## The big speed number with its "MPH" caption underneath.
##
## Damage warning (MainDial turns it on when the car's health is critical):
## the number softly cross-fades to "DAMAGE CRITICAL" and back, once every
## WARN_PERIOD seconds, so the speed is still readable most of the time. Runs
## on real time, so slow-mo doesn't stretch it.

const WARN_PERIOD := 2.6 # seconds per number -> warning -> number cycle
const WARN_SHARE := 0.45 # share of the cycle the warning is up
const WARN_FADE := 0.35 # seconds for each cross-fade

@onready var _speed: Label = %SpeedLabel
@onready var _warn: Label = %WarnLabel

var _warning := false
var _clock := 0.0
var _mix := 0.0 # 0 = speed number, 1 = warning text

func _ready() -> void:
	_apply_mix()

func set_speed(v: int) -> void:
	_speed.text = str(v)

func set_warning(on: bool) -> void:
	if on and not _warning:
		_clock = 0.0 # a new warning starts by showing itself
	_warning = on

func _process(delta: float) -> void:
	if not _warning and _mix <= 0.0:
		return
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	var show_warning := false
	if _warning:
		_clock += real_delta
		show_warning = fmod(_clock, WARN_PERIOD) < WARN_PERIOD * WARN_SHARE
	_mix = move_toward(_mix, 1.0 if show_warning else 0.0, real_delta / WARN_FADE)
	_apply_mix()

func _apply_mix() -> void:
	var k := smoothstep(0.0, 1.0, _mix)
	_warn.modulate.a = k
	_speed.modulate.a = 1.0 - k
