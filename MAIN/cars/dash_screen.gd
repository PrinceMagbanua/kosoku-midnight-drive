@tool
extends MeshInstance3D

## Live gauge display on a car's "Dash_Screen" mesh (see ModularCarBuilder.
## _rig_dash_screen(), which gives the mesh 0..1 UVs across the screen and
## sets "dash_aspect"). Draws an RPM arc, speed (MPH, like the HUD) and gear
## into a small SubViewport and shows it as an unshaded texture, so it reads
## as a lit screen at night.
##
## Cost control: the SubViewport only renders while the active camera is
## within UPDATE_DISTANCE of the screen (cockpit view, garage close-ups);
## otherwise it keeps its last frame and costs nothing.
##
## @tool: also live in a car's interior scene preview (car_interior.gd, whose
## "Editor Preview" values stand in for the car), where it always updates.

const TEX_WIDTH := 512
const UPDATE_DISTANCE := 8.0 # world units
const KPH_PER_UNIT_SPEED := 1.10130592 # same as live_hud.gd
const KM_PER_MILE := 1.609

const BG := Color(0.02, 0.03, 0.05)
const TRACK := Color(0.12, 0.14, 0.2)
const ACCENT := Color(0.9098, 0.6392, 0.2392) # theme amber
const REDLINE := Color(0.95, 0.25, 0.2)
const TEXT := Color(0.9255, 0.9333, 0.9569)
const MUTED := Color(0.5451, 0.5765, 0.6549)
const FONT := preload("res://FONT/Exo2/Exo2-VariableFont_wght.ttf")

var _viewport: SubViewport
var _gauges: DashGauges
var _car: Node

func _ready() -> void:
	var aspect := float(get_meta("dash_aspect", 2.0))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(TEX_WIDTH, clampi(int(TEX_WIDTH / aspect), 64, 1024))
	_viewport.disable_3d = true
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_gauges = DashGauges.new()
	_gauges.size = Vector2(_viewport.size)
	_viewport.add_child(_gauges)
	add_child(_viewport)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = _viewport.get_texture()
	material_override = mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(_delta: float) -> void:
	if _car == null or not is_instance_valid(_car):
		_car = _find_car()
	var near := Engine.is_editor_hint()
	if not near:
		var cam := get_viewport().get_camera_3d()
		var centre := global_transform * get_aabb().get_center()
		near = cam != null and is_visible_in_tree() \
			and cam.global_position.distance_to(centre) < UPDATE_DISTANCE
	_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS if near else SubViewport.UPDATE_DISABLED
	if near and _car:
		_gauges.rpm = float(_car.get("rpm"))
		_gauges.rpm_limit = float(_car.get("RPMLimit"))
		_gauges.mph = (_car as Node3D).get("linear_velocity").length() * KPH_PER_UNIT_SPEED / KM_PER_MILE
		_gauges.gear_text = _gear_text()
		_gauges.queue_redraw()

func _gear_text() -> String:
	var gear: int = _car.get("gear")
	if gear == 0:
		return "N"
	if gear == -1:
		return "R"
	var tt: int = _car.get("TransmissionType")
	return "D" if tt == 1 or tt == 2 else str(gear)

func _find_car() -> Node:
	var n := get_parent()
	while n != null:
		if "rpm" in n and "gear" in n:
			return n
		n = n.get_parent()
	return null


## The 2D gauge face. Layout scales with the texture height, so any screen
## aspect works: RPM arc on the left, speed + gear on the right.
class DashGauges extends Control:
	var rpm := 0.0
	var rpm_limit := 7000.0
	var mph := 0.0
	var gear_text := "N"
	var _font: FontVariation

	func _init() -> void:
		_font = FontVariation.new()
		_font.base_font = FONT
		_font.variation_opentype = {"wght": 700.0}

	func _draw() -> void:
		var w := size.x
		var h := size.y
		draw_rect(Rect2(Vector2.ZERO, size), BG)

		# RPM arc: 270 degrees, from bottom-left clockwise to bottom-right.
		var top: float = ceilf(maxf(rpm_limit, 1000.0) / 1000.0) * 1000.0 + 1000.0
		var r := h * 0.4
		var c := Vector2(minf(h * 0.55, w * 0.3), h * 0.52)
		var a0 := deg_to_rad(135.0)
		var sweep := deg_to_rad(270.0)
		var red_from := clampf(rpm_limit / top, 0.0, 1.0)
		var t := clampf(absf(rpm) / top, 0.0, 1.0)
		var thick := h * 0.07
		draw_arc(c, r, a0, a0 + sweep, 64, TRACK, thick, true)
		draw_arc(c, r, a0 + sweep * red_from, a0 + sweep, 24, REDLINE.darkened(0.5), thick, true)
		if t > 0.0:
			draw_arc(c, r, a0, a0 + sweep * t, 64, REDLINE if t >= red_from else ACCENT, thick, true)
		for k in int(top / 1000.0) + 1:
			var ang := a0 + sweep * (k * 1000.0 / top)
			var dir := Vector2(cos(ang), sin(ang))
			draw_line(c + dir * (r - thick), c + dir * (r - thick * 1.8), MUTED, maxf(h * 0.01, 1.0))
		_text_centered(str(int(absf(rpm) / 100.0) / 10.0).pad_decimals(1), c + Vector2(0, h * 0.06), int(h * 0.2), TEXT)
		_text_centered("x1000 RPM", c + Vector2(0, h * 0.2), int(h * 0.075), MUTED)

		# Speed + gear on the right.
		var sx := c.x + r + (w - (c.x + r)) * 0.5
		_text_centered(str(int(round(mph))), Vector2(sx, h * 0.58), int(h * 0.42), TEXT)
		_text_centered("MPH", Vector2(sx, h * 0.76), int(h * 0.09), MUTED)
		var shift := rpm >= rpm_limit * 0.92
		var box := Rect2(Vector2(sx - h * 0.11, h * 0.06), Vector2(h * 0.22, h * 0.2))
		draw_rect(box, REDLINE if shift else TRACK)
		_text_centered(gear_text, box.get_center() + Vector2(0, h * 0.065), int(h * 0.17), TEXT if shift else ACCENT)

	## Draws `text` centred horizontally on `pos.x`, baseline at `pos.y`.
	func _text_centered(text: String, pos: Vector2, font_size: int, color: Color) -> void:
		var tw := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		draw_string(_font, Vector2(pos.x - tw * 0.5, pos.y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color)
