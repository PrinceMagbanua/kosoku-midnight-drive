extends CanvasLayer

## Live-play HUD overlay (transparent - the 3D scene renders behind it).
## Layout follows hud-layout-wireframe_4.html's "Live HUD" tab at 1024x600.
##
## This script only ROUTES data: it reads the game (RunRewards, CrashSystem,
## the "player_car" group's car.gd, the car's NitroBoost) and hands values to
## the element scenes in UI/hud/elements/, each of which is a separate .tscn
## instanced in LiveHud.tscn - so every piece can be dragged around in the
## editor. Nothing here reaches into an element's internals.
##
## ToastStack (centre of screen, empty) is reserved for the toast system that
## isn't built yet - overtakes, combo milestones, near-misses, scrapes.
##
## Attention (HudFlare): everything rests at 70% and flares only when it
## changes in a way that matters, so the HUD stays quiet over the road:
## - centre (pile popup, score feed): flare as they appear (their own scripts)
## - cluster (dial, nitro bottles, slow-mo arc): full while nitro/slow-mo
##   fires or the dial is at redline / an assist is lit; bottles flare when
##   one empties or refills. Speed/RPM alone never flare.
## - damage outline: flares on a hit, full while crashing
## - score/combo/cash: flare on bank, combo tier change, cash change
## - distance: flares each whole km. Buttons don't flare.
## Root's children are grouped by screen area (TopLeft, Centre, BottomLeft,
## Cluster, Chrome) so HudSway can move each by its own depth.

# RunRewards.current_distance is in this project's own engine units (see
# RoadMetrics.UNIT_SCALE, "units per metre") - divide by that to get real
# metres, then by 1000 for km.
const METRES_PER_UNIT := 1.0 / RoadMetrics.UNIT_SCALE
# Same speed conversion MISC/misc scripts/debug.gd uses for its KM/PH / MPH readout.
const KPH_PER_UNIT_SPEED := 1.10130592
const KM_PER_MILE := 1.609

const COUNT_TIME := 0.8 # score count-up duration after a bank
const SLIDE_TARGET_OFFSET := Vector2(40, 22) # where the sliding pile lands, relative to the score number's top-left
# The whole HUD clears out as the crash results screen slides in over it
# (crash_overlay.gd starts CrashSystem.CRASH_POPUP_DELAY into the crash).
const CRASH_FADE_TIME := 0.3 # real seconds

@export var crash_system_path: NodePath = NodePath("../CrashSystem")
@export var nitro_path: NodePath = NodePath("../car/NitroBoost")
@export var slowmo_path: NodePath = NodePath("../car/SlowMo")
@export var settings_menu_path: NodePath = NodePath("../debug/MenuList")

@onready var root: Control = $Root
@onready var score_display: ScoreDisplay = %ScoreDisplay
@onready var combo_display: Label = %ComboDisplay
@onready var cash_display: Label = %CashDisplay
@onready var distance_display: Label = %DistanceDisplay
@onready var pile_popup: PilePopup = %PilePopup
@onready var score_feed: ScoreFeed = %ScoreFeed

@onready var help_button: Button = %HelpButton
@onready var settings_button: Button = %SettingsButton
@onready var controls_widget: ControlsWidget = %ControlsWidget

@onready var damage_silhouette: DamageSilhouette = %DamageSilhouette
@onready var main_dial: MainDial = %MainDial
@onready var nitro_bottles: NitroBottles = %NitroBottles
@onready var slowmo_arc: SideArc = %SlowMoArc
@onready var hud_sway: HudSway = %HudSway

var _car: Node
var _crash_system: Node
var _nitro: Node
var _slowmo: Node

# Last shown values, so a flare fires only on a change.
var _last_combo_color := Color.TRANSPARENT
var _last_cash := -1
var _last_km := -1
var _crash_clock := 0.0 # real seconds since CRASHING began

func _ready() -> void:
	help_button.pressed.connect(controls_widget.toggle)
	settings_button.pressed.connect(_on_settings_pressed)
	RiskEvents.pile_updated.connect(_on_pile_updated)
	RiskEvents.pile_banked.connect(_on_pile_banked)
	RiskEvents.pile_lost.connect(_on_pile_lost)
	RiskEvents.drift_updated.connect(_on_drift_updated)
	RiskEvents.drift_ended.connect(_on_drift_ended)
	RiskEvents.high_speed_updated.connect(_on_high_speed_updated)
	RiskEvents.high_speed_ended.connect(_on_high_speed_ended)
	RiskEvents.slipstream_updated.connect(_on_slipstream_updated)
	RiskEvents.slipstream_ended.connect(_on_slipstream_ended)
	damage_silhouette.hit.connect(func(): HudFlare.flare(damage_silhouette))
	nitro_bottles.bottle_changed.connect(func(): HudFlare.flare(nitro_bottles))
	for ci in [score_display, combo_display, cash_display, distance_display, damage_silhouette, main_dial, nitro_bottles, slowmo_arc]:
		HudFlare.rest(ci)
	GameState.state_changed.connect(_on_state_changed)
	_on_state_changed(GameState.current, GameState.current)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	visible = new_state in [GameState.State.PLAYING, GameState.State.CRASHING, GameState.State.CRASHED]
	if new_state == GameState.State.PLAYING and old_state != GameState.State.PAUSED:
		pile_popup.hide_now()
		score_feed.clear()
		_live_drift = ""
		_live_slipstream = ""
		_live_speed = ""
		score_display.reset()
	HudFlare.hold(damage_silhouette, new_state in [GameState.State.CRASHING, GameState.State.CRASHED])
	# CRASHING fades the HUD out in _process; END RUN jumps straight to CRASHED
	# with the tree paused, so it's cleared at once there.
	_crash_clock = 0.0
	root.modulate.a = 0.0 if new_state == GameState.State.CRASHED else 1.0

# --- combo pile ---------------------------------------------------------

func _on_pile_updated(pile_total: float, added: int, multiplier: float, _streak: int, reason: String) -> void:
	pile_popup.show_pile(int(pile_total), added, multiplier, reason)
	if added > 0:
		score_feed.add_event(reason, added, HudFormat.combo_color(multiplier))
	elif reason == "COMBO BROKEN":
		score_feed.add_event(reason, 0, HudFormat.COL_DANGER)

func _on_pile_banked(amount: int) -> void:
	# The pile flies to wherever the score number currently is on screen, then
	# the number counts up from what it shows now to the new banked total.
	pile_popup.slide_to(score_display.value_global_position() + SLIDE_TARGET_OFFSET)
	var from: float = score_display.shown_value() if score_display.is_animating() else RunRewards.score - amount
	score_display.count_up(from, RunRewards.score, PilePopup.SLIDE_TIME, COUNT_TIME)
	HudFlare.flare(score_display)

func _on_pile_lost(_amount: int) -> void:
	pile_popup.show_lost()

# --- score feed live line (drift / slipstream / top speed) ---------------

# The feed's top line shows whichever session is building; a drift wins, then
# a slipstream, then a top-speed run - the one the player is most actively
# working comes first.
var _live_drift := ""
var _live_slipstream := ""
var _live_speed := ""

func _on_drift_updated(points: float, duration_mult: float, prox_mult: float, prox_reason: String, _angle: float) -> void:
	_live_drift = "DRIFT  %s  ×%s" % [HudFormat.commas(int(points)), HudFormat.mult_text(duration_mult)]
	if prox_mult > 1.0:
		_live_drift += "  %s×%s" % [prox_reason, HudFormat.mult_text(prox_mult)]
	_refresh_live()

func _on_drift_ended(_landed: int, _reason: String) -> void:
	_live_drift = "" # a landed drift shows up as its own line via pile_updated
	_refresh_live()

func _on_high_speed_updated(seconds: float) -> void:
	_live_speed = "TOP SPEED  %ds" % int(seconds)
	_refresh_live()

func _on_high_speed_ended() -> void:
	_live_speed = ""
	_refresh_live()

## Charge as a percentage while it builds, "READY" once it's full (swing out).
func _on_slipstream_updated(charge: float, _seconds: float) -> void:
	_live_slipstream = "SLIPSTREAM  READY" if charge >= 1.0 else "SLIPSTREAM  %d%%" % int(charge * 100.0)
	_refresh_live()

func _on_slipstream_ended() -> void:
	_live_slipstream = ""
	_refresh_live()

func _refresh_live() -> void:
	if _live_drift != "":
		score_feed.set_live(_live_drift)
	elif _live_slipstream != "":
		score_feed.set_live(_live_slipstream)
	else:
		score_feed.set_live(_live_speed)

## Opens the dev/settings dropdown that used to hang off the old debug
## overlay's own gear (graphics/audio/controls). That
## overlay is still in the scene - its readouts are hidden, not deleted,
## since camera.gd and debug.gd still read from it. Esc still pauses.
func _on_settings_pressed() -> void:
	var menu := get_node_or_null(settings_menu_path) as Control
	if menu:
		menu.visible = not menu.visible

func _process(delta: float) -> void:
	if not visible:
		return
	if GameState.current == GameState.State.CRASHING:
		_crash_clock += delta / maxf(Engine.time_scale, 0.001)
		root.modulate.a = 1.0 - clampf((_crash_clock - CrashSystem.CRASH_POPUP_DELAY) / CRASH_FADE_TIME, 0.0, 1.0)
	_update_run_stats()
	_update_damage()
	_update_car(delta)
	_update_nitro()
	_update_slowmo()

# --- upper-left stack ---------------------------------------------------

func _update_run_stats() -> void:
	score_display.sync_to(RunRewards.score)
	combo_display.text = HudFormat.mult_text(RunRewards.combo_multiplier) + "×"
	var combo_col := HudFormat.combo_color(RunRewards.combo_multiplier)
	if combo_col != _last_combo_color:
		if _last_combo_color.a > 0.0:
			HudFlare.flare(combo_display)
		_last_combo_color = combo_col
		combo_display.add_theme_color_override("font_color", combo_col)

	var cash: int = SaveData.game.garage.cash + RunRewards.run_cash_earned
	if cash != _last_cash:
		if _last_cash >= 0:
			HudFlare.flare(cash_display)
		_last_cash = cash
		cash_display.text = "$" + HudFormat.commas(cash)

	var km: float = RunRewards.current_distance * METRES_PER_UNIT / 1000.0
	distance_display.text = "%.2f km" % km
	if int(km) != _last_km:
		if _last_km >= 0 and int(km) > _last_km:
			HudFlare.flare(distance_display)
		_last_km = int(km)

# --- lower-left damage outline -----------------------------------------

func _update_damage() -> void:
	if not is_instance_valid(_crash_system):
		_crash_system = get_node_or_null(crash_system_path)
		if _crash_system == null:
			return
		hud_sway.crash_system = _crash_system
	var dmg: CarDamageModel = _crash_system.damage
	damage_silhouette.show_damage(dmg.piece_fracs(), dmg.chassis_frac())
	main_dial.show_health(dmg.chassis_frac()) # tints the dial red as the car wears out

# --- gauge cluster + pedals ---------------------------------------------

func _update_car(delta: float) -> void:
	if not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("player_car")
		if _car == null:
			return

	var mph: float = _car.linear_velocity.length() * KPH_PER_UNIT_SPEED / KM_PER_MILE
	var abs_on: bool = _car.abspump > 0.0 and _car.brakepedal > 0.1
	main_dial.show_car(
		_car.rpm, _car.RPMLimit, mph, _gear_text(),
		abs_on, _car.tcsflash, _car.espflash, delta)
	var redline: float = floorf(_car.RPMLimit / 1000.0) * 1000.0
	var nitro_firing: bool = is_instance_valid(_nitro) and _nitro.is_active()
	HudFlare.hold(main_dial, nitro_firing or abs_on or _car.tcsflash or _car.espflash or (redline > 0.0 and _car.rpm >= redline))

## N2O: the tank split into 2 + nitroFuel-level bottles.
## The bottle row under the dial shows them all; the dial's outer arc shows
## the one in use and flashes while firing. Hidden without the nitro upgrade.
func _update_nitro() -> void:
	if not is_instance_valid(_nitro):
		_nitro = get_node_or_null(nitro_path)
	var has_nitro: bool = _nitro != null and SaveData.get_upgrade_tier("nitro") > 0
	nitro_bottles.visible = has_nitro
	if not has_nitro:
		main_dial.show_nitro(false, 0.0, false)
		return
	var count: int = 2 + SaveData.get_upgrade_tier("nitroFuel")
	var fuel: float = _nitro.get_fuel()
	nitro_bottles.count = count
	nitro_bottles.value = fuel
	HudFlare.hold(nitro_bottles, _nitro.is_active())
	# Level inside the bottle in use: a full tank reads as a full bottle.
	var x := fuel * count
	var in_use := ceilf(x - 0.001)
	main_dial.show_nitro(true, x - (in_use - 1.0) if in_use > 0.0 else 0.0, _nitro.is_active())

## Slow-mo arc on the dial's left. Hidden without the SPEEDBREAKER upgrade.
func _update_slowmo() -> void:
	if not is_instance_valid(_slowmo):
		_slowmo = get_node_or_null(slowmo_path)
	var has_slowmo: bool = _slowmo != null and SaveData.get_upgrade_tier("slowmo") > 0
	slowmo_arc.visible = has_slowmo
	if has_slowmo:
		slowmo_arc.value = _slowmo.get_fuel()
		HudFlare.hold(slowmo_arc, _slowmo.get_amount() > 0.0)

func _gear_text() -> String:
	var gear: int = _car.gear
	if gear == 0:
		return "N"
	if gear == -1:
		return "R"
	if _car.TransmissionType == 1 or _car.TransmissionType == 2:
		return "D"
	return str(gear)
