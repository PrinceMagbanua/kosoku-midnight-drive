@tool
class_name IconButton
extends Button

## Circular outline button. `?` is just the button's text; the gear has no
## font glyph to lean on, so GEAR draws a small toothed outline instead.
## Colour follows the theme's font_color / font_hover_color overrides.

enum Glyph { NONE, GEAR }

@export var glyph: Glyph = Glyph.NONE:
	set(g):
		glyph = g
		queue_redraw()

func _draw() -> void:
	if glyph != Glyph.GEAR:
		return
	var col := get_theme_color("font_hover_color" if is_hovered() else "font_color")
	var c := size * 0.5
	var pts := PackedVector2Array()
	const TEETH := 8
	for i in TEETH:
		var a := TAU * float(i) / float(TEETH)
		for step in [[-0.30, 6.0], [-0.17, 8.2], [0.17, 8.2], [0.30, 6.0]]:
			var ang: float = a + step[0]
			pts.append(c + Vector2(cos(ang), sin(ang)) * float(step[1]))
	pts.append(pts[0])
	draw_polyline(pts, col, 1.4, true)
	draw_arc(c, 2.8, 0.0, TAU, 20, col, 1.4, true)
