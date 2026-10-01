extends Node

## Live run state (distance/score/combo/cash-earned) + banking whatever a
## finished run earned into SaveData. Godot equivalent of Voxel Driver's
## `score`/`comboMultiplier`/`runCashEarned` globals (main.js/hud-crash.js)
## plus bankRunRewards() (hud-crash.js:548-562).
##
## COMBO PILE: risk events (RiskEvents.near_miss / overtake) don't add to
## `score` directly - they add to `pile`. Every event also extends a streak
## (combo multiplier = 1 + streak * COMBO_STEP, capped at COMBO_CAP) and
## resets a CHAIN_TIME timer. When the timer runs out the pile is BANKED into
## `score` and the streak resets; a crash (CRASHING) BANKS it too (the run
## keeps what it earned - only the chain/multiplier end). A
## non-fatal collision only resets the streak - the pile stays and keeps its
## timer. Checkpoints/ending a run on purpose bank it via bank_pile().
##
## Event points = base * multiplier * (speed / reference max), x1.5 while
## nitro is boosting. The timer is counted in _physics_process (scaled game
## time), so it freezes on pause and will freeze under Time Stop too.
##
## NOT ported yet (see plan doc step 6): swerve/snake chains, tailgating
## trickle, dodge-on-lane-change scoring, hazard
## dodges, biome/weather score multipliers. `run_cash_earned` stays 0 for now
## since its only real sources (overtake coins, sustained-speed cash) aren't
## ported.

const CASH_CONVERSION_RATE := 0.035 # core.js:307

const CHAIN_TIME := 3.0 # seconds - every event refreshes this
const COMBO_STEP := 0.2 # multiplier gained per streak event
const COMBO_CAP := 10.0
const NITRO_POINTS_MULT := 1.5
const MIN_SPEED_FACTOR := 0.1 # floor on speed/max so a crawl still scores a little
const MAX_SPEED_FACTOR := 1.5

const BASE_NEAR_MISS_CLOSE := 25.0
const BASE_NEAR_MISS_HAIRLINE := 50.0
const BASE_NEAR_MISS_IMPOSSIBLE := 100.0
const BASE_OVERTAKE := 10.0

var current_distance: float = 0.0
var score: float = 0.0 # banked score only - the unbanked part is `pile`
var pile: float = 0.0
var combo_streak: int = 0
var combo_multiplier: float = 1.0
var chain_timer: float = 0.0
var near_miss_count: int = 0
var overtake_count: int = 0
var run_cash_earned: int = 0
## Per-run breakdown for the crash screen's results table (crash_overlay.gd).
## Every point enters the pile through register_score_event()/register_drift()
## and the pile is always banked, so `category_points` sums to `score` once the
## run is over. `category_time` is seconds spent doing each thing (added by
## the scorers through add_time()); `run_time` is seconds driven, intro excluded.
const CATEGORIES := ["top_speed", "drift", "slipstream", "near_miss", "overtake", "other"]
const REASON_CATEGORY := {
	"TOP SPEED": "top_speed",
	"NEAR MISS": "near_miss",
	"HAIRLINE!": "near_miss",
	"IMPOSSIBLE!!": "near_miss",
	"OVERTAKE": "overtake",
	"SLIPSTREAM": "slipstream",
	"SLINGSHOT": "slipstream",
	"DRIFT": "drift",
	"SPUN OUT": "drift",
}
var category_points := {}
var category_time := {}
var run_time: float = 0.0
## Set by DriftScorer / HighSpeedScorer / SlipstreamScorer while their session
## is live - holds the chain timer so events before and after one session link
## into the same combo.
var drift_active := false
var high_speed_active := false
var slipstream_active := false

var _start_dist: float = 0.0

func _ready() -> void:
	_clear_breakdown()
	GameState.state_changed.connect(_on_state_changed)
	RiskEvents.near_miss.connect(register_near_miss)
	RiskEvents.overtake.connect(register_overtake)
	RiskEvents.collision.connect(break_combo)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state == GameState.State.PLAYING and old_state != GameState.State.PAUSED:
		_start_dist = _road_dist()
		current_distance = 0.0
		score = 0.0
		_clear_chain()
		near_miss_count = 0
		overtake_count = 0
		run_cash_earned = 0
		run_time = 0.0
		_clear_breakdown()
	elif new_state == GameState.State.CRASHING:
		bank_pile()

## The road now curves - "distance traveled" has to be arc-length along the
## path (RoadGenerator's own PathTracker), not raw world Z (valid only back
## when the road was straight, where dist WAS z). Falls back to raw Z if
## RoadGenerator/its tracker isn't found for any reason (shouldn't happen
## in normal play, but this autoload has no guaranteed NodePath into
## world.tscn's tree, so it looks the nodes up itself - once, and again only
## if they go away, e.g. a scene change).
var _road_gen: Node
var _player: Node3D

## Marks where the car is NOW as the run's 0 km. Called by run_reset.gd once
## the car is parked at the new run's start and the road is rebuilt around it.
func mark_run_start() -> void:
	_start_dist = _road_dist()
	current_distance = 0.0

func _player_car() -> Node3D:
	if not is_instance_valid(_player):
		_player = get_tree().get_first_node_in_group("player_car") as Node3D
	return _player

func _road_dist() -> float:
	if not is_instance_valid(_road_gen):
		var scene: Node = get_tree().current_scene
		_road_gen = scene.get_node_or_null("RoadGenerator") if scene else null
	var rg := _road_gen
	if rg and "tracker" in rg and rg.tracker:
		return rg.tracker.dist
	var car := _player_car()
	return car.global_position.z if car else 0.0

func _physics_process(delta: float) -> void:
	if GameState.current != GameState.State.PLAYING:
		return
	current_distance = maxf(0.0, _road_dist() - _start_dist)
	if not IntroPan.playing:
		run_time += delta
	if chain_timer > 0.0 and not (drift_active or high_speed_active or slipstream_active):
		chain_timer -= delta
		if chain_timer <= 0.0:
			bank_pile()

## Fraction of the chain timer left (1 = just refreshed, 0 = about to bank).
func chain_fraction() -> float:
	return clampf(chain_timer / CHAIN_TIME, 0.0, 1.0)

## Adds one event's points to the pile, extends the streak (unless
## `add_streak` is false - HighSpeedScorer, so just cruising can't climb the
## multiplier), refreshes the chain timer. Returns the points added.
func register_score_event(base_points: float, speed_pct: float, reason: String = "", add_streak := true) -> int:
	var speed_factor: float = clampf(speed_pct, MIN_SPEED_FACTOR, MAX_SPEED_FACTOR)
	var pts: int = int(round(base_points * combo_multiplier * speed_factor * nitro_points_mult()))
	pile += pts
	_add_category_points(reason, pts)
	if add_streak:
		combo_streak += 1
		combo_multiplier = minf(COMBO_CAP, 1.0 + float(combo_streak) * COMBO_STEP)
	chain_timer = CHAIN_TIME
	RiskEvents.pile_updated.emit(pile, pts, combo_multiplier, combo_streak, reason)
	return pts

func register_near_miss(speed_pct: float, tier: int = 0) -> void:
	match tier:
		RiskEvents.NearMissTier.IMPOSSIBLE:
			register_score_event(BASE_NEAR_MISS_IMPOSSIBLE, speed_pct, "IMPOSSIBLE!!")
		RiskEvents.NearMissTier.HAIRLINE:
			register_score_event(BASE_NEAR_MISS_HAIRLINE, speed_pct, "HAIRLINE!")
		_:
			register_score_event(BASE_NEAR_MISS_CLOSE, speed_pct, "NEAR MISS")
	near_miss_count += 1

func register_overtake(speed_pct: float) -> void:
	register_score_event(BASE_OVERTAKE, speed_pct, "OVERTAKE")
	overtake_count += 1

## A finished drift session lands as ONE event. `points` already has speed,
## angle, duration, proximity and nitro baked in (DriftScorer), so only the
## combo multiplier is applied here. Returns the points added.
func register_drift(points: float, reason: String = "DRIFT") -> int:
	var pts: int = int(round(points * combo_multiplier))
	pile += pts
	_add_category_points(reason, pts)
	combo_streak += 1
	combo_multiplier = minf(COMBO_CAP, 1.0 + float(combo_streak) * COMBO_STEP)
	chain_timer = CHAIN_TIME
	RiskEvents.pile_updated.emit(pile, pts, combo_multiplier, combo_streak, reason)
	return pts

## Called on any collision - resets the streak/multiplier immediately. The
## pile itself survives (only a crash loses it) and keeps its chain timer.
func break_combo() -> void:
	if combo_streak == 0:
		return
	combo_streak = 0
	combo_multiplier = 1.0
	RiskEvents.pile_updated.emit(pile, 0, combo_multiplier, combo_streak, "COMBO BROKEN")

## Moves the pile into `score` and ends the chain. Also used by checkpoints
## and by ending a run on purpose.
func bank_pile() -> void:
	var amount := int(round(pile))
	_clear_chain()
	if amount > 0:
		score += amount
		RiskEvents.pile_banked.emit(amount)

func _lose_pile() -> void:
	var amount := int(round(pile))
	_clear_chain()
	if amount > 0:
		RiskEvents.pile_lost.emit(amount)

func _clear_chain() -> void:
	pile = 0.0
	combo_streak = 0
	combo_multiplier = 1.0
	chain_timer = 0.0

func _clear_breakdown() -> void:
	for c in CATEGORIES:
		category_points[c] = 0
		category_time[c] = 0.0

func _add_category_points(reason: String, pts: int) -> void:
	var c: String = REASON_CATEGORY.get(reason, "other")
	category_points[c] = int(category_points.get(c, 0)) + pts

## Seconds spent in `category` this run (called every tick by its scorer).
func add_time(category: String, delta: float) -> void:
	category_time[category] = float(category_time.get(category, 0.0)) + delta

## The run's cash split per category, summing exactly to run_cash_total():
## each category's score converted on its own, with the rounding remainder
## (and any direct `run_cash_earned`) put on the biggest earner.
func category_cash() -> Dictionary:
	var out := {}
	var sum := 0
	var biggest := "other"
	for c in CATEGORIES:
		var pts := int(category_points.get(c, 0))
		out[c] = int(round(pts * CASH_CONVERSION_RATE))
		sum += out[c]
		if pts > int(category_points.get(biggest, 0)):
			biggest = c
	out[biggest] += run_cash_total() - sum
	return out

func nitro_points_mult() -> float:
	var car := _player_car()
	var nitro: Node = car.get_node_or_null(NodePath("NitroBoost")) if car else null
	if nitro and nitro.get_power() > 0.0:
		return NITRO_POINTS_MULT
	return 1.0

## Cash this run is worth once banked (direct earnings + score conversion).
## Exposed so the crash popup can count up to it before banking happens.
func run_cash_total() -> int:
	return run_cash_earned + int(round(score * CASH_CONVERSION_RATE))

func bank_run_rewards() -> void:
	bank_pile()
	if current_distance > SaveData.game.garage.furthest_dist:
		SaveData.game.garage.furthest_dist = current_distance
	SaveData.game.garage.cash += run_cash_total()
	if int(score) > SaveData.game.high_score:
		SaveData.game.high_score = int(score)
	SaveData.save()
