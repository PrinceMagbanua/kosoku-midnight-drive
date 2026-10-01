@tool
class_name SideArc
extends Control

## Slow-mo tank as a curved bar hugging the speedometer's left side (the spot
## NFS Heat uses for its white health arc). Place the control centred on the
## dial and a little larger than it; only the left `sweep_deg` is drawn,
## filling from the bottom end upward. Smoke white, rose when low.
## Drawn in code like MainDial.

@export_range(0.0, 1.0, 0.001) var value: float = 0.6
@export_range(20.0, 180.0, 1.0) var sweep_deg: float = 110.0
@export var width: float = 6.0
@export var color: Color = Color(0.945, 0.973, 0.988) # HudFormat.COL_SMOKE
@export var low_color: Color = Color(1.0, 0.0, 0.502) # HudFormat.COL_ROSE
## Gradient start (bottom end of the fill); `color` / `low_color` is the top end.
@export var start_color: Color = Color(0.4, 0.62, 0.8)
@export var low_start_color: Color = Color(0.45, 0.0, 0.3)
## Alpha at the bottom end of the fill (the top end is fully opaque).
@export_range(0.0, 1.0, 0.01) var start_alpha: float = 0.55
@export_range(0.0, 1.0, 0.01) var low_below: float = 0.25
@export_range(0.0, 1.0, 0.01) var track_alpha: float = 0.18
@export var smoothing: float = 14.0

const ARC_POINTS := 48

var _shown: float = 0.0

func _ready() -> void:
	_shown = value

func _process(delta: float) -> void:
	var target := clampf(value, 0.0, 1.0)
	if Engine.is_editor_hint():
		_shown = target
	else:
		_shown = lerpf(_shown, target, 1.0 - exp(-smoothing * delta))
		if absf(_shown - target) < 0.0005:
			_shown = target
	queue_redraw()

func _draw() -> void:
	var center := size * 0.5
	var radius := minf(size.x, size.y) * 0.5 - width * 0.5 - 4.0
	var span := deg_to_rad(sweep_deg)
	var start := PI - span * 0.5 # bottom end (screen y points down), filling up
	var low := _shown < low_below
	var col_top := low_color if low else color
	var col_bottom := low_start_color if low else start_color
	draw_polyline(_arc(center, radius, start, span), Color(color, track_alpha), width, true)
	if _shown > 0.002:
		# Gradient runs along the filled part: dim at the bottom, brightest at
		# the top (leading) end; the glow follows it.
		var pts := _arc(center, radius, start, span * _shown)
		var cols := PackedColorArray()
		var glow_outer := PackedColorArray()
		var glow_inner := PackedColorArray()
		for i in pts.size():
			var t := float(i) / float(maxi(pts.size() - 1, 1))
			var col := col_bottom.lerp(col_top, t)
			var a := lerpf(start_alpha, 1.0, t)
			cols.append(Color(col, a))
			glow_outer.append(Color(col, 0.12 * a))
			glow_inner.append(Color(col, 0.22 * a))
		draw_polyline_colors(pts, glow_outer, width + 8.0, true)
		draw_polyline_colors(pts, glow_inner, width + 4.0, true)
		draw_polyline_colors(pts, cols, width, true)

## Points from `start` clockwise-on-screen... i.e. increasing angle, which on
## the left side of the circle runs from bottom to top.
func _arc(center: Vector2, radius: float, start: float, span: float) -> PackedVector2Array:
	var n := maxi(2, int(ceil(ARC_POINTS * span / deg_to_rad(sweep_deg))) + 1)
	var pts := PackedVector2Array()
	for i in n:
		var a := start + span * float(i) / float(n - 1)
		pts.append(center + Vector2(cos(a), sin(a)) * radius)
	return pts
