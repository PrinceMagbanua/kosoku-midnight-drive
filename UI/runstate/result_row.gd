@tool
class_name ResultRow
extends Control

## One strip of the crash screen's results table (CrashOverlay.tscn): name,
## amount, score, cash. Hard-edged translucent panel - no rounded corners, a
## thin outline. crash_overlay.gd hands it the final values (set_values) and
## drives the animation (set_progress): the strip slides in from the left or
## right while its numbers count up.
##
## The root keeps its place in the table's VBoxContainer; only the inner Body
## moves, so the container re-sorting (label text changing width) can't snap
## a strip back mid-slide.
##
## Look: the exported colours below, per instance in the editor (defaults are
## the HudFormat palette - asphalt fill, smoke outline, yellow cash).

enum Kind { ROW, HEADER, TOTAL }
enum Amount { NONE, TIME, COUNT, KM }

const SLIDE_DISTANCE := 420.0 # px the strip starts off to the side
const OVERSHOOT := 1.1 # ease-out-back strength (0 = no overshoot)

@export var title := "STAT":
	set(v):
		title = v
		_refresh()
@export var kind: Kind = Kind.ROW:
	set(v):
		kind = v
		_refresh()
## Slides in from the right instead of the left.
@export var from_right := false
@export var fill_color := Color(0.098, 0.098, 0.098, 0.55):
	set(v):
		fill_color = v
		_refresh()
@export var outline_color := Color(0.945, 0.973, 0.988, 0.22):
	set(v):
		outline_color = v
		_refresh()
@export var total_fill_color := Color(0.098, 0.098, 0.098, 0.72):
	set(v):
		total_fill_color = v
		_refresh()
@export var total_outline_color := Color(0.945, 0.973, 0.988, 1.0):
	set(v):
		total_outline_color = v
		_refresh()

@onready var body: Panel = %Body
@onready var name_label: Label = %Name
@onready var amount_label: Label = %Amount
@onready var score_label: Label = %Score
@onready var cash_label: Label = %Cash

var _amount := 0.0
var _amount_kind: Amount = Amount.NONE
var _score := 0
var _cash := 0
var _has_score := false

func _ready() -> void:
	_refresh()

func _refresh() -> void:
	if not is_node_ready():
		return
	name_label.text = title
	var style := StyleBoxFlat.new()
	match kind:
		Kind.HEADER:
			style.bg_color = Color(0, 0, 0, 0)
			amount_label.text = "AMOUNT"
			score_label.text = "SCORE"
			cash_label.text = "CASH"
		Kind.TOTAL:
			style.bg_color = total_fill_color
			style.border_color = total_outline_color
			style.set_border_width_all(2)
		_:
			style.bg_color = fill_color
			style.border_color = outline_color
			style.set_border_width_all(1)
	body.add_theme_stylebox_override("panel", style)
	var header := kind == Kind.HEADER
	var size_px := 10 if header else (16 if kind == Kind.TOTAL else 13)
	for l: Label in [name_label, amount_label, score_label, cash_label]:
		l.add_theme_font_size_override("font_size", size_px)
		l.modulate.a = 0.6 if header else 1.0
	cash_label.add_theme_color_override("font_color", HudFormat.COL_SMOKE if header else HudFormat.COL_YELLOW)

## Final values this strip counts up to. `has_score` false = an amount-only
## strip (distance, time): score and cash stay blank.
func set_values(amount: float, amount_kind: Amount, score := 0, cash := 0, has_score := false) -> void:
	_amount = amount
	_amount_kind = amount_kind
	_score = score
	_cash = cash
	_has_score = has_score
	_show(0.0)

## `slide_k` 0..1 = how far in the strip is; `count_k` 0..1 = the count-up.
## Both are clamped here, so the caller can pass raw (time - start) / length.
func set_progress(slide_k: float, count_k: float) -> void:
	var k := clampf(slide_k, 0.0, 1.0)
	body.position.x = (1.0 if from_right else -1.0) * SLIDE_DISTANCE * (1.0 - ease_out_back(k))
	body.modulate.a = clampf(k * 2.5, 0.0, 1.0)
	if kind != Kind.HEADER:
		_show(ease_out_cubic(clampf(count_k, 0.0, 1.0)))

func _show(k: float) -> void:
	match _amount_kind:
		Amount.TIME:
			amount_label.text = time_text(_amount * k)
		Amount.COUNT:
			amount_label.text = HudFormat.commas(int(round(_amount * k)))
		Amount.KM:
			amount_label.text = "%.2f km" % (_amount * k)
		_:
			amount_label.text = ""
	if not _has_score:
		score_label.text = ""
		cash_label.text = ""
		return
	score_label.text = HudFormat.commas(int(round(_score * k)))
	cash_label.text = ("+$" if kind == Kind.TOTAL else "$") + HudFormat.commas(int(round(_cash * k)))

## 75.4 -> "01:15"
static func time_text(seconds: float) -> String:
	var s := int(seconds)
	@warning_ignore("integer_division")
	return "%02d:%02d" % [s / 60, s % 60]

## Fast start, settles on 1 with a small overshoot.
static func ease_out_back(k: float) -> float:
	var c := k - 1.0
	return 1.0 + (OVERSHOOT + 1.0) * c * c * c + OVERSHOOT * c * c

static func ease_out_cubic(k: float) -> float:
	return 1.0 - pow(1.0 - k, 3.0)
