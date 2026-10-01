extends "res://UI/common/button_motion.gd"

## Icon-only "undo" (sell back one tier) button for the upgrade rows. No
## font glyph to lean on (same as icon_button.gd's gear), so this draws a
## small counter-clockwise arrow itself. Colour follows the theme's
## font_color / font_hover_color, keeps button_motion.gd's hover/press feel.

const RADIUS := 5.0
const WIDTH := 1.6
const HEAD := 3.0

func _draw() -> void:
	var col := get_theme_color("font_hover_color" if is_hovered() else "font_color")
	var c := size * 0.5
	# Arc from the left, over the top, round to the lower right; the arrow
	# head sits on the left end pointing down (i.e. turning back = undo).
	draw_arc(c, RADIUS, PI, TAU + PI * 0.35, 20, col, WIDTH, true)
	var tip := c + Vector2(-RADIUS, 0) + Vector2(0, HEAD)
	var base := c + Vector2(-RADIUS, 0) - Vector2(0, HEAD * 0.4)
	draw_colored_polygon(PackedVector2Array([
		tip, base + Vector2(-HEAD, 0), base + Vector2(HEAD, 0),
	]), col)
