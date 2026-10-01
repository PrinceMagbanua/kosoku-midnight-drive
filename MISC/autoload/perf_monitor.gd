extends CanvasLayer

## Autoload "PerfMonitor" - in-game frame debugger. F3 (or the dev console's
## "Perf overlay" box) toggles the overlay; spike logging runs either way.
##
## Overlay (top right): FPS, frame time (avg / worst over the last second),
## the main-thread CPU frame and physics times, draw calls, primitives, objects
## and node count, plus the heaviest named sections this second.
##
## Sections: game code wraps expensive work in PerfMonitor.begin("name") /
## PerfMonitor.end("name") (road chunk build stages, traffic, ...). Times are
## summed per rendered frame, however many physics ticks that frame ran.
##
## Spikes: a frame slower than SPIKE_MIN_MS and SPIKE_FACTOR x the running
## average is logged with its likely cause - the biggest named section that
## frame, else physics / render - and any note() attached to it
## (e.g. which chunk was being built). The last few are listed on the
## overlay and every one is printed to the output log, so you can copy them.
##
## Collapsing: click the header (or Shift+F3) to fold the overlay down to its
## one-line FPS summary; click the "spikes" line to fold just the spike list
## (it starts folded - the output log has every spike anyway).

const SPIKE_MIN_MS := 25.0
const SPIKE_FACTOR := 1.8
const LOG_LINES := 8
const WINDOW_MS := 1000.0

var enabled := false:
	set(v):
		enabled = v
		if _label:
			_panel.visible = v

var _label: Label
var _panel: PanelContainer
var _header: Button
var _spikes_btn: Button
var _spikes_label: Label
var _collapsed := false
var _spikes_collapsed := true
var _open: Dictionary = {} # name -> start usec
var _frame_sections: Dictionary = {} # name -> usec this frame
var _frame_notes: PackedStringArray = []
var _window_sections: Dictionary = {} # name -> max usec in the current window
var _last_frame_usec := 0
var _avg_ms := 16.0
var _window_start := 0
var _window_worst := 0.0
var _window_frames := 0
var _window_total := 0.0
var _shown_fps := 0.0
var _shown_avg := 0.0
var _shown_worst := 0.0
var _shown_sections: Array = []
var _spikes: PackedStringArray = []

func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_panel.visible = enabled
	RenderingServer.frame_post_draw.connect(_on_frame_end)
	_last_frame_usec = Time.get_ticks_usec()
	_window_start = Time.get_ticks_msec()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_F3:
		if event.shift_pressed and enabled:
			_toggle_collapsed()
		else:
			enabled = not enabled

## Start timing a named section. Nesting different names is fine.
func begin(section: String) -> void:
	_open[section] = Time.get_ticks_usec()

func end(section: String) -> void:
	if not _open.has(section):
		return
	var dt: int = Time.get_ticks_usec() - int(_open[section])
	_open.erase(section)
	_frame_sections[section] = int(_frame_sections.get(section, 0)) + dt

## Extra context for this frame's spike line (e.g. "RoadChunk_42 terrain").
func note(text: String) -> void:
	if _frame_notes.size() < 4:
		_frame_notes.append(text)

func _on_frame_end() -> void:
	var now := Time.get_ticks_usec()
	var frame_ms: float = float(now - _last_frame_usec) / 1000.0
	_last_frame_usec = now

	# Spike? Blame the biggest named section, else the engine's own buckets.
	if frame_ms > SPIKE_MIN_MS and frame_ms > _avg_ms * SPIKE_FACTOR and _window_frames > 5:
		_log_spike(frame_ms)
	_avg_ms = lerpf(_avg_ms, frame_ms, 0.05)

	_window_frames += 1
	_window_total += frame_ms
	_window_worst = maxf(_window_worst, frame_ms)
	for s in _frame_sections:
		_window_sections[s] = maxi(int(_window_sections.get(s, 0)), int(_frame_sections[s]))
	_frame_sections.clear()
	_frame_notes.clear()

	if Time.get_ticks_msec() - _window_start >= WINDOW_MS:
		_shown_fps = float(_window_frames) * 1000.0 / float(Time.get_ticks_msec() - _window_start)
		_shown_avg = _window_total / float(_window_frames)
		_shown_worst = _window_worst
		_shown_sections = []
		for s in _window_sections:
			_shown_sections.append([s, float(_window_sections[s]) / 1000.0])
		_shown_sections.sort_custom(func(a, b): return a[1] > b[1])
		_window_sections.clear()
		_window_start = Time.get_ticks_msec()
		_window_frames = 0
		_window_total = 0.0
		_window_worst = 0.0
		if enabled:
			_refresh()

func _log_spike(frame_ms: float) -> void:
	var cause := ""
	var worst := 0
	for s in _frame_sections:
		if int(_frame_sections[s]) > worst:
			worst = int(_frame_sections[s])
			cause = s
	var physics_ms: float = Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
	# (No "scripts" bucket: TIME_PROCESS is the whole main-thread frame,
	# render submission included, so it can't single out script time.)
	var why: String
	if worst > 0 and float(worst) / 1000.0 > frame_ms * 0.3:
		why = "%s %.1fms" % [cause, float(worst) / 1000.0]
	elif physics_ms > frame_ms * 0.4:
		why = "physics %.1fms (car/traffic/collision)" % physics_ms
	else:
		why = "render/GPU or engine (%d draw calls) - try the Visual Profiler" % int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var line := "%6.1fs  %5.1fms  <- %s" % [Time.get_ticks_msec() / 1000.0, frame_ms, why]
	if not _frame_notes.is_empty():
		line += "  [" + ", ".join(_frame_notes) + "]"
	print("[PerfMonitor] spike ", line)
	_spikes.append(line)
	while _spikes.size() > LOG_LINES:
		_spikes.remove_at(0)
	if enabled:
		_refresh()

func _toggle_collapsed() -> void:
	_collapsed = not _collapsed
	_refresh()

func _toggle_spikes() -> void:
	_spikes_collapsed = not _spikes_collapsed
	_refresh()

func _refresh() -> void:
	_header.text = "%s FPS %d   frame %.1f ms avg / %.1f worst" % [
		"[+]" if _collapsed else "[-]", roundi(_shown_fps), _shown_avg, _shown_worst]
	_label.visible = not _collapsed
	_spikes_btn.visible = not _collapsed and not _spikes.is_empty()
	_spikes_label.visible = _spikes_btn.visible and not _spikes_collapsed
	# The panel only grows on its own - zero its width/height after folding and
	# let the grow directions re-expand it to fit, still pinned top right.
	_panel.offset_left = _panel.offset_right
	_panel.offset_bottom = _panel.offset_top
	if _collapsed:
		return
	var t := "cpu frame %.1f ms   physics %.1f ms\n" % [
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0]
	t += "draw calls %d   prims %dk   objects %d   nodes %d\n" % [
		int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
		int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)),
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))]
	if not _shown_sections.is_empty():
		t += "-- heaviest sections (worst frame, last 1s) --\n"
		for i in mini(6, _shown_sections.size()):
			t += "  %-26s %5.1f ms\n" % [_shown_sections[i][0], _shown_sections[i][1]]
	_label.text = t.strip_edges(false, true)
	if _spikes.is_empty():
		return
	_spikes_btn.text = "%s spikes (%d, also in the output log)" % [
		"[+]" if _spikes_collapsed else "[-]", _spikes.size()]
	if not _spikes_collapsed:
		var s := ""
		for i in range(_spikes.size() - 1, -1, -1):
			s += _spikes[i] + "\n"
		_spikes_label.text = s.strip_edges(false, true)

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_panel.offset_left = -8.0
	_panel.offset_right = -8.0
	_panel.offset_top = 8.0
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_content_margin_all(8)
	style.set_corner_radius_all(4)
	_panel.add_theme_stylebox_override("panel", style)
	add_child(_panel)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_theme_constant_override("separation", 2)
	_panel.add_child(col)
	_header = _fold_button("[-] PerfMonitor - collecting...", _toggle_collapsed)
	col.add_child(_header)
	_label = _text_label()
	col.add_child(_label)
	_spikes_btn = _fold_button("", _toggle_spikes)
	_spikes_btn.visible = false
	col.add_child(_spikes_btn)
	_spikes_label = _text_label()
	_spikes_label.visible = false
	col.add_child(_spikes_label)

func _text_label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", Color(0.85, 1.0, 0.85))
	return l

## Flat, left-aligned text button that never takes keyboard focus (so Space /
## Enter keep driving the car after a click).
func _fold_button(text: String, on_press: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.add_theme_font_size_override("font_size", 11)
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(c, Color(1.0, 0.9, 0.5))
	var empty := StyleBoxEmpty.new()
	for s in ["normal", "hover", "pressed", "focus"]:
		b.add_theme_stylebox_override(s, empty)
	b.pressed.connect(on_press)
	return b
