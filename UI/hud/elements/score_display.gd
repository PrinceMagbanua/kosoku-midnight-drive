class_name ScoreDisplay
extends Control

## "SCORE" caption + the big score number. The number can count up toward a
## new total (used when the combo pile is banked); otherwise it just follows
## whatever `sync_to` is given.

@onready var _value: Label = %ValueLabel

var _shown: float = 0.0
var _tween: Tween

## Follow the real score - ignored while a count-up is running.
func sync_to(v: float) -> void:
	if not is_animating():
		_set_shown(v)

func is_animating() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()

func shown_value() -> float:
	return _shown

## Counts from `from` to `to` after `delay` seconds. Ignores Engine.time_scale
## so it stays in real time under slow-mo / Time Stop.
func count_up(from: float, to: float, delay: float, duration: float) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween().set_ignore_time_scale(true)
	_tween.tween_interval(delay)
	_tween.tween_method(_set_shown, from, to, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func reset() -> void:
	if _tween:
		_tween.kill()
	_set_shown(0.0)

## Where the number is on screen - the pile popup slides toward this.
func value_global_position() -> Vector2:
	return _value.global_position

func _set_shown(v: float) -> void:
	_shown = v
	_value.text = HudFormat.commas(int(round(v)))
