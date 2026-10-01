class_name UpgradeTile
extends PanelContainer

## One tile in the garage's upgrade grid (see garage_screen.gd): the
## upgrade's icon over a row of level pips, plus a MAX tag once maxed.
## Milestone levels (the big jumps) get wider pips so they read at a glance.
## Hover/selection only change the look - the info panel under the grid does
## the buying.

signal hovered(id: String)
signal unhovered(id: String)
signal clicked(id: String)

const STYLE_NORMAL := &"UpgradeTile"
const STYLE_HOVER := &"UpgradeTileHover"
const STYLE_SELECTED := &"UpgradeTileSelected"
const HOVER_SCALE := 1.04
const HOVER_TIME := 0.15
const PIP_SIZE := Vector2(9, 4)
const MILESTONE_PIP_SIZE := Vector2(15, 4)
const ICON_COLOR := Color(0.8235, 0.8431, 0.8902, 1)
const ICON_LIT := Color(0.9255, 0.9333, 0.9569, 1)
const ICON_MAXED := Color(0.3725, 0.8157, 0.7882, 1) # teal, like MaxedButton
const DIM_ALPHA := 0.4 # can't afford the next level / nothing to refund
## Stand-ins shown if an icon is missing from assets/icons/upgrade-icons/.
const PLACEHOLDER := {
	"accel": "ACC", "topSpeed": "TOP", "handling": "HDL", "braking": "BRK",
	"armor": "ARM", "nitro": "N2O", "nitroFuel": "N2O+", "slowmo": "SB",
	"slowmoFuel": "SB+",
}

@onready var _icon: TextureRect = %Icon
@onready var _placeholder: Label = %Placeholder
@onready var _pips: HBoxContainer = %PipsRow
@onready var _max_tag: Label = %MaxTag

var id: String
var _hover := false
var _selected := false
var _maxed := false
var _dim := false
var _tween: Tween

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)
	resized.connect(func(): pivot_offset = size / 2.0)
	pivot_offset = size / 2.0

func setup(row: UpgradeRow, tier: int, can_afford: bool) -> void:
	id = row.id
	_set_icon(row.icon)
	_maxed = tier >= row.max_tier
	_dim = not _maxed and not can_afford
	_max_tag.visible = _maxed
	_build_pips(row, tier)
	_restyle()

func set_selected(on: bool) -> void:
	_selected = on
	_restyle()

func _gui_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		clicked.emit(id)
		accept_event()

func _on_mouse_entered() -> void:
	_hover = true
	_restyle()
	_animate(Vector2.ONE * HOVER_SCALE)
	hovered.emit(id)

func _on_mouse_exited() -> void:
	_hover = false
	_restyle()
	_animate(Vector2.ONE)
	unhovered.emit(id)

func _set_icon(icon: Texture2D) -> void:
	_icon.texture = icon
	_icon.visible = icon != null
	_placeholder.visible = icon == null
	_placeholder.text = PLACEHOLDER.get(id, id.left(3).to_upper())

func _restyle() -> void:
	if _selected:
		theme_type_variation = STYLE_SELECTED
	elif _hover:
		theme_type_variation = STYLE_HOVER
	else:
		theme_type_variation = STYLE_NORMAL
	var c := ICON_MAXED if _maxed else (ICON_LIT if _selected or _hover else ICON_COLOR)
	c.a = DIM_ALPHA if _dim else 1.0
	_icon.modulate = c
	_placeholder.modulate = c

func _animate(target_scale: Vector2) -> void:
	if _tween:
		_tween.kill()
	_tween = create_tween()
	_tween.tween_property(self, "scale", target_scale, HOVER_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

func _build_pips(row: UpgradeRow, tier: int) -> void:
	for child in _pips.get_children():
		child.queue_free()
	for i in row.max_tier:
		var pip := Panel.new()
		pip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		pip.custom_minimum_size = MILESTONE_PIP_SIZE if (i + 1) in row.milestones else PIP_SIZE
		pip.theme_type_variation = &"PipOn" if i < tier else &"PipOff"
		_pips.add_child(pip)
