class_name Horn
extends Node

## Horn + high-beam flash on one key (`horn`, H) - port of the original's
## triggerHonk() (Voxel Driver input.js). Pressing it: the horn loops while
## the key is held (the original's hold-to-loop horn, sample extracted from
## its audio-data.js), the headlights double-blink (headlight_lights.gd
## flash()), and the nearest car ahead in your lane is told to signal and
## move over if a neighbouring lane is clear (TrafficManager.request_yield).
## A car moving over scores "MOVE!" (MOVE_POINTS base, like any combo event),
## at most once per MOVE_COOLDOWN so horn spam can't farm it.
##
## Reach is a fixed BASE_REACH (the original's HORN RANGE upgrade was dropped
## from the shop).
##
## Each car has its own horn, MAIN/sfx/horns/<car id>.wav (bass-heavy loops
## synthesised offline - dual/triple disc tones, treble rolled off), falling
## back to the original horn.wav. Like a real horn it winds up: pitch starts
## WINDUP_FROM low and rises over WINDUP_TIME while the volume attacks, and
## sags a little as it's released.

const HORN_SFX_PATH := "res://MAIN/sfx/horn.wav"
const CAR_HORN_PATH := "res://MAIN/sfx/horns/%s.wav"
const WINDUP_FROM := 0.78 # pitch_scale at the instant of pressing
const WINDUP_TIME := 0.14
const ATTACK_TIME := 0.05
const RELEASE_PITCH := 0.93 # pitch it sags to while fading out
const HORN_VOLUME := 0.55 # linear, fraction of SFX volume (the original's gain)
const BASE_REACH := 28.0 * RoadMetrics.UNIT_SCALE # metres ahead, per the original
const MOVE_POINTS := 15.0
const MOVE_COOLDOWN := 1.2
const FADE_OUT := 0.12 # seconds - release fade so the loop doesn't click off

@export var car_path: NodePath = NodePath("../car")
@export var traffic_manager_path: NodePath = NodePath("../TrafficManager")

var _player: AudioStreamPlayer
var _fade: Tween
var _windup: Tween
var _move_cooldown := 0.0

func _ready() -> void:
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_load_horn()
	GameState.state_changed.connect(_on_state_changed)
	SaveData.selected_car_changed.connect(func(_i: int) -> void: _load_horn())

## The selected car's horn (or the original one if it has none), as a loop.
func _load_horn() -> void:
	var car_id: String = CarCatalog.get_profile(SaveData.get_selected_car_index()).id
	var path: String = CAR_HORN_PATH % car_id
	if not ResourceLoader.exists(path):
		path = HORN_SFX_PATH
	var wav := load(path) as AudioStreamWAV
	if wav == null:
		push_warning("Horn: couldn't load %s" % path)
		return
	var stream: AudioStreamWAV = wav.duplicate()
	stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	stream.loop_begin = 0
	stream.loop_end = int(stream.get_length() * stream.mix_rate)
	_player.stop()
	_player.stream = stream

func _on_state_changed(new_state: GameState.State, _old_state: GameState.State) -> void:
	if new_state == GameState.State.PLAYING:
		_load_horn() # the car may have changed in the garage
	else:
		_stop()

func _physics_process(delta: float) -> void:
	_move_cooldown = maxf(0.0, _move_cooldown - delta)
	if GameState.current != GameState.State.PLAYING or IntroPan.playing:
		return
	if Input.is_action_just_pressed("horn"):
		_honk()
	elif Input.is_action_just_released("horn"):
		_stop()
	var busy: bool = (_fade != null and _fade.is_running()) or (_windup != null and _windup.is_running())
	if _player.playing and not busy:
		_player.volume_db = _volume_db() # sliders apply live while held

func _honk() -> void:
	if _fade:
		_fade.kill()
	if _windup:
		_windup.kill()
	if _player.stream:
		# Wind up from low pitch and quiet, like a horn's diaphragm spinning up.
		if not _player.playing:
			_player.pitch_scale = WINDUP_FROM
			_player.volume_db = _volume_db() - 18.0
			_player.play()
		_windup = create_tween().set_ignore_time_scale(true).set_parallel(true)
		_windup.tween_property(_player, "pitch_scale", 1.0, WINDUP_TIME).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_windup.tween_property(_player, "volume_db", _volume_db(), ATTACK_TIME)
	var car: Node = get_node_or_null(car_path)
	if car:
		var lights: Node = car.get_node_or_null("HullHeadlights")
		if lights and lights.has_method("flash"):
			lights.flash()
	var tm: Node = get_node_or_null(traffic_manager_path)
	if tm == null:
		return
	if tm.request_yield(BASE_REACH) and _move_cooldown <= 0.0:
		_move_cooldown = MOVE_COOLDOWN
		var speed: float = (car as RigidBody3D).linear_velocity.length() if car else 0.0
		RunRewards.register_score_event(MOVE_POINTS, speed / CrashSystem.REFERENCE_MAX_SPEED, "MOVE!")

func _stop() -> void:
	if not _player.playing:
		return
	if _fade:
		_fade.kill()
	if _windup:
		_windup.kill()
	_fade = create_tween().set_ignore_time_scale(true).set_parallel(true)
	_fade.tween_property(_player, "volume_db", -60.0, FADE_OUT)
	_fade.tween_property(_player, "pitch_scale", RELEASE_PITCH, FADE_OUT)
	_fade.chain().tween_callback(_player.stop)

func _volume_db() -> float:
	return linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume * HORN_VOLUME, 0.0001, 1.0))
