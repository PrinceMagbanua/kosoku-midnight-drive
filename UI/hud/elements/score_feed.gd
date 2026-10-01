class_name ScoreFeed
extends Control

## Scoring feed under the PilePopup in LiveHud.tscn. The top line is LIVE -
## whatever session is building right now (a drift, a high-speed run) - and
## updates every frame. Below it are the event lines, newest on top:
## - A new event slides in fast from the right while fading in, and pushes the
##   older lines down. It arrives flared (overbright, full opacity) and
##   settles to the HUD's resting 70%; the further down a line sits, the
##   fainter it gets (ROW_ALPHA).
## - The same event again (another OVERTAKE while that's still the top line)
##   doesn't push a new line - it adds onto the top one ("OVERTAKE  +23" ->
##   "OVERTAKE  +46") with a quick pop.
## - A line fades out EVENT_LIFE seconds after it was last added to.
## live_hud.gd routes the data in; this node only draws, building its own
## labels and placing them itself (not a container, so they can slide).
## Tweens and timing ignore Engine.time_scale.

const MAX_EVENTS := 4
const EVENT_LIFE := 2.5 # seconds after the last update before a line fades
const FADE_TIME := 0.4
const LIVE_HEIGHT := 22.0
const LINE_HEIGHT := 18.0
const ROW_ALPHA: Array[float] = [0.7, 0.4, 0.22, 0.1]
const FLARE := Color(1.3, 1.3, 1.3, 1.0) # arrival / re-hit, see HudFlare
const SETTLE_TIME := 0.9
const SLIDE_FROM := 70.0 # px to the right the new line starts at
const SLIDE_TIME := 0.16
const SHIFT_TIME := 0.14
const POP_SCALE := 1.12
const FEED_FONT := preload("res://FONT/KosokuDisplay/KosokuDisplay-Regular.ttf")
const COL_LIVE := HudFormat.COL_CYAN # a session still building
const LIVE_SIZE := 15
const EVENT_SIZE := 12
## Event colours are pulled this far toward grey so the feed stays quiet next
## to the pile total above it.
const MUTE := 0.35
const MUTE_TO := Color(0.78, 0.83, 0.86)

var _live: Label
## Newest first. Each: {label, reason, amount, stamp (msec), tween}
var _entries: Array[Dictionary] = []

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_live = _make_label(LIVE_SIZE, COL_LIVE, LIVE_HEIGHT)
	_live.visible = false
	_live.modulate.a = HudFlare.REST
	add_child(_live)

func _make_label(font_size: int, col: Color, height: float) -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", FEED_FONT)
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	l.add_theme_constant_override("outline_size", 3)
	l.size = Vector2(size.x, height)
	l.pivot_offset = l.size * 0.5
	return l

## The live session line. Empty text hides it.
func set_live(text: String) -> void:
	var was: bool = _live.visible
	_live.visible = text != ""
	_live.text = text
	if _live.visible and not was:
		HudFlare.flare(_live)
	if was != _live.visible:
		_layout(0) # the event lines move up/down to make room

## One scoring event. `amount` 0 = a text-only line (e.g. COMBO BROKEN).
func add_event(reason: String, amount: int, col: Color) -> void:
	var now := Time.get_ticks_msec()
	if not _entries.is_empty() and _entries[0].reason == reason:
		var top: Dictionary = _entries[0]
		top.amount += amount
		top.stamp = now
		top.label.add_theme_color_override("font_color", col.lerp(MUTE_TO, MUTE))
		_set_text(top)
		_pop(top)
		_flare_row(top, 0)
		return

	var l := _make_label(EVENT_SIZE, col.lerp(MUTE_TO, MUTE), LINE_HEIGHT)
	add_child(l)
	var e := {"label": l, "reason": reason, "amount": amount, "stamp": now, "tween": null}
	_entries.push_front(e)
	_set_text(e)
	while _entries.size() > MAX_EVENTS:
		_fade_out(_entries.pop_back())

	l.position = Vector2(SLIDE_FROM, _row_y(0))
	l.modulate.a = 0.0
	var tw := l.create_tween().set_ignore_time_scale(true).set_parallel(true)
	tw.tween_property(l, "position:x", 0.0, SLIDE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(l, "modulate", FLARE, SLIDE_TIME)
	tw.chain().tween_property(l, "modulate", Color(1, 1, 1, ROW_ALPHA[0]), SETTLE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	e.tween = tw
	_layout(1) # everything older shifts down a row and dims

func _process(_delta: float) -> void:
	var now := Time.get_ticks_msec()
	for i in range(_entries.size() - 1, -1, -1):
		if now - int(_entries[i].stamp) > int(EVENT_LIFE * 1000.0):
			_fade_out(_entries[i])
			_entries.remove_at(i)

func _row_y(index: int) -> float:
	return (LIVE_HEIGHT if _live.visible else 0.0) + float(index) * LINE_HEIGHT

## Moves entries from `first` down to their rows and row fade.
func _layout(first: int) -> void:
	for i in range(first, _entries.size()):
		var e: Dictionary = _entries[i]
		var l: Label = e.label
		if e.tween:
			e.tween.kill()
		var tw := l.create_tween().set_ignore_time_scale(true).set_parallel(true)
		tw.tween_property(l, "position", Vector2(0.0, _row_y(i)), SHIFT_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		tw.tween_property(l, "modulate", Color(1, 1, 1, ROW_ALPHA[mini(i, ROW_ALPHA.size() - 1)]), SHIFT_TIME)
		e.tween = tw

func _set_text(e: Dictionary) -> void:
	var l: Label = e.label
	l.text = "%s  +%s" % [e.reason, HudFormat.commas(e.amount)] if e.amount > 0 else String(e.reason)

## Re-hit on a line: flash it bright again, then settle to its row's alpha.
func _flare_row(e: Dictionary, index: int) -> void:
	var l: Label = e.label
	if e.tween:
		e.tween.kill() # may be the arrival slide - finish it instantly
	l.position = Vector2(0.0, _row_y(index))
	l.modulate = FLARE
	var tw := l.create_tween().set_ignore_time_scale(true)
	tw.tween_property(l, "modulate", Color(1, 1, 1, ROW_ALPHA[mini(index, ROW_ALPHA.size() - 1)]), SETTLE_TIME).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)
	e.tween = tw

func _pop(e: Dictionary) -> void:
	var l: Label = e.label
	var tw := l.create_tween().set_ignore_time_scale(true)
	l.scale = Vector2.ONE * POP_SCALE
	tw.tween_property(l, "scale", Vector2.ONE, 0.18).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

func _fade_out(e: Dictionary) -> void:
	var l: Label = e.label
	if e.tween:
		e.tween.kill()
	var tw := l.create_tween().set_ignore_time_scale(true)
	tw.tween_property(l, "modulate:a", 0.0, FADE_TIME)
	tw.tween_callback(l.queue_free)

## Fresh run - drop everything.
func clear() -> void:
	set_live("")
	for e in _entries:
		if e.tween:
			e.tween.kill()
		e.label.queue_free()
	_entries.clear()
