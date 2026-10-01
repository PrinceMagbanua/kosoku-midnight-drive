extends CanvasLayer

## Autoload. Dev/testing console - double-tap ` (backtick/tilde key) to open,
## ` twice again, Esc or the × to close. Pauses the game while open
## (SceneTree.paused, restored to whatever it was on close). Temporary, for
## this iteration of testing - available in every build, including web
## exports. Remove by deleting this file and its [autoload] line; the only
## hooks elsewhere read `invincible` / `zero_traffic` below.
##
## - Cash: +1,000 / +10,000 (saved immediately).
## - Max all upgrades: every garage upgrade to its max level.
## - Reset save: wipes cash/upgrades/cars/high score (click twice to confirm).
## - Invincible: no HP loss and no crashes (crash_system.gd) - except falling
##   off the road, which would otherwise never end.
## - Zero traffic: pulls every traffic car out of the world
##   (TrafficManager.set_enabled); unticking puts them back.
## - CAMERA - Speed zoom / Speed shake: multipliers (0 = off, 1 = as authored)
##   on the chase camera's speed zoom-out (camera.gd) and the speed camera
##   shake (camera_shake.gd). Tuning sliders; the defaults below are the values
##   picked so far.
## - HUD - HUD sway: multiplier on how far the HUD leans with G-forces
##   (hud_sway.gd). 0 = still. The on/off toggle is in Graphics Config.
## - PSX SHADER: the low-res "PSX crunch" post effect over the 3D view
##   (psx_crunch.gd / psx_crunch.gdshader) - on/off plus every one of its
##   uniforms. `psx` holds the values, `psx_changed` fires when any changes.
## None of these are saved - they go back to the defaults here on restart.

const DOUBLE_TAP_TIME := 0.35 # seconds between the two ` presses
const CONFIRM_TIME := 3.0 # seconds the "click again" reset prompt stays armed
const SCROLL_HEIGHT := 430.0 # the option list scrolls inside this

var invincible := false
var zero_traffic := false
var speed_zoom := 1.9
var speed_shake := 0.75
var hud_sway := 1.0

signal psx_changed
var psx_enabled := false
## Shader uniform name -> value (the shader's own defaults).
var psx := {
	"resolution_x": 320.0,
	"resolution_y": 240.0,
	"color_bit_depth": 4.0,
	"dither_strength": 0.03,
	"jitter_amount": 0.008,
	"jitter_speed": 1.2,
	"jitter_frequency": 180.0,
	"chromatic_aberration_strength": 0.015,
	"vignette_strength": 0.8,
	"vignette_radius": 0.9,
}
## [uniform, label, min, max, step] - one slider each, in this order.
const PSX_SLIDERS := [
	["resolution_x", "Resolution X", 64.0, 1280.0, 8.0],
	["resolution_y", "Resolution Y", 48.0, 720.0, 8.0],
	["color_bit_depth", "Colour bits", 1.0, 8.0, 1.0],
	["dither_strength", "Dither", 0.0, 0.2, 0.005],
	["jitter_amount", "Jitter amount", 0.0, 0.03, 0.001],
	["jitter_speed", "Jitter speed", 0.0, 5.0, 0.1],
	["jitter_frequency", "Jitter frequency", 10.0, 400.0, 5.0],
	["chromatic_aberration_strength", "Chromatic aberration", 0.0, 0.1, 0.001],
	["vignette_strength", "Vignette strength", 0.0, 1.0, 0.05],
	["vignette_radius", "Vignette radius", 0.0, 2.0, 0.05],
]

var _panel: PanelContainer
var _cash_label: Label
var _reset_button: Button
var _last_tap := -10.0
var _reset_armed_until := -10.0
var _was_paused := false
var _prev_mouse_mode := Input.MOUSE_MODE_VISIBLE

func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_panel.visible = false

func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

func is_open() -> bool:
	return _panel.visible

func _input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.physical_keycode == KEY_QUOTELEFT or key.keycode == KEY_QUOTELEFT:
		get_viewport().set_input_as_handled()
		var t := _now()
		if t - _last_tap <= DOUBLE_TAP_TIME:
			_last_tap = -10.0
			if is_open():
				close()
			else:
				open()
		else:
			_last_tap = t
	elif is_open() and key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close()

func open() -> void:
	if is_open():
		return
	_was_paused = get_tree().paused
	get_tree().paused = true
	_prev_mouse_mode = Input.mouse_mode
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_refresh_cash()
	_disarm_reset()
	_panel.visible = true

func close() -> void:
	if not is_open():
		return
	_panel.visible = false
	get_tree().paused = _was_paused
	Input.mouse_mode = _prev_mouse_mode

func _process(_delta: float) -> void:
	if is_open() and _reset_armed_until > 0.0 and _now() > _reset_armed_until:
		_disarm_reset()

# --- actions ------------------------------------------------------------

func _add_cash(amount: int) -> void:
	SaveData.game.garage.cash += amount
	SaveData.save()
	_refresh_cash()

func _max_upgrades() -> void:
	for row in SaveData.upgrade_rows:
		SaveData.set_upgrade_tier(row.id, row.max_tier)
	SaveData.save()
	SaveData.upgrades_changed.emit()

func _on_reset_pressed() -> void:
	if _now() > _reset_armed_until:
		_reset_armed_until = _now() + CONFIRM_TIME
		_reset_button.text = "Click again to wipe the save"
		return
	_disarm_reset()
	SaveData.game = SaveData.new_game()
	SaveData.save()
	SaveData.upgrades_changed.emit()
	SaveData.selected_car_changed.emit(0)
	SaveData.loadout_changed.emit(CarCatalog.get_profile(0).id) # back to its preset look
	_refresh_cash()

func _disarm_reset() -> void:
	_reset_armed_until = -10.0
	if _reset_button:
		_reset_button.text = "Reset save"

func _set_invincible(on: bool) -> void:
	invincible = on

func _set_zero_traffic(on: bool) -> void:
	zero_traffic = on
	var scene := get_tree().current_scene
	var tm: Node = scene.get_node_or_null("TrafficManager") if scene else null
	if tm and tm.has_method("set_enabled"):
		tm.set_enabled(not on)

func _refresh_cash() -> void:
	_cash_label.text = "Cash: $" + HudFormat.commas(SaveData.game.garage.cash)

# --- UI -------------------------------------------------------------------

func _build_ui() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_panel)
	var empty := StyleBoxEmpty.new()
	_panel.add_theme_stylebox_override("panel", empty)
	_panel.add_child(dim)

	var center := CenterContainer.new()
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(center)

	var box := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.09, 0.11, 0.96)
	style.border_color = Color(0.49, 0.83, 1.0, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(16)
	box.add_theme_stylebox_override("panel", style)
	box.custom_minimum_size = Vector2(320, 0)
	center.add_child(box)

	# Header stays put; everything else scrolls under it.
	var frame := VBoxContainer.new()
	frame.add_theme_constant_override("separation", 8)
	box.add_child(frame)

	var header := HBoxContainer.new()
	frame.add_child(header)
	var title := Label.new()
	title.text = "DEV CONSOLE"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 18)
	header.add_child(title)
	var close_button := Button.new()
	close_button.text = "×"
	close_button.custom_minimum_size = Vector2(32, 0)
	close_button.pressed.connect(close)
	header.add_child(close_button)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, SCROLL_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	frame.add_child(scroll)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 8)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(col)

	_cash_label = Label.new()
	col.add_child(_cash_label)

	var cash_row := HBoxContainer.new()
	cash_row.add_theme_constant_override("separation", 8)
	col.add_child(cash_row)
	cash_row.add_child(_button("+1,000 cash", _add_cash.bind(1000)))
	cash_row.add_child(_button("+10,000 cash", _add_cash.bind(10000)))

	col.add_child(_button("Max all upgrades", _max_upgrades))
	_reset_button = _button("Reset save", _on_reset_pressed)
	col.add_child(_reset_button)

	col.add_child(HSeparator.new())
	col.add_child(_check("Invincible", invincible, _set_invincible))
	col.add_child(_check("Zero traffic", zero_traffic, _set_zero_traffic))
	col.add_child(_check("Perf overlay (F3)", PerfMonitor.enabled, func(on: bool) -> void: PerfMonitor.enabled = on))

	col.add_child(_section("CAMERA"))
	col.add_child(_slider("Speed zoom", speed_zoom, 0.0, 3.0, 0.05, func(v: float) -> void: speed_zoom = v, "x"))
	col.add_child(_slider("Speed shake", speed_shake, 0.0, 3.0, 0.05, func(v: float) -> void: speed_shake = v, "x"))

	col.add_child(_section("HUD"))
	col.add_child(_slider("HUD sway", hud_sway, 0.0, 4.0, 0.05, func(v: float) -> void: hud_sway = v, "x"))

	col.add_child(_section("PSX SHADER"))
	col.add_child(_check("Enabled", psx_enabled, func(on: bool) -> void:
		psx_enabled = on
		psx_changed.emit()))
	for s in PSX_SLIDERS:
		col.add_child(_slider(s[1], psx[s[0]], s[2], s[3], s[4], _set_psx.bind(s[0])))

	var hint := Label.new()
	hint.text = "Double-tap ` or press Esc to close"
	hint.modulate = Color(1, 1, 1, 0.5)
	hint.add_theme_font_size_override("font_size", 12)
	frame.add_child(hint)

func _set_psx(value: float, key: String) -> void:
	psx[key] = value
	psx_changed.emit()

## A separator with a small caption over the options that follow.
func _section(title: String) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	box.add_child(HSeparator.new())
	var label := Label.new()
	label.text = title
	label.modulate = Color(1, 1, 1, 0.6)
	label.add_theme_font_size_override("font_size", 11)
	box.add_child(label)
	return box

func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(cb)
	return b

## A slider whose label shows the current value ("Speed zoom  x1.25"), so it
## can be read off and baked into the code. `prefix` goes before the number
## ("x" for multipliers); decimals follow the step size.
func _slider(text: String, value: float, min_value: float, max_value: float, step: float, cb: Callable, prefix := "") -> VBoxContainer:
	var decimals := 0 if step >= 1.0 else (2 if step >= 0.01 else 3)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	var label := Label.new()
	label.text = "%s  %s%s" % [text, prefix, String.num(value, decimals)]
	box.add_child(label)
	var s := HSlider.new()
	s.min_value = min_value
	s.max_value = max_value
	s.step = step
	s.value = value
	s.scrollable = false # the mouse wheel scrolls the list, not the slider under it
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.value_changed.connect(func(v: float) -> void:
		label.text = "%s  %s%s" % [text, prefix, String.num(v, decimals)]
		cb.call(v))
	box.add_child(s)
	return box

func _check(text: String, on: bool, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = on
	c.toggled.connect(cb)
	return c
