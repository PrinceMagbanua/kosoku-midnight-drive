@tool
class_name GlowBar
extends Control

## Thin glowing progress line (was the HUD's pedal rows / HP meter, now only
## the garage's StatBar reuses its constants). Tweak LINE_HEIGHT /
## GLOW_LAYERS here and StatBar follows.
## The glow is layered translucent strokes under the line (a true blur would
## need a backbuffer shader; this reads the same at 2px).
##
## The control should be taller than LINE_HEIGHT so the glow has room; the
## line is centred vertically.

@export_range(0.0, 1.0, 0.001) var value: float = 0.0:
	set(v):
		v = clampf(v, 0.0, 1.0)
		if v != value:
			value = v
			queue_redraw()
@export var color: Color = Color.WHITE:
	set(c):
		if c != color:
			color = c
			queue_redraw()

const LINE_HEIGHT := 2.0
const TRACK_COLOR := Color(1.0, 1.0, 1.0, 0.08)
## [extra height, alpha] per glow layer, widest first.
const GLOW_LAYERS := [[7.0, 0.10], [4.0, 0.18]]

func _draw() -> void:
	var cy := size.y * 0.5
	draw_rect(Rect2(0.0, cy - LINE_HEIGHT * 0.5, size.x, LINE_HEIGHT), TRACK_COLOR)
	var w := size.x * value
	if w <= 0.0:
		return
	for layer in GLOW_LAYERS:
		var h: float = LINE_HEIGHT + layer[0]
		draw_rect(Rect2(0.0, cy - h * 0.5, w, h), Color(color, layer[1]))
	draw_rect(Rect2(0.0, cy - LINE_HEIGHT * 0.5, w, LINE_HEIGHT), color)
