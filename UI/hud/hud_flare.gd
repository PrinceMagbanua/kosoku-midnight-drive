class_name HudFlare
extends RefCounted

## HUD attention levels. Every element rests at REST opacity and only
## "flares" (full opacity, a touch overbright) when something happens to it,
## then eases back - so the HUD stays quiet over the road and the thing that
## just changed is the thing you notice. hold() keeps an element at full for
## as long as it's in use (nitro firing, a crash). Tweens ignore time scale.

const REST := 0.7
const OVERBRIGHT := 1.3
const HOLD_TIME := 0.25
const FADE_TIME := 0.9
const RISE_TIME := 0.08

const _TWEEN_META := &"hud_flare_tween"
const _HOLD_META := &"hud_flare_hold"

## Stops any flare/hold tween so the caller can animate modulate itself.
static func stop(ci: CanvasItem) -> void:
	_kill(ci)
	ci.set_meta(_HOLD_META, false)

static func rest(ci: CanvasItem) -> void:
	_kill(ci)
	ci.set_meta(_HOLD_META, false)
	ci.modulate = Color(1, 1, 1, REST)

static func flare(ci: CanvasItem) -> void:
	_kill(ci)
	ci.modulate = Color(OVERBRIGHT, OVERBRIGHT, OVERBRIGHT, 1.0)
	var target := _held_color() if ci.get_meta(_HOLD_META, false) else _rest_color()
	var tw := ci.create_tween().set_ignore_time_scale(true)
	tw.tween_interval(HOLD_TIME)
	tw.tween_property(ci, "modulate", target, FADE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	ci.set_meta(_TWEEN_META, tw)

## Keep at full while `on`; eases back to REST when released. Cheap to call
## every frame - it only acts when the state changes.
static func hold(ci: CanvasItem, on: bool) -> void:
	if ci.get_meta(_HOLD_META, false) == on:
		return
	ci.set_meta(_HOLD_META, on)
	_kill(ci)
	var tw := ci.create_tween().set_ignore_time_scale(true)
	tw.tween_property(ci, "modulate", _held_color() if on else _rest_color(), RISE_TIME if on else FADE_TIME)
	ci.set_meta(_TWEEN_META, tw)

static func _rest_color() -> Color:
	return Color(1, 1, 1, REST)

static func _held_color() -> Color:
	return Color(1, 1, 1, 1)

static func _kill(ci: CanvasItem) -> void:
	var tw: Tween = ci.get_meta(_TWEEN_META, null)
	if tw and tw.is_valid():
		tw.kill()
