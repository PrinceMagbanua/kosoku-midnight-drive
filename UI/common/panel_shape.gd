@tool
extends MarginContainer
class_name PanelShape

## Reusable background for the mockup's recurring "corner-cut panel" shape
## (see kosoku-ui-mockup.html's `.cut`/`.cut-sm` clip-path utility) plus its
## vertical gradient fills (`.nav-col`, `.garage-panel`, etc.) - neither is
## expressible with a plain StyleBoxFlat (no chamfered-corner support, no
## gradient fill), so this draws both itself with corner_size = 0 collapsing
## to a plain flat/gradient rect. Content margins double as the panel's
## padding, same as a themed PanelContainer.

@export var corner_size: float = 0.0:
	set(v):
		corner_size = v
		queue_redraw()
@export var top_color: Color = Color(0.0706, 0.0863, 0.1216):
	set(v):
		top_color = v
		queue_redraw()
@export var bottom_color: Color = Color(0.0706, 0.0863, 0.1216):
	set(v):
		bottom_color = v
		queue_redraw()
@export var border_color: Color = Color(0, 0, 0, 0):
	set(v):
		border_color = v
		queue_redraw()
@export var border_width: float = 1.0:
	set(v):
		border_width = v
		queue_redraw()
@export var border_left: bool = false:
	set(v):
		border_left = v
		queue_redraw()
@export var border_top: bool = false:
	set(v):
		border_top = v
		queue_redraw()
@export var border_right: bool = false:
	set(v):
		border_right = v
		queue_redraw()
@export var border_bottom: bool = false:
	set(v):
		border_bottom = v
		queue_redraw()

func _ready() -> void:
	resized.connect(queue_redraw)

func _draw() -> void:
	var w: float = size.x
	var h: float = size.y
	if w <= 0.0 or h <= 0.0:
		return
	var c: float = clampf(corner_size, 0.0, minf(w, h) * 0.5)
	var points := PackedVector2Array([
		Vector2(0, 0), Vector2(w - c, 0), Vector2(w, c),
		Vector2(w, h), Vector2(c, h), Vector2(0, h - c),
	])
	var colors := PackedColorArray()
	for p in points:
		colors.append(top_color.lerp(bottom_color, clampf(p.y / h, 0.0, 1.0)))
	draw_polygon(points, colors)
	if border_color.a > 0.0 and border_width > 0.0:
		if border_left:
			draw_line(points[5], points[0], border_color, border_width)
		if border_top:
			draw_line(points[0], points[1], border_color, border_width)
		if border_right:
			draw_line(points[2], points[3], border_color, border_width)
		if border_bottom:
			draw_line(points[3], points[4], border_color, border_width)
