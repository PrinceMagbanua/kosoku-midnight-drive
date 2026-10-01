@tool
class_name HourglassGauge
extends Control

## Hourglass-shaped tank gauge (slow-mo). The fill is a "sand" level: it
## rises from the bottom as `value` goes up and drops from the top as it
## drains, clipped to the glass. Drawn procedurally like GlowBar/MainDial -
## resize the control to resize the hourglass.
##
## Icon-style shape: rounded cap bars top and bottom, straight glass sides
## that curve in to the waist, and the two side strokes crossing in an X at
## the neck (each stroke runs top-left -> bottom-right or mirrored).

@export_range(0.0, 1.0, 0.001) var value: float = 0.6
@export var fill_color: Color = Color(1.0, 0.82, 0.2)
@export var outline_color: Color = Color(1.0, 0.9, 0.55, 0.7)
@export_range(0.0, 1.0, 0.01) var track_alpha: float = 0.12
## Half-width of the sand's gap at the waist, as a fraction of the full width.
@export_range(0.01, 0.5, 0.01) var neck_frac: float = 0.04
## Thickness of the glass side strokes.
@export var outline_width: float = 2.5
## Thickness of the top/bottom cap bars.
@export var cap_width: float = 3.0
## How far the caps stick out past the glass on each side (fraction of width).
@export_range(0.0, 0.4, 0.01) var cap_overhang: float = 0.12
## How much of each bulb's height is straight-sided before curving in.
@export_range(0.0, 0.9, 0.01) var straight_frac: float = 0.4
## How fast the shown level eases toward `value` (like MainDial).
@export var smoothing: float = 14.0

const CURVE_STEPS := 12

var _shown: float = 0.0

func _ready() -> void:
	_shown = value

func _process(delta: float) -> void:
	var target := clampf(value, 0.0, 1.0)
	if absf(_shown - target) > 0.0005:
		_shown = lerpf(_shown, target, clampf(smoothing * delta, 0.0, 1.0))
		queue_redraw()

## Top-left quarter of the glass: straight down from (x_edge, y_top), then a
## cubic curve in to (centre - neck, mid-height), arriving diagonally so the
## mirrored halves read as an X.
func _quarter(x_edge: float, y_top: float, neck: float) -> PackedVector2Array:
	var cx := size.x * 0.5
	var ym := size.y * 0.5
	var ys := lerpf(y_top, ym, straight_frac)
	var p0 := Vector2(x_edge, y_top)
	var p1 := Vector2(x_edge, ys)
	var end := Vector2(cx - neck, ym)
	var c1 := Vector2(x_edge, lerpf(ys, ym, 0.55))
	var c2 := end - Vector2((cx - x_edge) * 0.45, (ym - ys) * 0.35)
	var pts := PackedVector2Array([p0])
	for i in range(CURVE_STEPS + 1):
		var t := float(i) / CURVE_STEPS
		pts.append(p1.bezier_interpolate(c1, c2, end, t))
	return pts

## The glass interior (inside the strokes) as one polygon.
func _glass_polygon() -> PackedVector2Array:
	var w := size.x
	var h := size.y
	var x_edge := w * cap_overhang + outline_width
	var q := _quarter(x_edge, cap_width, w * neck_frac)
	var left := q.duplicate()
	for i in range(q.size() - 2, -1, -1): # mirror down, skip the shared waist point
		left.append(Vector2(q[i].x, h - q[i].y))
	var poly := left.duplicate()
	for i in range(left.size() - 1, -1, -1): # mirror across, bottom -> top
		poly.append(Vector2(w - left[i].x, left[i].y))
	return poly

func _draw() -> void:
	var w := size.x
	var h := size.y

	var glass := _glass_polygon()
	draw_colored_polygon(glass, Color(fill_color, track_alpha))

	var level_y := h * (1.0 - _shown)
	if _shown > 0.001:
		var below := PackedVector2Array([
			Vector2(-1, level_y), Vector2(w + 1, level_y),
			Vector2(w + 1, h + 1), Vector2(-1, h + 1),
		])
		for poly in Geometry2D.intersect_polygons(glass, below):
			draw_colored_polygon(poly, fill_color)

	# Side strokes: top-left quarter + its point reflection (bottom-right),
	# giving one S from top-left to bottom-right; the other is its mirror.
	var q := _quarter(w * cap_overhang + outline_width * 0.5, cap_width * 0.5, 0.0)
	var s1 := q.duplicate()
	for i in range(q.size() - 2, -1, -1):
		s1.append(Vector2(w - q[i].x, h - q[i].y))
	var s2 := PackedVector2Array()
	for p in s1:
		s2.append(Vector2(w - p.x, p.y))
	draw_polyline(s1, outline_color, outline_width, true)
	draw_polyline(s2, outline_color, outline_width, true)

	# Rounded cap bars.
	var r := cap_width * 0.5
	for y in [r, h - r]:
		draw_line(Vector2(r, y), Vector2(w - r, y), outline_color, cap_width, true)
		draw_circle(Vector2(r, y), r, outline_color, true, -1.0, true)
		draw_circle(Vector2(w - r, y), r, outline_color, true, -1.0, true)
