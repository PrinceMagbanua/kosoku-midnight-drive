@tool
class_name StatBar
extends Control

## Thin glowing stat bar for the garage: the car's own value in `base_color`,
## with what purchased upgrades add drawn after it in `bonus_color`. Same
## glow style as GlowBar - it reuses GlowBar's line/track/glow constants so
## the two stay in sync. Values are 0..1 (stat / 10). In the
## game the fills ease toward new values when the car changes.

@export_range(0.0, 1.0, 0.001) var base_value: float = 0.5:
	set(v):
		base_value = v
		if Engine.is_editor_hint():
			_shown_base = v
		queue_redraw()
@export_range(0.0, 1.0, 0.001) var bonus_value: float = 0.0:
	set(v):
		bonus_value = v
		if Engine.is_editor_hint():
			_shown_bonus = v
		queue_redraw()
@export var base_color: Color = Color(0.9098, 0.6392, 0.2392)
@export var bonus_color: Color = Color(0.3725, 0.8157, 0.7882)
@export var smoothing: float = 10.0

var _shown_base: float = 0.0
var _shown_bonus: float = 0.0

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		return
	var k := 1.0 - exp(-smoothing * delta)
	var nb := lerpf(_shown_base, base_value, k)
	var nx := lerpf(_shown_bonus, bonus_value, k)
	if absf(nb - _shown_base) > 0.0002 or absf(nx - _shown_bonus) > 0.0002:
		_shown_base = nb
		_shown_bonus = nx
		queue_redraw()

func _draw() -> void:
	var cy := size.y * 0.5
	draw_rect(Rect2(0.0, cy - GlowBar.LINE_HEIGHT * 0.5, size.x, GlowBar.LINE_HEIGHT), GlowBar.TRACK_COLOR)
	var wb := size.x * clampf(_shown_base, 0.0, 1.0)
	var wx := size.x * clampf(_shown_bonus, 0.0, 1.0 - clampf(_shown_base, 0.0, 1.0))
	_segment(0.0, wb, base_color, cy)
	_segment(wb, wx, bonus_color, cy)

func _segment(x: float, w: float, color: Color, cy: float) -> void:
	if w <= 0.0:
		return
	for layer in GlowBar.GLOW_LAYERS:
		var h: float = GlowBar.LINE_HEIGHT + layer[0]
		draw_rect(Rect2(x, cy - h * 0.5, w, h), Color(color, layer[1]))
	draw_rect(Rect2(x, cy - GlowBar.LINE_HEIGHT * 0.5, w, GlowBar.LINE_HEIGHT), color)
