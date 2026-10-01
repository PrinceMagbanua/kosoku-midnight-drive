extends Control

## The loading screen's animated car (LoadingScreen): a side-profile coupe
## drawn with plain polygons, driving right while the road markings and speed
## streaks stream past underneath it, faster the longer it runs. `launch()`
## floors it off the right edge. Driven by real time, not the scene tree's
## delta, so a hitch behind the loading screen doesn't distort the motion.

const BODY_COLOR := Color(0.925, 0.933, 0.957)
const GLASS_COLOR := Color(0.07, 0.08, 0.11)
const TYRE_COLOR := Color(0.05, 0.05, 0.07)
const RIM_COLOR := Color(0.55, 0.57, 0.62)
const ACCENT := Color(0.91, 0.64, 0.24) # the wordmark's amber
const TAIL_COLOR := Color(1.0, 0.18, 0.12)

const CAR_LENGTH := 200.0 # px, the profile below is authored at this size
const WHEEL_R := 13.0
const WHEELS_X: Array[float] = [42.0, 158.0]
const BODY_DROP := 10.0 # body sits this far below the profile's origin line (sill just under the axles)

## Scroll speed (px/s) of the road markings: starts at BASE, grows by ACCEL
## * t^ACCEL_POW, never past MAX.
const SPEED_BASE := 160.0
const SPEED_ACCEL := 240.0
const SPEED_ACCEL_POW := 1.35
const SPEED_MAX := 2600.0
const DASH_LEN := 46.0
const DASH_GAP := 34.0
const STREAKS := 14

## Side profile (x right / y down), origin at the rear bumper; drawn BODY_DROP
## below the axle line.
const BODY: Array[Vector2] = [
	Vector2(-2, -12), Vector2(-3, -25), Vector2(6, -30), Vector2(40, -32),
	Vector2(72, -49), Vector2(112, -51), Vector2(138, -37), Vector2(186, -31),
	Vector2(201, -23), Vector2(200, -12),
]
const GLASS: Array[Vector2] = [
	Vector2(78, -45), Vector2(110, -47), Vector2(130, -37), Vector2(66, -36),
]

var _t := 0.0 # seconds running
var _scroll := 0.0 # px the road has moved
var _speed := SPEED_BASE
var _wheel_angle := 0.0
var _launch_t := -1.0 # seconds since launch(), -1 = not launched
var _last_usec := 0
var _streaks: Array[Vector3] = [] # (x, y, length factor)
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	for i in STREAKS:
		_streaks.append(Vector3(_rng.randf(), _rng.randf(), _rng.randf_range(0.4, 1.0)))

## Back to a standstill, ready for the next load.
func reset() -> void:
	_t = 0.0
	_scroll = 0.0
	_speed = SPEED_BASE
	_launch_t = -1.0
	_last_usec = Time.get_ticks_usec()
	queue_redraw()

func launch() -> void:
	if _launch_t < 0.0:
		_launch_t = 0.0

func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		_last_usec = Time.get_ticks_usec()
		return
	var now := Time.get_ticks_usec()
	# Capped, so a long hitch reads as a pause rather than a teleport.
	var dt: float = minf(float(now - _last_usec) / 1000000.0, 0.1)
	_last_usec = now
	_t += dt
	_speed = minf(SPEED_BASE + SPEED_ACCEL * pow(_t, SPEED_ACCEL_POW), SPEED_MAX)
	if _launch_t >= 0.0:
		_launch_t += dt
		_speed = minf(_speed * (1.0 + 3.0 * dt), SPEED_MAX * 1.5)
	_scroll += _speed * dt
	_wheel_angle += _speed * dt / WHEEL_R
	queue_redraw()

func _draw() -> void:
	var ground_y: float = size.y - 18.0
	var speed_t: float = clampf((_speed - SPEED_BASE) / (SPEED_MAX - SPEED_BASE), 0.0, 1.0)

	# Ground line, fading out at both ends.
	var fade := Color(ACCENT, 0.0)
	draw_polyline_colors(PackedVector2Array([Vector2(0, ground_y), Vector2(size.x * 0.5, ground_y), Vector2(size.x, ground_y)]),
		PackedColorArray([fade, Color(ACCENT, 0.35), fade]), 1.0, true)
	# Lane dashes scrolling left.
	var step := DASH_LEN + DASH_GAP
	var x: float = -fmod(_scroll, step)
	while x < size.x:
		var a: float = _edge_fade(x + DASH_LEN * 0.5) * 0.55
		draw_line(Vector2(x, ground_y + 9.0), Vector2(x + DASH_LEN, ground_y + 9.0), Color(BODY_COLOR, a), 2.0, true)
		x += step

	# Car position: eases back a touch as it picks up speed, then launches.
	var car_x: float = size.x * 0.5 - CAR_LENGTH * 0.5 - 18.0 * speed_t
	if _launch_t >= 0.0:
		car_x += 900.0 * _launch_t * _launch_t + 60.0 * _launch_t
	var bob: float = sin(_t * 31.0) * 0.8 * speed_t
	var origin := Vector2(car_x, ground_y - WHEEL_R + bob) # axle line
	var body_o := origin + Vector2(0, BODY_DROP)

	# Speed streaks behind and around the car - longer and brighter with speed.
	for s in _streaks:
		var sy: float = ground_y - 8.0 - s.y * 70.0
		var streak_len: float = (30.0 + 170.0 * speed_t) * s.z
		var sx: float = fposmod(s.x * size.x - _scroll * (0.6 + s.z), size.x + streak_len) - streak_len
		var sa: float = (0.08 + 0.35 * speed_t) * s.z * _edge_fade(sx + streak_len * 0.5)
		draw_line(Vector2(sx, sy), Vector2(sx + streak_len, sy), Color(BODY_COLOR, sa), 1.0, true)

	# Headlight beam.
	var nose := body_o + Vector2(199, -24)
	var beam := PackedVector2Array([nose, nose + Vector2(150, -16), nose + Vector2(150, 22)])
	draw_polygon(beam, PackedColorArray([Color(ACCENT, 0.35), Color(ACCENT, 0.0), Color(ACCENT, 0.0)]))

	# Body, glass, lights.
	var body := _offset(BODY, body_o)
	draw_colored_polygon(body, BODY_COLOR)
	draw_polyline(body + PackedVector2Array([body[0]]), BODY_COLOR, 1.2, true) # smooth the edges
	draw_colored_polygon(_offset(GLASS, body_o), GLASS_COLOR)
	draw_line(body_o + Vector2(4, -27), body_o + Vector2(14, -29), TAIL_COLOR, 3.0, true)
	draw_line(body_o + Vector2(188, -28), body_o + Vector2(198, -25), ACCENT, 2.5, true)
	# Accent stripe along the flank.
	draw_line(body_o + Vector2(10, -21), body_o + Vector2(194, -19), Color(ACCENT, 0.9), 1.5, true)

	# Wheels, spinning.
	for wx in WHEELS_X:
		var c := origin + Vector2(wx, 0)
		draw_circle(c, WHEEL_R + 3.0, GLASS_COLOR) # wheel arch shadow
		draw_circle(c, WHEEL_R, TYRE_COLOR)
		draw_arc(c, WHEEL_R * 0.62, 0.0, TAU, 20, RIM_COLOR, 1.5, true)
		for k in 3:
			var ang: float = _wheel_angle + TAU * float(k) / 3.0
			draw_line(c, c + Vector2(cos(ang), sin(ang)) * WHEEL_R * 0.6, RIM_COLOR, 1.5, true)

func _offset(points: Array[Vector2], origin: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(origin + p)
	return out

## 0 at the widget's left/right edges, 1 across the middle.
func _edge_fade(x: float) -> float:
	var edge: float = size.x * 0.18
	return clampf(minf(x, size.x - x) / edge, 0.0, 1.0)
