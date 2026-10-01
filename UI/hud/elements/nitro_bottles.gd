@tool
class_name NitroBottles
extends Control

## Nitro tank as a row of N2O bottles under the speedometer (NFS Heat style).
## The tank is one continuous 0..1 value split evenly across `count` bottles:
## full bottles glow cyan, the one being used drains smoothly, empties are a
## dim outline. The last bottle turns rose once less than one bottle is left.
## Drawn in code like MainDial; bottles are `bottle_width` wide and the row
## is centred in the control, so it stays put as `count` changes.
##
## live_hud.gd sets `count` (from the nitroFuel upgrade) and `value`, and
## flares the row on `bottle_changed` (a bottle emptied or refilled).

signal bottle_changed

@export_range(0.0, 1.0, 0.001) var value: float = 0.7
@export_range(1, 8, 1) var count: int = 4:
	set(c):
		if c == count:
			return
		count = c
		_whole = _bottles_left(value) # a resize isn't a bottle emptying/refilling
		queue_redraw()
@export var fill_color: Color = Color(0.0, 1.0, 1.0) # HudFormat.COL_CYAN
@export var low_color: Color = Color(1.0, 0.0, 0.502) # HudFormat.COL_ROSE
@export_range(0.0, 1.0, 0.01) var empty_alpha: float = 0.25
@export var bottle_width: float = 12.0
@export var gap: float = 5.0
@export var outline_width: float = 1.5
## Higher = snappier level.
@export var smoothing: float = 14.0

const CORNER_STEPS := 4

var _shown: float = 0.0
var _whole := -1 # bottles with anything left in them, for bottle_changed

func _ready() -> void:
	_shown = value
	_whole = _bottles_left(value)

func _process(delta: float) -> void:
	var target := clampf(value, 0.0, 1.0)
	if Engine.is_editor_hint():
		_shown = target
	elif absf(_shown - target) > 0.0005:
		_shown = lerpf(_shown, target, 1.0 - exp(-smoothing * delta))
	else:
		_shown = target
	var whole := _bottles_left(target)
	if whole != _whole:
		_whole = whole
		if not Engine.is_editor_hint():
			bottle_changed.emit()
	queue_redraw()

func _bottles_left(v: float) -> int:
	return int(ceil(v * count - 0.001))

func _draw() -> void:
	var bw := bottle_width
	var x0 := (size.x - (bw * float(count) + gap * float(count - 1))) * 0.5
	var low := _shown * count < 1.0
	for i in count:
		var rect := Rect2(Vector2(x0 + float(i) * (bw + gap), 0.0), Vector2(bw, size.y))
		var col := low_color if low else fill_color
		var fill := clampf(_shown * count - float(i), 0.0, 1.0)
		_bottle(rect, fill, col)

## One bottle: cap, neck, shoulders, rounded body. `fill` 0..1 of the body.
func _bottle(r: Rect2, fill: float, col: Color) -> void:
	var body := _body_polygon(r)
	# Fake glow behind a filled bottle (layered strokes - no 2D bloom).
	if fill > 0.0:
		var c := r.get_center()
		for layer in [[1.35, 0.08], [1.18, 0.14]]:
			var grown := PackedVector2Array()
			for p in body:
				grown.append(c + (p - c) * Vector2(layer[0], 1.0 + (layer[0] - 1.0) * 0.4))
			draw_colored_polygon(grown, Color(col, layer[1] * fill))
	draw_colored_polygon(body, Color(col, empty_alpha * 0.35))
	if fill > 0.001:
		var level_y := lerpf(r.end.y, r.position.y + r.size.y * 0.32, fill)
		var below := PackedVector2Array([
			Vector2(r.position.x - 1, level_y), Vector2(r.end.x + 1, level_y),
			Vector2(r.end.x + 1, r.end.y + 1), Vector2(r.position.x - 1, r.end.y + 1)])
		for poly in Geometry2D.intersect_polygons(body, below):
			draw_colored_polygon(poly, col)
	var closed := body.duplicate()
	closed.append(body[0])
	draw_polyline(closed, Color(col, 0.9 if fill > 0.0 else empty_alpha), outline_width, true)
	# Cap.
	var cap_w := r.size.x * 0.42
	var cap := Rect2(r.position.x + (r.size.x - cap_w) * 0.5, r.position.y, cap_w, r.size.y * 0.1)
	draw_rect(cap, Color(col, 0.9 if fill > 0.0 else empty_alpha))

## Neck at the top, shoulders sloping out to a round-cornered body.
func _body_polygon(r: Rect2) -> PackedVector2Array:
	var x0 := r.position.x + outline_width
	var x1 := r.end.x - outline_width
	var cx := r.get_center().x
	var neck := r.size.x * 0.17
	var y_neck := r.position.y + r.size.y * 0.13
	var y_shoulder := r.position.y + r.size.y * 0.24
	var y_body := r.position.y + r.size.y * 0.34
	var y1 := r.end.y - outline_width
	var rad := minf(r.size.x * 0.22, 4.0)
	var pts := PackedVector2Array([
		Vector2(cx - neck, y_neck), Vector2(cx + neck, y_neck),
		Vector2(cx + neck, y_shoulder), Vector2(x1, y_body)])
	_corner(pts, Vector2(x1 - rad, y1 - rad), rad, 0.0)
	_corner(pts, Vector2(x0 + rad, y1 - rad), rad, PI * 0.5)
	pts.append(Vector2(x0, y_body))
	pts.append(Vector2(cx - neck, y_shoulder))
	return pts

func _corner(pts: PackedVector2Array, c: Vector2, rad: float, from: float) -> void:
	for i in CORNER_STEPS + 1:
		var a := from + PI * 0.5 * float(i) / float(CORNER_STEPS)
		pts.append(c + Vector2(cos(a), sin(a)) * rad)
