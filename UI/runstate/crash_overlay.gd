extends CanvasLayer

## Crash/game-over results screen - no backdrop panel, the (desaturated) world
## stays visible behind a light dim. "CRASHED" and what happened sit upper
## left, the run's grade upper right, and in the middle a results table
## (ResultRow strips: amount / score / cash per stat, then TOTAL). Below it the
## best score + wallet, and two buttons: GARAGE (straight to the shop) and
## RESTART (a fresh run right away - CRASHED -> PLAYING triggers run_reset.gd
## like any new run). R also restarts. Freezes the world behind it the same
## way the pause overlay does (SceneTree.paused).
##
## Everything slides in from the left or right on one clock (`_t`, see
## _apply()): title, cause, the empty grade box, the table strips alternating
## sides with their numbers counting up, TOTAL, then the grade letter stamps
## in and the footer/buttons arrive. The T_* constants below are the schedule.
##
## Shows up in two phases on an organic crash (crash_system.gd):
## - CRASHING: after CrashSystem.CRASH_POPUP_DELAY the sequence starts. It is
##   shorter than CrashSystem.CRASH_POPUP_FADE, so everything has landed by
##   the time the state flips. Input is ignored here.
## - CRASHED: crash_system.gd flips the state (and only then ends the
##   slow-mo). Input goes live.
## Pause's "END RUN" skips straight to CRASHED - the same sequence plays from
## the start, titled "RUN ENDED", and input goes live once the buttons are in.
##
## All timing here runs on REAL time (delta / Engine.time_scale), since the
## whole CRASHING phase plays under slow-mo.
##
## This is the single place bank_run_rewards() is called for an actual
## crash - fires once on every path into CRASHED rather than at each call
## site, so a run's rewards can never get double-banked.

const SLIDE_DISTANCE := 420.0 # px the title/grade/footer blocks start off to the side
const DIM_FADE := 0.4
const BLOCK_SLIDE := 0.35 # slide length of a block (title, grade box, footer...)
const T_TITLE := 0.0
const T_GRADE_BOX := 0.1
const T_CAUSE := 0.15
const T_HEADER := 0.3
const T_ROWS := 0.35 # first table strip
const ROW_STAGGER := 0.09 # between strips
const ROW_SLIDE := 0.32
const ROW_COUNT_DELAY := 0.1 # a strip's numbers start this long after it does
const ROW_COUNT := 0.5
const TOTAL_GAP := 0.12 # pause between the last strip starting and TOTAL
const TOTAL_COUNT := 0.7
const FOOTER_AFTER_TOTAL := 0.25
const BUTTONS_AFTER_FOOTER := 0.15
const GRADE_STAMP := 0.25 # the letter lands once TOTAL has finished counting
const STAMP_SCALE := 2.4

const COL_TITLE_CRASH := HudFormat.COL_ROSE
const COL_TITLE_ENDED := HudFormat.COL_SMOKE

@onready var background: ColorRect = %Background
@onready var title: Label = %Title
@onready var cause_block: Control = %CauseBlock
@onready var cause_label: Label = %CauseLabel
@onready var reason_label: Label = %ReasonLabel
@onready var grade_box: Control = %GradeBox
@onready var grade_letter: Label = %GradeLetter
@onready var header: ResultRow = %Header
@onready var top_speed_row: ResultRow = %TopSpeedRow
@onready var drift_row: ResultRow = %DriftRow
@onready var slipstream_row: ResultRow = %SlipstreamRow
@onready var near_miss_row: ResultRow = %NearMissRow
@onready var overtake_row: ResultRow = %OvertakeRow
@onready var other_row: ResultRow = %OtherRow
@onready var distance_row: ResultRow = %DistanceRow
@onready var time_row: ResultRow = %TimeRow
@onready var total_row: ResultRow = %TotalRow
@onready var footer: Control = %Footer
@onready var best_label: Label = %BestLabel
@onready var cash_label: Label = %CashLabel
@onready var buttons: Control = %Buttons
@onready var garage_button: Button = %GarageButton
@onready var restart_button: Button = %RestartButton

var _delay := 0.0 # real seconds since CRASHING began
var _t := 0.0 # real seconds since the sequence started
var _running := false
var _rows: Array[ResultRow] = [] # the visible table strips, top to bottom
# Schedule points that depend on how many strips are showing.
var _total_at := 0.0
var _stamp_at := 0.0
var _footer_at := 0.0
var _buttons_at := 0.0
var _end_at := 0.0

# Final values, captured once per crash.
var _final_score := 0
var _final_earned := 0
var _cash_before := 0 # garage cash before this run's rewards were banked
var _best_before := 0 # high score before this run

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	garage_button.pressed.connect(_on_garage_pressed)
	restart_button.pressed.connect(_on_restart_pressed)
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.current, GameState.current)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	match new_state:
		GameState.State.CRASHING:
			_delay = 0.0
			_running = false
			visible = false
			_capture_results()
		GameState.State.CRASHED:
			if old_state != GameState.State.CRASHING:
				# END RUN from pause: bank the pile first so the results include it.
				RunRewards.bank_pile()
				_capture_results()
				_start_sequence()
			elif not visible:
				_start_sequence()
			RunRewards.bank_run_rewards()
			get_tree().paused = true
		_:
			visible = false
			_running = false

func _capture_results() -> void:
	_final_score = int(RunRewards.score)
	_final_earned = RunRewards.run_cash_total()
	_cash_before = SaveData.game.garage.cash
	_best_before = SaveData.game.high_score

	# What ended the run (set by CrashSystem._trigger_crash). All empty when
	# the run was ended from the pause menu. (last_crash_detail is debug-only -
	# it still prints to the console, not shown here.)
	var crashed := CrashSystem.last_crash_cause != ""
	title.text = "CRASHED" if crashed else "RUN ENDED"
	title.add_theme_color_override("font_color", COL_TITLE_CRASH if crashed else COL_TITLE_ENDED)
	cause_label.text = CrashSystem.last_crash_cause
	cause_label.visible = crashed
	reason_label.text = CrashSystem.last_crash_reason
	reason_label.visible = CrashSystem.last_crash_reason != ""

	var grade := RunGrade.for_score(_final_score)
	grade_letter.text = grade.text
	grade_letter.add_theme_color_override("font_color", grade.color)

	var pts: Dictionary = RunRewards.category_points
	var secs: Dictionary = RunRewards.category_time
	var cash: Dictionary = RunRewards.category_cash()
	top_speed_row.set_values(secs["top_speed"], ResultRow.Amount.TIME, pts["top_speed"], cash["top_speed"], true)
	drift_row.set_values(secs["drift"], ResultRow.Amount.TIME, pts["drift"], cash["drift"], true)
	slipstream_row.set_values(secs["slipstream"], ResultRow.Amount.TIME, pts["slipstream"], cash["slipstream"], true)
	near_miss_row.set_values(RunRewards.near_miss_count, ResultRow.Amount.COUNT, pts["near_miss"], cash["near_miss"], true)
	overtake_row.set_values(RunRewards.overtake_count, ResultRow.Amount.COUNT, pts["overtake"], cash["overtake"], true)
	# Anything that scored outside the named stats (horn "MOVE!") - hidden when empty.
	other_row.visible = pts["other"] != 0 or cash["other"] != 0
	other_row.set_values(0.0, ResultRow.Amount.NONE, pts["other"], cash["other"], true)
	distance_row.set_values(RunRewards.current_distance / RoadMetrics.UNIT_SCALE / 1000.0, ResultRow.Amount.KM)
	time_row.set_values(RunRewards.run_time, ResultRow.Amount.TIME)
	total_row.set_values(0.0, ResultRow.Amount.NONE, _final_score, _final_earned, true)

func _start_sequence() -> void:
	_rows.clear()
	for row: ResultRow in [top_speed_row, drift_row, slipstream_row, near_miss_row, overtake_row, other_row, distance_row, time_row]:
		if row.visible:
			_rows.append(row)
	_total_at = T_ROWS + _rows.size() * ROW_STAGGER + TOTAL_GAP
	_stamp_at = _total_at + ROW_COUNT_DELAY + TOTAL_COUNT
	_footer_at = _total_at + FOOTER_AFTER_TOTAL
	_buttons_at = _footer_at + BUTTONS_AFTER_FOOTER
	_end_at = maxf(_stamp_at + GRADE_STAMP, _buttons_at + BLOCK_SLIDE)
	grade_letter.pivot_offset = grade_letter.size * 0.5
	_t = 0.0
	_running = true
	visible = true
	_apply(0.0)

func _process(delta: float) -> void:
	var real_delta := delta / maxf(Engine.time_scale, 0.001)

	if GameState.current == GameState.State.CRASHING and not visible:
		_delay += real_delta
		if _delay >= CrashSystem.CRASH_POPUP_DELAY:
			_start_sequence()
		return

	if _running:
		_t += real_delta
		_apply(_t)
		if _t >= _end_at:
			_running = false

## Poses every element for time `t` (real seconds into the sequence).
func _apply(t: float) -> void:
	background.modulate.a = clampf(t / DIM_FADE, 0.0, 1.0)
	_slide(title, t - T_TITLE, -1.0)
	_slide(cause_block, t - T_CAUSE, -1.0)
	_slide(grade_box, t - T_GRADE_BOX, 1.0)
	header.set_progress((t - T_HEADER) / ROW_SLIDE, 1.0)
	for i in _rows.size():
		var start := T_ROWS + i * ROW_STAGGER
		_rows[i].set_progress((t - start) / ROW_SLIDE, (t - start - ROW_COUNT_DELAY) / ROW_COUNT)
	var total_k := clampf((t - _total_at - ROW_COUNT_DELAY) / TOTAL_COUNT, 0.0, 1.0)
	total_row.set_progress((t - _total_at) / BLOCK_SLIDE, total_k)

	# Grade letter: hidden until TOTAL has counted, then drops in from oversized.
	var stamp := clampf((t - _stamp_at) / GRADE_STAMP, 0.0, 1.0)
	grade_letter.modulate.a = clampf(stamp * 3.0, 0.0, 1.0)
	grade_letter.scale = Vector2.ONE * lerpf(STAMP_SCALE, 1.0, ResultRow.ease_out_cubic(stamp))

	_slide(footer, t - _footer_at, -1.0)
	_slide(buttons, t - _buttons_at, 1.0)
	_show_wallet(ResultRow.ease_out_cubic(total_k))

## Slides a block in from the left (`dir` -1) or right (+1). Each block sits
## in its own slot Control in the scene, so its resting position is x = 0.
func _slide(block: Control, elapsed: float, dir: float) -> void:
	var k := clampf(elapsed / BLOCK_SLIDE, 0.0, 1.0)
	block.position.x = dir * SLIDE_DISTANCE * (1.0 - ResultRow.ease_out_back(k))
	block.modulate.a = clampf(k * 2.5, 0.0, 1.0)

## Best score + wallet, counting along with the TOTAL strip (`k` 0..1).
func _show_wallet(k: float) -> void:
	var score := int(round(_final_score * k))
	var earned := int(round(_final_earned * k))
	cash_label.text = "$%s TOTAL" % HudFormat.commas(_cash_before + earned)
	if _final_score > _best_before and k >= 1.0:
		best_label.text = "NEW BEST!"
	else:
		best_label.text = "BEST " + HudFormat.commas(maxi(_best_before, score))

func _input_live() -> bool:
	return visible and GameState.current == GameState.State.CRASHED and _t >= _buttons_at + BLOCK_SLIDE

func _unhandled_input(event: InputEvent) -> void:
	if _input_live() and event is InputEventKey and event.pressed and event.keycode == KEY_R:
		_on_restart_pressed()

func _on_garage_pressed() -> void:
	if not _input_live():
		return
	get_tree().paused = false
	GameState.set_state(GameState.State.GARAGE)

func _on_restart_pressed() -> void:
	if not _input_live():
		return
	get_tree().paused = false
	GameState.set_state(GameState.State.PLAYING)
