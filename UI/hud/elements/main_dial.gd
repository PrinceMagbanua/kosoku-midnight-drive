@tool
class_name MainDial
extends Control

## The speedometer cluster (NFS Heat style), drawn in code:
## - RPM number line (x1000): thin ring, major ticks + numbers, minor ticks
##   and half-step dots. Everything is near-transparent until the needle
##   reaches it, then lights up and stays lit behind the needle - the line
##   "fills in" as you rev. Past the redline it lights rose.
## - Needle: fades in from transparent at the centre to a bright red tip, so it
##   never covers the speed number.
## - Nitro arc outside the number line: the bottle currently in use (the
##   NitroBottles row below shows how many are left). Flashes blue/white while
##   the boost fires. Hidden without the nitro upgrade.
## The speed number, "RPM x1000" / "MPH" captions, gear badge and ABS/TCS/ESP
## alerts are child nodes in MainDial.tscn, so they can be moved there.
## The slow-mo arc is a separate element (SideArc) placed concentric with this.
##
## Damage: show_health() takes the car's health 0..1. As it drops from
## damage_tint_from to damage_tint_full the number line, numbers, captions and
## speed number shift toward damage_color and a red glow builds behind the
## dial (the nitro arc stays blue). At critical_below and under, the glow
## pulses and the speed number softly alternates with "DAMAGE CRITICAL"
## (SpeedReadout.set_warning).

@export_range(60.0, 340.0, 1.0) var sweep_deg: float = 260.0
@export var font: Font
@export var number_size: int = 12

@export_group("Colours")
@export var line_color: Color = Color(0.945, 0.973, 0.988) # HudFormat.COL_SMOKE
@export var tick_color: Color = Color(0.945, 0.973, 0.988) # HudFormat.COL_SMOKE
@export var redline_color: Color = Color(1.0, 0.0, 0.502) # HudFormat.COL_ROSE
@export var needle_color: Color = Color(1.0, 0.18, 0.24)
## Nitro arc gradient: a at the arc's start, b at the leading edge.
@export var nitro_color_a: Color = Color(0.1, 0.12, 0.85)
@export var nitro_color_b: Color = Color(0.0, 1.0, 1.0) # HudFormat.COL_CYAN
## Alpha at the arc's start (the leading edge is fully opaque).
@export_range(0.0, 1.0, 0.01) var nitro_start_alpha: float = 0.55
@export var nitro_flash_color: Color = Color(1, 1, 1)
## Alpha of the number line ahead of the needle.
@export_range(0.0, 1.0, 0.01) var unlit_alpha: float = 0.12

@export_group("Damage")
@export var damage_color: Color = Color(1.0, 0.16, 0.22)
## Health where the red tint starts, and where it's complete.
@export_range(0.0, 1.0, 0.01) var damage_tint_from: float = 0.6
@export_range(0.0, 1.0, 0.01) var damage_tint_full: float = 0.3
## At or under this health the glow pulses and "DAMAGE CRITICAL" blinks.
@export_range(0.0, 1.0, 0.01) var critical_below: float = 0.25
## Glow strength (alpha of the widest, faintest layer at full tint).
@export_range(0.0, 1.0, 0.01) var damage_glow: float = 0.12

@export_group("Preview")
@export_range(0.0, 1.0, 0.001) var preview_rpm: float = 0.62
@export_range(0.0, 1.0, 0.001) var preview_nitro: float = 0.8
@export_range(0.0, 1.0, 0.01) var preview_health: float = 1.0

## Radii as fractions of the control's half-size.
const NITRO_R := 0.93
const NITRO_WIDTH := 7.0
const LINE_R := 0.8
const MAJOR_LEN := 9.0
const MINOR_LEN := 4.0
const NUMBER_R := 0.61
const DOT_R := 0.69
const NEEDLE_FROM := 0.2 # fraction of LINE_R where the needle starts (invisible there)
const NEEDLE_TO := 0.97 # fraction of LINE_R the tip reaches
const MINOR_PER_MAJOR := 4
const LIT_EDGE := 0.015 # soft leading edge of the lit number line (fraction of sweep)
const NITRO_FLASH_HZ := 7.0
const ARC_POINTS := 96
const SMOOTHING := 14.0
const TINT_SMOOTHING := 4.0 # how fast the damage tint follows the health
const CRITICAL_PULSE_HZ := 0.9

@onready var _speed: SpeedReadout = %SpeedReadout
@onready var _alerts: AlertStack = %AlertStack
@onready var _gear: GearBadge = %GearBadge
## Child nodes tinted with the dial (white text multiplied toward damage_color).
@onready var _tinted: Array = [$RpmCaption, $RpmScale, %SpeedReadout, %GearBadge]

var _rpm_target := 0.0 # 0..1 of the dial range
var _rpm_shown := 0.0
var _redline := 0.8 # 0..1 of the dial range
var _majors := 10 # numbers 0.._majors (x1000 rpm)
var _nitro_on := false
var _nitro_fill := 0.0
var _nitro_shown := 0.0
var _nitro_active := false
var _health := 1.0
var _tint := 0.0 # 0 = healthy colours, 1 = fully damage_color
var _glow := 0.0 # glow level right now (tint, pulsing when critical)

## The car's overall health 0..1 (chassis) - drives the damage tint.
func show_health(frac: float) -> void:
	_health = clampf(frac, 0.0, 1.0)

## One call per frame with the car's state.
func show_car(rpm: float, rpm_limit: float, mph: float, gear_text: String, abs_on: bool, tcs_on: bool, esp_on: bool, delta: float) -> void:
	_speed.set_speed(int(mph))
	# Same range/redline rule as MISC/car swapper (redline = RPMLimit rounded
	# down to a thousand, dial runs 2000 past it).
	var redline: float = floorf(rpm_limit / 1000.0) * 1000.0
	var rpm_range: float = maxf(redline + 2000.0, 1000.0)
	_majors = int(rpm_range / 1000.0)
	_redline = clampf(redline / rpm_range, 0.0, 1.0)
	_rpm_target = clampf(absf(rpm) / rpm_range, 0.0, 1.0)
	_gear.text = gear_text
	_alerts.update_alerts(abs_on, tcs_on, esp_on, delta)

## Nitro arc: `fill` is the in-use bottle's level 0..1, `active` = firing.
func show_nitro(on: bool, fill: float, active: bool) -> void:
	_nitro_on = on
	_nitro_fill = clampf(fill, 0.0, 1.0)
	_nitro_active = active

func _process(delta: float) -> void:
	if Engine.is_editor_hint():
		_rpm_shown = preview_rpm
		_nitro_shown = preview_nitro
		_nitro_on = true
		_health = preview_health
		_tint = _tint_target()
	else:
		var k := 1.0 - exp(-SMOOTHING * delta)
		_rpm_shown = lerpf(_rpm_shown, _rpm_target, k)
		_nitro_shown = lerpf(_nitro_shown, _nitro_fill, k)
		_tint = lerpf(_tint, _tint_target(), 1.0 - exp(-TINT_SMOOTHING * delta))
	_update_damage_look()
	queue_redraw()

func _tint_target() -> float:
	return 1.0 - smoothstep(damage_tint_full, maxf(damage_tint_from, damage_tint_full + 0.001), _health)

## Tints the child labels, sets the glow level and the critical warning.
func _update_damage_look() -> void:
	var critical := _health <= critical_below
	_glow = _tint
	if critical:
		var t := Time.get_ticks_msec() / 1000.0
		_glow *= 0.55 + 0.45 * (0.5 + 0.5 * sin(t * TAU * CRITICAL_PULSE_HZ))
	var label_tint := Color.WHITE.lerp(damage_color, _tint)
	for ci in _tinted:
		(ci as CanvasItem).modulate = label_tint
	if not Engine.is_editor_hint():
		_speed.set_warning(critical)

func _draw() -> void:
	var c := size * 0.5
	var half := minf(size.x, size.y) * 0.5
	var span := deg_to_rad(sweep_deg)
	var start := -PI * 0.5 - span * 0.5
	if _glow > 0.01:
		_draw_damage_glow(c, half * LINE_R, start, span)
	if _nitro_on:
		_draw_nitro(c, half * NITRO_R, start, span)
	_draw_number_line(c, half * LINE_R, start, span)
	_draw_needle(c, half * LINE_R, start + span * _rpm_shown)

func _draw_nitro(c: Vector2, r: float, start: float, span: float) -> void:
	draw_polyline(_arc(c, r, start, span, 1.0), Color(nitro_color_a, 0.14), NITRO_WIDTH, true)
	if _nitro_shown <= 0.002:
		return
	var flash := 0.0
	if _nitro_active:
		var t := Time.get_ticks_msec() / 1000.0
		flash = 0.5 + 0.5 * sin(t * TAU * NITRO_FLASH_HZ)
	# Gradient runs along the filled part, so the leading edge is always the
	# brightest (cyan) end; the glow follows the same gradient.
	var pts := _arc(c, r, start, span, _nitro_shown)
	var cols := PackedColorArray()
	var glow_outer := PackedColorArray()
	var glow_inner := PackedColorArray()
	for i in pts.size():
		var t := float(i) / float(maxi(pts.size() - 1, 1))
		var col := nitro_color_a.lerp(nitro_color_b, t).lerp(nitro_flash_color, flash * 0.85)
		var a := lerpf(nitro_start_alpha, 1.0, t)
		cols.append(Color(col, a))
		glow_outer.append(Color(col, 0.12 * a))
		glow_inner.append(Color(col, 0.25 * a))
	draw_polyline_colors(pts, glow_outer, NITRO_WIDTH + 10.0, true)
	draw_polyline_colors(pts, glow_inner, NITRO_WIDTH + 5.0, true)
	draw_polyline_colors(pts, cols, NITRO_WIDTH, true)

## Soft red glow behind the dial: a faint disc plus layered halos on the ring.
func _draw_damage_glow(c: Vector2, r: float, start: float, span: float) -> void:
	draw_circle(c, r * 1.04, Color(damage_color, damage_glow * 0.5 * _glow))
	draw_circle(c, r * 0.78, Color(damage_color, damage_glow * 0.4 * _glow))
	var ring := _arc(c, r, start, span, 1.0)
	draw_polyline(ring, Color(damage_color, damage_glow * _glow), 18.0, true)
	draw_polyline(ring, Color(damage_color, damage_glow * 1.6 * _glow), 9.0, true)

func _draw_number_line(c: Vector2, r: float, start: float, span: float) -> void:
	# Ring: dim all the way, bright up to the needle (rose past the redline).
	var ring_color := line_color.lerp(damage_color, _tint)
	draw_polyline(_arc(c, r, start, span, 1.0), Color(ring_color, unlit_alpha), 1.5, true)
	var lit := _rpm_shown
	if lit > 0.002:
		var below_red := minf(lit, _redline)
		draw_polyline(_arc(c, r, start, span, below_red), Color(ring_color, 0.3), 5.0, true)
		draw_polyline(_arc(c, r, start, span, below_red), ring_color, 2.0, true)
		if lit > _redline:
			var red_pts := _arc(c, r, start + span * _redline, span, lit - _redline)
			draw_polyline(red_pts, Color(redline_color, 0.3), 5.0, true)
			draw_polyline(red_pts, redline_color, 2.0, true)

	var f: Font = font if font else get_theme_default_font()
	var steps := _majors * MINOR_PER_MAJOR
	for i in steps + 1:
		var frac := float(i) / float(steps)
		var a := start + span * frac
		var dir := Vector2(cos(a), sin(a))
		var col := _lit_color(frac)
		if i % MINOR_PER_MAJOR == 0:
			draw_line(c + dir * (r - 1.0), c + dir * (r - MAJOR_LEN), col, 2.5, true)
			var label := str(int(float(i) / MINOR_PER_MAJOR))
			var ts := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, number_size)
			var p := c + dir * (r * NUMBER_R / LINE_R) - Vector2(ts.x * 0.5, -f.get_ascent(number_size) * 0.5 + 1.0)
			draw_string(f, p, label, HORIZONTAL_ALIGNMENT_LEFT, -1, number_size, col)
		else:
			draw_line(c + dir * (r - 1.0), c + dir * (r - MINOR_LEN), Color(col, col.a * 0.7), 1.0, true)
			if i % MINOR_PER_MAJOR == 2: # half-step dot
				draw_circle(c + dir * (r * DOT_R / LINE_R), 1.5, Color(col, col.a * 0.8))

## Tick/number colour at `frac` of the sweep: transparent ahead of the needle,
## lit behind it (soft leading edge), rose past the redline.
func _lit_color(frac: float) -> Color:
	var lit := clampf((_rpm_shown - frac) / LIT_EDGE + 1.0, 0.0, 1.0)
	var base := redline_color if frac > _redline + 0.001 else tick_color.lerp(damage_color, _tint)
	return Color(base, lerpf(unlit_alpha, 1.0, lit))

func _draw_needle(c: Vector2, r: float, angle: float) -> void:
	var dir := Vector2(cos(angle), sin(angle))
	var n := 10
	var pts := PackedVector2Array()
	var cols := PackedColorArray()
	var glow_cols := PackedColorArray()
	for i in n:
		var t := float(i) / float(n - 1)
		pts.append(c + dir * r * lerpf(NEEDLE_FROM, NEEDLE_TO, t))
		var alpha := t * t
		cols.append(Color(needle_color.lerp(Color.WHITE, 0.25 * t), alpha))
		glow_cols.append(Color(needle_color, alpha * 0.3))
	draw_polyline_colors(pts, glow_cols, 7.0, true)
	draw_polyline_colors(pts, cols, 2.5, true)

func _arc(c: Vector2, r: float, start: float, span: float, fill: float) -> PackedVector2Array:
	var n := maxi(2, int(ceil(ARC_POINTS * fill)) + 1)
	var pts := PackedVector2Array()
	for i in n:
		var a := start + span * fill * float(i) / float(n - 1)
		pts.append(c + Vector2(cos(a), sin(a)) * r)
	return pts
