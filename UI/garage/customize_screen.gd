class_name CustomizeScreen
extends Control

## Customize screen - a sub-mode of the GARAGE state (GarageScreen hides its
## own shop panel/header while this is open, rather than a new GameState,
## so the pause predicates garage_screen.gd/start_screen.gd keep in sync are
## untouched). Everything listed comes from CarManifest - no hardcoded parts.
##
## Tabs:
## - BODY:   left rail = the car's slots; right = a ‹ variant › selector plus
##           a pick grid. Required slots have no NONE.
## - WHEELS: STOCK + 30 rims, and 7 tyres (tyres only apply to a custom rim).
## - PAINT:  SOLID (palette atlases) / LIVERY (vinyls) thumbnail swatches.
## - GLASS:  window tint presets (WindowTint), each with a colour chip.
##
## Twist: picking a slot swings the preview camera to that area of the car
## (SLOT_FOCUS -> GaragePreview viewpoints cust_front/rear/side/top), and a
## small amber callout bottom-left names what's in focus. Drag orbits, the
## wheel zooms (garage_orbit_camera.gd's customize orbit).
##
## Edits re-dress the preview (and the real car) live via
## SaveData.set_loadout(persist = false); BACK writes the save once.

signal closed

## Slot -> preview viewpoint the camera swings to when it's selected.
const SLOT_FOCUS := {
	"Front_Bumper": "cust_front", "Bonnet": "cust_front", "Light_Covers": "cust_front",
	"Nudge_Bar": "cust_front", "Windscreen_Sticker": "cust_front",
	"Rear_Bumper": "cust_rear", "Spoiler": "cust_rear", "Spoiler_Boot": "cust_rear",
	"Exhaust": "cust_rear", "Wheelie_Bars": "cust_rear",
	"Side_Skirts": "cust_side", "Fenders": "cust_side", "Undercarriage": "cust_side",
	"Roof": "cust_top", "Roof_Scoop": "cust_top", "Rollcage": "cust_top", "Louvers": "cust_top",
}
const WHEELS_FOCUS := "cust_side"
const PAINT_FOCUS := "cust_overview"
const GLASS_FOCUS := "cust_side"
const DEFAULT_FOCUS := "cust_overview"

const PANEL_ENTER_OFFSET := 340.0
const TRANSITION_TIME := 0.35

const SWATCH_SIZE := Vector2(140, 70)
const TINT_CHIP_SIZE := 14
const TEAL := Color(0.3725, 0.8157, 0.7882)
const LINE := Color(0.1451, 0.1725, 0.2392)
const MUTED := Color(0.5451, 0.5765, 0.6549)
const RAIL_TEXT := Color(0.8235294, 0.84313726, 0.8901961)

const MOTION_SCRIPT := preload("res://UI/common/button_motion.gd")

@onready var _drag_area: Control = %DragArea
@onready var _header: Control = %Header
@onready var _car_label: Label = %CarLabel
@onready var _focus_tag: Control = %FocusTag
@onready var _focus_label: Label = %FocusLabel
@onready var _focus_sub: Label = %FocusSubLabel
@onready var _panel: Control = %Panel
@onready var _tab_body: Button = %TabBody
@onready var _tab_wheels: Button = %TabWheels
@onready var _tab_paint: Button = %TabPaint
@onready var _tab_glass: Button = %TabGlass
@onready var _info_label: Label = %PresetLabel
@onready var _body_page: Control = %BodyPage
@onready var _wheels_page: Control = %WheelsPage
@onready var _paint_page: Control = %PaintPage
@onready var _glass_page: Control = %GlassPage
@onready var _slot_list: VBoxContainer = %SlotList
@onready var _slot_name: Label = %SlotName
@onready var _slot_kind: Label = %SlotKind
@onready var _prev_variant: Button = %PrevVariant
@onready var _next_variant: Button = %NextVariant
@onready var _variant_label: Label = %VariantLabel
@onready var _variant_grid: GridContainer = %VariantGrid
@onready var _rim_grid: GridContainer = %RimGrid
@onready var _tyre_header: Label = %TyreHeader
@onready var _tyre_grid: GridContainer = %TyreGrid
@onready var _solid_button: Button = %SolidButton
@onready var _livery_button: Button = %LiveryButton
@onready var _paint_name: Label = %PaintName
@onready var _paint_grid: GridContainer = %PaintGrid
@onready var _tint_grid: GridContainer = %TintGrid
@onready var _randomize_button: Button = %RandomizeButton
@onready var _reset_button: Button = %ResetButton
@onready var _done_button: Button = %DoneButton

var _camera: Node
var _settle: Node
var _profile: CarProfile
var _car: String # manifest id
var _loadout: Dictionary = {}
var _slot: String = ""
var _tab: String = "body"
var _paint_group: String = "solid"
var _base_panel_x := 0.0
var _transitioning := false
var _swatch_styles: Dictionary = {}
var _rng := RandomNumberGenerator.new()

func _ready() -> void:
	_rng.randomize()
	_base_panel_x = _panel.position.x
	_tab_body.pressed.connect(_select_tab.bind("body"))
	_tab_wheels.pressed.connect(_select_tab.bind("wheels"))
	_tab_paint.pressed.connect(_select_tab.bind("paint"))
	_tab_glass.pressed.connect(_select_tab.bind("glass"))
	_prev_variant.pressed.connect(_step_variant.bind(-1))
	_next_variant.pressed.connect(_step_variant.bind(1))
	_solid_button.pressed.connect(_select_paint_group.bind("solid"))
	_livery_button.pressed.connect(_select_paint_group.bind("livery"))
	_randomize_button.pressed.connect(_randomize)
	_reset_button.pressed.connect(_reset)
	_done_button.pressed.connect(close)
	_drag_area.gui_input.connect(_on_drag_input)
	_swatch_styles = _make_swatch_styles()
	_build_tint_grid()

func is_open() -> bool:
	return visible

## Opens for the currently selected car. `camera` = the preview's
## garage_orbit_camera.gd, `settle` = its garage_preview_settle.gd.
func open(camera: Node, settle: Node) -> void:
	_camera = camera
	_settle = settle
	_profile = CarCatalog.get_profile(SaveData.get_selected_car_index())
	_car = _profile.manifest_id
	if _car.is_empty():
		return
	_loadout = SaveData.get_loadout(_profile.id)
	ModularCarBuilder.preload_car(_car)
	_car_label.text = _profile.display_name
	_info_label.text = "SAVED ON BACK"
	if _settle and _settle.has_method("set_turntable"):
		_settle.set_turntable(false)

	_build_slot_rail()
	_build_wheel_grids()
	_slot = CarManifest.slots(_car)[0] if not CarManifest.slots(_car).is_empty() else ""
	_select_paint_group("livery" if CarManifest.livery_paints().has(str(_loadout.paint)) else "solid")
	_select_tab("body")

	visible = true
	_panel.position.x = _base_panel_x + PANEL_ENTER_OFFSET
	_panel.modulate.a = 0.0
	_header.modulate.a = 0.0
	_focus_tag.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_panel, "position:x", _base_panel_x, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(_panel, "modulate:a", 1.0, TRANSITION_TIME)
	tw.parallel().tween_property(_header, "modulate:a", 1.0, TRANSITION_TIME)
	tw.parallel().tween_property(_focus_tag, "modulate:a", 1.0, TRANSITION_TIME)

## BACK: saves the loadout, restores the turntable, slides out, then emits
## `closed` (GarageScreen brings its own panels back).
func close() -> void:
	if _transitioning or not visible:
		return
	_transitioning = true
	SaveData.save()
	if _settle and _settle.has_method("set_turntable"):
		_settle.set_turntable(true)
	var tw := create_tween()
	tw.tween_property(_panel, "position:x", _base_panel_x + PANEL_ENTER_OFFSET, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(_panel, "modulate:a", 0.0, TRANSITION_TIME)
	tw.parallel().tween_property(_header, "modulate:a", 0.0, TRANSITION_TIME)
	tw.parallel().tween_property(_focus_tag, "modulate:a", 0.0, TRANSITION_TIME)
	tw.finished.connect(func():
		_transitioning = false
		visible = false
		closed.emit()
	)

## Immediate close without animation (e.g. the garage itself is left).
func force_close() -> void:
	if not visible:
		return
	SaveData.save()
	if _settle and _settle.has_method("set_turntable"):
		_settle.set_turntable(true)
	_transitioning = false
	visible = false
	_panel.position.x = _base_panel_x

# --- tabs -------------------------------------------------------------------

func _select_tab(tab: String) -> void:
	_tab = tab
	_tab_body.disabled = tab == "body"
	_tab_wheels.disabled = tab == "wheels"
	_tab_paint.disabled = tab == "paint"
	_tab_glass.disabled = tab == "glass"
	_body_page.visible = tab == "body"
	_wheels_page.visible = tab == "wheels"
	_paint_page.visible = tab == "paint"
	_glass_page.visible = tab == "glass"
	match tab:
		"body":
			_select_slot(_slot)
		"wheels":
			_focus(WHEELS_FOCUS)
			_refresh_wheels()
		"paint":
			_focus(PAINT_FOCUS)
			_refresh_paint()
		"glass":
			_focus(GLASS_FOCUS)
			_refresh_glass()

func _focus(viewpoint: String) -> void:
	if _camera and _camera.has_method("focus"):
		_camera.focus(viewpoint)

# --- body -------------------------------------------------------------------

func _build_slot_rail() -> void:
	for c in _slot_list.get_children():
		c.queue_free()
	for s in CarManifest.slots(_car):
		var b := _make_button(_slot_label(s), &"CatRailButton")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", RAIL_TEXT)
		b.set_meta("slot", s)
		b.pressed.connect(_select_slot.bind(s))
		_slot_list.add_child(b)

func _select_slot(slot: String) -> void:
	if slot.is_empty():
		return
	_slot = slot
	for b in _slot_list.get_children():
		(b as Button).disabled = b.get_meta("slot") == slot
	_slot_name.text = _slot_label(slot).capitalize()
	var required := CarManifest.is_required(_car, slot)
	var count := CarManifest.variants(_car, slot).size()
	_slot_kind.text = "%s  ·  %d VARIANT%s" % ["REQUIRED" if required else "OPTIONAL", count, "" if count == 1 else "S"]
	_rebuild_variant_grid()
	_refresh_variant()
	_focus(SLOT_FOCUS.get(slot, DEFAULT_FOCUS))

func _rebuild_variant_grid() -> void:
	for c in _variant_grid.get_children():
		c.queue_free()
	for v in CarManifest.options(_car, _slot):
		var b := _make_button(_variant_text(v), &"ToggleButton")
		b.custom_minimum_size = Vector2(58, 0)
		b.set_meta("variant", v)
		b.pressed.connect(_set_variant.bind(v))
		_variant_grid.add_child(b)

func _refresh_variant() -> void:
	var current := _current_variant()
	var opts := CarManifest.options(_car, _slot)
	var variants := CarManifest.variants(_car, _slot)
	_variant_label.text = _variant_text(current)
	_prev_variant.disabled = opts.size() < 2
	_next_variant.disabled = opts.size() < 2
	for b in _variant_grid.get_children():
		(b as Button).disabled = b.get_meta("variant") == current
	_focus_label.text = _slot_label(_slot)
	_focus_sub.text = "NONE FITTED" if current == CarManifest.NONE \
		else "VARIANT %s  ·  %d / %d" % [current, variants.find(current) + 1, variants.size()]

func _current_variant() -> String:
	return str(_loadout.get("slots", {}).get(_slot, CarManifest.NONE))

func _step_variant(step: int) -> void:
	var opts := CarManifest.options(_car, _slot)
	if opts.is_empty():
		return
	var i := opts.find(_current_variant())
	_set_variant(opts[posmod(i + step, opts.size())])

func _set_variant(variant: String) -> void:
	_loadout.slots[_slot] = variant
	_commit()
	_refresh_variant()

static func _slot_label(slot: String) -> String:
	return slot.replace("_", " ").to_upper()

static func _variant_text(v: String) -> String:
	return "NONE" if v == CarManifest.NONE else v

# --- wheels -----------------------------------------------------------------

func _build_wheel_grids() -> void:
	for c in _rim_grid.get_children():
		c.queue_free()
	for c in _tyre_grid.get_children():
		c.queue_free()
	var rims: Array[String] = [CarManifest.STOCK]
	rims.append_array(CarManifest.wheel_ids())
	for id in rims:
		var b := _make_button("STOCK" if id == CarManifest.STOCK else id, &"ToggleButton")
		b.custom_minimum_size = Vector2(52, 0)
		b.set_meta("wheel", id)
		b.pressed.connect(_set_wheel.bind(id))
		_rim_grid.add_child(b)
	for id in CarManifest.tyre_ids():
		var b := _make_button(id, &"ToggleButton")
		b.custom_minimum_size = Vector2(52, 0)
		b.set_meta("tyre", id)
		b.pressed.connect(_set_tyre.bind(id))
		_tyre_grid.add_child(b)

func _refresh_wheels() -> void:
	var wheel := str(_loadout.get("wheel", CarManifest.STOCK))
	var tyre := str(_loadout.get("tyre", ""))
	var stock := wheel == CarManifest.STOCK
	for b in _rim_grid.get_children():
		(b as Button).disabled = b.get_meta("wheel") == wheel
	for b in _tyre_grid.get_children():
		(b as Button).disabled = stock or b.get_meta("tyre") == tyre
		(b as Button).modulate.a = 0.35 if stock else 1.0
	_tyre_header.text = "TYRES  ·  STOCK WHEELS KEEP THEIR OWN" if stock else "TYRES"
	_focus_label.text = "WHEELS"
	_focus_sub.text = "STOCK" if stock else "RIM %s  ·  TYRE %s" % [wheel, tyre]

func _set_wheel(id: String) -> void:
	_loadout.wheel = id
	_commit()
	_refresh_wheels()

func _set_tyre(id: String) -> void:
	_loadout.tyre = id
	_commit()
	_refresh_wheels()

# --- paint ------------------------------------------------------------------

func _select_paint_group(group: String) -> void:
	_paint_group = group
	_solid_button.disabled = group == "solid"
	_livery_button.disabled = group == "livery"
	for c in _paint_grid.get_children():
		c.queue_free()
	var files := CarManifest.solid_paints() if group == "solid" else CarManifest.livery_paints()
	for f in files:
		_paint_grid.add_child(_make_swatch(f))
	_refresh_paint()

func _make_swatch(file: String) -> Button:
	var b := Button.new()
	b.set_script(MOTION_SCRIPT)
	b.set("hover_scale", 1.05)
	b.custom_minimum_size = SWATCH_SIZE
	b.icon = load(CarManifest.thumb_path(file)) as Texture2D
	b.expand_icon = true
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.tooltip_text = CarManifest.paint_label(file)
	b.focus_mode = Control.FOCUS_NONE
	for state in _swatch_styles:
		b.add_theme_stylebox_override(state, _swatch_styles[state])
	b.set_meta("paint", file)
	b.pressed.connect(_set_paint.bind(file))
	b.mouse_entered.connect(ModularCarBuilder.preload_texture.bind(file))
	return b

## Swatch frame: thin line normally, muted on hover, teal when equipped
## (equipped = disabled, the theme's own "active" convention).
func _make_swatch_styles() -> Dictionary:
	var out := {}
	for state in ["normal", "hover", "pressed", "disabled", "focus"]:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0)
		var w := 2 if state == "disabled" else 1
		sb.set_border_width_all(w)
		sb.set_content_margin_all(3)
		match state:
			"hover", "pressed": sb.border_color = MUTED
			"disabled": sb.border_color = TEAL
			"focus": sb.border_color = Color(0, 0, 0, 0)
			_: sb.border_color = LINE
		out[state] = sb
	return out

func _refresh_paint() -> void:
	var paint := str(_loadout.get("paint", ""))
	for b in _paint_grid.get_children():
		(b as Button).disabled = b.get_meta("paint") == paint
	_paint_name.text = CarManifest.paint_label(paint)
	if _tab == "paint":
		_focus_label.text = "PAINT"
		_focus_sub.text = CarManifest.paint_label(paint)

func _set_paint(file: String) -> void:
	_loadout.paint = file
	_commit()
	_refresh_paint()

# --- glass ------------------------------------------------------------------

## One button per tint preset, built once (the presets are the same for every
## car). The chip shows the tint's colour at full opacity so dark tints still
## read against the panel.
func _build_tint_grid() -> void:
	for id in WindowTint.ids():
		var b := _make_button(WindowTint.label(id), &"ToggleButton")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.icon = _tint_chip(WindowTint.color(id))
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.set_meta("tint", id)
		b.pressed.connect(_set_tint.bind(id))
		_tint_grid.add_child(b)

static func _tint_chip(c: Color) -> Texture2D:
	var img := Image.create(TINT_CHIP_SIZE, TINT_CHIP_SIZE, false, Image.FORMAT_RGBA8)
	img.fill(Color(c, 1.0))
	return ImageTexture.create_from_image(img)

func _refresh_glass() -> void:
	var tint := str(_loadout.get("tint", WindowTint.DEFAULT))
	for b in _tint_grid.get_children():
		(b as Button).disabled = b.get_meta("tint") == tint
	if _tab == "glass":
		_focus_label.text = "GLASS"
		_focus_sub.text = WindowTint.label(tint)

func _set_tint(id: String) -> void:
	_loadout.tint = id
	_commit()
	_refresh_glass()

# --- randomize / reset ------------------------------------------------------

func _randomize() -> void:
	for s in CarManifest.slots(_car):
		var opts := CarManifest.options(_car, s)
		_loadout.slots[s] = opts[_rng.randi_range(0, opts.size() - 1)]
	var rims := CarManifest.wheel_ids()
	_loadout.wheel = CarManifest.STOCK if _rng.randf() < 0.25 else rims[_rng.randi_range(0, rims.size() - 1)]
	var tyres := CarManifest.tyre_ids()
	_loadout.tyre = tyres[_rng.randi_range(0, tyres.size() - 1)]
	var paints := CarManifest.all_paints()
	_loadout.paint = paints[_rng.randi_range(0, paints.size() - 1)]
	var tints := WindowTint.ids()
	_loadout.tint = tints[_rng.randi_range(0, tints.size() - 1)]
	_commit()
	_refresh_all()

func _reset() -> void:
	_loadout = CarManifest.preset_loadout(_car, CarManifest.DEFAULT_PRESET, _profile.default_paint)
	_commit()
	_refresh_all()

func _refresh_all() -> void:
	_select_paint_group("livery" if CarManifest.livery_paints().has(str(_loadout.paint)) else "solid")
	match _tab:
		"body": _select_slot(_slot)
		"wheels": _refresh_wheels()
		"paint": _refresh_paint()
		"glass": _refresh_glass()

## Pushes the edit to SaveData (live re-dress of preview + real car; the save
## file is written on BACK).
func _commit() -> void:
	_loadout = CarManifest.sanitize(_car, _loadout, _profile.default_paint)
	SaveData.set_loadout(_profile.id, _loadout, false)

# --- orbit input --------------------------------------------------------------

func _on_drag_input(event: InputEvent) -> void:
	if _camera == null:
		return
	if event is InputEventMouseMotion and (event.button_mask & (MOUSE_BUTTON_MASK_LEFT | MOUSE_BUTTON_MASK_RIGHT)) != 0:
		_camera.orbit_by(event.relative)
		_drag_area.accept_event()
	elif event is InputEventScreenDrag:
		_camera.orbit_by(event.relative)
		_drag_area.accept_event()
	elif event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_camera.zoom_by(1.0)
			_drag_area.accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_camera.zoom_by(-1.0)
			_drag_area.accept_event()
	elif event is InputEventMagnifyGesture:
		_camera.zoom_by(log(event.factor) / log(1.12))
		_drag_area.accept_event()

# --- helpers ------------------------------------------------------------------

func _make_button(text: String, variation: StringName) -> Button:
	var b := Button.new()
	b.set_script(MOTION_SCRIPT)
	b.set("hover_scale", 1.05)
	b.text = text
	b.theme_type_variation = variation
	b.focus_mode = Control.FOCUS_NONE
	return b
