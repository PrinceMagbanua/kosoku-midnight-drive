@tool
class_name GearBadge
extends Control

## Gear letter/number in a chamfered-corner badge (bottom-right corner cut) -
## the mockup's `clip-path: polygon(...)` badge, drawn as a polygon.

@export var text: String = "N":
	set(t):
		if t != text:
			text = t
			queue_redraw()
@export var font: Font
@export var font_size: int = 16
@export var accent: Color = Color(0.0, 1.0, 1.0) # HudFormat.COL_CYAN
@export var fill: Color = Color(0.043, 0.059, 0.086)
## Fraction of the width/height removed by the bottom-right cut.
@export_range(0.0, 0.6, 0.01) var chamfer: float = 0.35

func _draw() -> void:
	var w := size.x
	var h := size.y
	var poly := PackedVector2Array([
		Vector2(0, 0), Vector2(w, 0), Vector2(w, h * (1.0 - chamfer)),
		Vector2(w * (1.0 - chamfer), h), Vector2(0, h),
	])
	draw_colored_polygon(poly, fill)
	# 2px border, inset by 1 so it stays inside the control rect.
	var b := PackedVector2Array([
		Vector2(1, 1), Vector2(w - 1, 1), Vector2(w - 1, h * (1.0 - chamfer)),
		Vector2(w * (1.0 - chamfer), h - 1), Vector2(1, h - 1), Vector2(1, 1),
	])
	draw_polyline(b, accent, 2.0, true)

	var f: Font = font if font else get_theme_default_font()
	var text_h := f.get_ascent(font_size) + f.get_descent(font_size)
	var baseline := (h - text_h) * 0.5 + f.get_ascent(font_size)
	draw_string(f, Vector2(0.0, baseline), text, HORIZONTAL_ALIGNMENT_CENTER, w, font_size, accent)
