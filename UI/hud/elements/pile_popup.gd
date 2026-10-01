class_name PilePopup
extends Control

## The combo-pile popup: running pile total + what just scored. Place this
## node wherever you like in LiveHud.tscn - it doesn't follow anything. It is
## visible in the editor so you can position it; at runtime it starts hidden.
## It flares in at full (HudFlare) and settles to the HUD's resting opacity.
## Tweens ignore Engine.time_scale.

const POP_SCALE := 1.18
const SLIDE_TIME := 0.5

@onready var _value: Label = %PileValue
@onready var _reason: Label = %PileReason

var _tween: Tween

func _ready() -> void:
	modulate.a = 0.0

func show_pile(total: int, added: int, mult: float, reason: String) -> void:
	_kill_tween()
	HudFlare.flare(self)
	_value.text = "+" + HudFormat.commas(total)
	_value.add_theme_color_override("font_color", HudFormat.combo_color(mult))
	if added > 0:
		_reason.text = "%s  +%d  ×%s" % [reason, added, HudFormat.mult_text(mult)]
		scale = Vector2.ONE * POP_SCALE
		_tween = create_tween().set_ignore_time_scale(true)
		_tween.tween_property(self, "scale", Vector2.ONE, 0.15).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_reason.text = reason

## Crash: the pile is gone.
func show_lost() -> void:
	_kill_tween()
	HudFlare.stop(self)
	modulate = Color.WHITE
	_value.add_theme_color_override("font_color", HudFormat.COL_DANGER)
	_reason.text = "PILE LOST"
	_tween = create_tween().set_ignore_time_scale(true)
	_tween.tween_interval(0.5)
	_tween.tween_property(self, "modulate:a", 0.0, 0.5)

func hide_now() -> void:
	_kill_tween()
	HudFlare.stop(self)
	modulate = Color(1, 1, 1, 0)
	scale = Vector2.ONE

## Banked: a throwaway copy flies to `target_top_left` (global) shrinking and
## fading, and this popup hides immediately so it is free for the next pile.
func slide_to(target_top_left: Vector2) -> void:
	var ghost := duplicate() as Control
	ghost.set_script(null) # a plain visual copy - no _ready/@onready of its own
	ghost.unique_name_in_owner = false
	for c in ghost.get_children():
		c.unique_name_in_owner = false
	get_parent().add_child(ghost)
	ghost.global_position = global_position
	var tw := ghost.create_tween().set_ignore_time_scale(true).set_parallel(true)
	tw.tween_property(ghost, "global_position", target_top_left, SLIDE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(ghost, "scale", Vector2.ONE * 0.45, SLIDE_TIME).set_ease(Tween.EASE_IN)
	tw.tween_property(ghost, "modulate:a", 0.0, 0.15).set_delay(SLIDE_TIME - 0.15)
	tw.chain().tween_callback(ghost.queue_free)
	hide_now()

func _kill_tween() -> void:
	if _tween:
		_tween.kill()
