class_name IntroPan
extends Node

## Start-of-run sequence: a short cinematic of the car while it sits in
## Neutral - ONE eased camera sweep (INTRO_TIME real seconds) from low in
## front of the nose, round one side, settling exactly into the gameplay
## camera behind the player. Throughout, the player can rev the engine (gas only - every
## other drive input stays suppressed), and the car is held in Neutral. The
## instant the move finishes it drops into gear 1 / Drive, physics is handed
## back, and full control unlocks. (This replaces the old coloured countdown
## band + "GO!" overlay.)
##
## Path: a single orbit arc in car-local polar space (+Z forward, +X left, +Y
## up - so it works wherever the road puts the car): angle round the car,
## distance from it and height are each interpolated from START_LOCAL to the
## gameplay camera's pose. One curve, no spline knots, so the speed never
## changes mid-move (the old multi-point spline lurched where segments met).
## The whole move is eased with smootherstep. The gameplay camera's pose is
## read live for the first END_CAPTURE_TIME (the chase cam needs a frame or
## two to settle after snap_to_car()) and then frozen - the car is frozen for
## the intro, so it can't go stale, and a fixed target can't wobble. The
## camera looks at the car the whole way, blending
## into the gameplay camera's own rotation/FOV over the last stretch - so it
## ends on the chase cam (or the cockpit cam, if that's the active view) with
## no pop. A temporary Camera3D is made current for the sequence, copying the
## gameplay camera's render settings.
##
## Input: CarInputLock.suppress_input() releases every drive action except gas
## (REV_ACTIONS), so revving still works. Neutral is held by forcing car.gd's
## gear/actualgear to 0 each tick and keeping its auto-engage counter
## (sassistdel - "hold gas in N for 60 ticks => gear 1") from ever running out.
## Suppressing input rather than disabling car.gd matters - see CarInputLock.
##
## run_reset.gd freezes the car's RigidBody3D for a fresh run (otherwise gravity
## would move it during the intro); this unfreezes it when the sequence ends.
##
## Same trigger run_reset.gd/RunRewards/CrashSystem already use for "a fresh
## run is starting, not resuming from pause": `new_state == PLAYING and
## old_state != PAUSED`.
##
## IntroPan.playing is true for the whole cinematic - nitro_boost.gd and
## slow_mo.gd check it so neither can be used before control unlocks. When
## control unlocks, SFX_GO_PATH plays (a single high start-light beep, no voice).

@export var cam_chase_path: NodePath = NodePath("../cam_chase")
@export var car_path: NodePath = NodePath("../car")

const INTRO_TIME := 5.0 # seconds for the whole move
const CINE_FOV := 55.0
const REV_ACTIONS := ["gas", "gas_mouse"] # left live during the intro so you can rev

## Where the sweep starts, car-local (RoadMetrics.UNIT_SCALE ~3.27 per metre;
## the car is roughly 5.5 wide x 8.4 long): low, just off the nose. It swings
## round the +X side (the side this point is on) to the gameplay camera.
const START_LOCAL := Vector3(4.0, 1.4, 12.0)
## Real seconds the gameplay camera's pose is read live before being frozen.
const END_CAPTURE_TIME := 0.3
const LOOK_AT := Vector3(0.0, 1.2, 0.5) # car-local point the camera watches
## Fraction of the move (0..1) where rotation/FOV start blending into the
## gameplay camera's own.
const HANDOFF_START := 0.65
const SFX_GO_PATH := "res://MAIN/sfx/race-go.wav"
const SFX_GO_VOLUME := 0.3 # linear, fraction of its SFX-slider level

## True while the start cinematic is running (see header).
static var playing := false

var _active := false
var _elapsed := 0.0
var _cine_cam: Camera3D
var _game_cam: Camera3D # the camera to hand back to at the end
var _end_local := Transform3D() # gameplay camera pose, car-local
var _end_fov := CINE_FOV

func _ready() -> void:
	GameState.state_changed.connect(_on_state_changed)

func _exit_tree() -> void:
	playing = false # static - don't leave it stuck if the scene goes mid-intro

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	if new_state == GameState.State.PLAYING and old_state != GameState.State.PAUSED:
		_start_intro()
	elif _active and new_state != GameState.State.PLAYING and new_state != GameState.State.PAUSED:
		# Left the run mid-intro (e.g. straight to the garage).
		_finish(false)

func _start_intro() -> void:
	var cam: Node = get_node_or_null(cam_chase_path)
	if cam:
		# camera.gd's manual orbit/zoom controls leave these wherever the
		# player last put them - reset so every run ends straight behind
		# the car at the normal distance.
		var orbit: Node = cam.get_node_or_null("orbit")
		if orbit:
			orbit.rotation_degrees.y = 0.0
		cam.default_cam_pos.z = cam.default_zoom
		cam.snap_to_car()
	_game_cam = get_viewport().get_camera_3d()
	if _cine_cam == null:
		_cine_cam = Camera3D.new()
		_cine_cam.name = "IntroCinematicCamera"
		add_child(_cine_cam)
	if _game_cam:
		_cine_cam.cull_mask = _game_cam.cull_mask
		_cine_cam.near = _game_cam.near
		_cine_cam.far = _game_cam.far
		_cine_cam.environment = _game_cam.environment
		_cine_cam.attributes = _game_cam.attributes
		_cine_cam.doppler_tracking = _game_cam.doppler_tracking
	_elapsed = 0.0
	_active = true
	playing = true
	_update_camera()
	_cine_cam.make_current()

func _process(delta: float) -> void:
	# Held at its first frame while the loading screen covers the start (its
	# warm-up camera is current then) - the sweep plays once it lifts.
	if not _active or LoadingScreen.busy:
		return
	_elapsed += delta
	_update_camera()

func _physics_process(_delta: float) -> void:
	if not _active:
		return
	var car: Node = get_node_or_null(car_path)
	# No revving behind the loading screen either.
	CarInputLock.suppress_input([] if LoadingScreen.busy else REV_ACTIONS)
	if car:
		car.gear = 0
		car.actualgear = 0
		car.sassistdel = 60
	if _elapsed >= INTRO_TIME:
		_finish(true)

func _update_camera() -> void:
	var car: Node3D = get_node_or_null(car_path)
	if car == null or _cine_cam == null:
		return
	var xf := car.global_transform
	var t := clampf(_elapsed / INTRO_TIME, 0.0, 1.0)
	var u := t * t * t * (t * (t * 6.0 - 15.0) + 10.0) # smootherstep

	var has_game := is_instance_valid(_game_cam)
	if has_game and _elapsed < END_CAPTURE_TIME:
		_end_local = xf.affine_inverse() * _game_cam.global_transform.orthonormalized()
		_end_fov = _game_cam.fov
	var end_pos: Vector3 = _end_local.origin if has_game else Vector3(0.0, 3.0, -12.0)

	# Polar arc: angle about the car's up axis (0 = straight ahead), distance
	# in the ground plane, and height - each lerped on its own.
	var a0 := atan2(START_LOCAL.x, START_LOCAL.z)
	var a1 := atan2(end_pos.x, end_pos.z)
	a1 = a0 + fposmod(a1 - a0, TAU) # always swing the same way round (+X side)
	var r0 := Vector2(START_LOCAL.x, START_LOCAL.z).length()
	var r1 := Vector2(end_pos.x, end_pos.z).length()
	var ang := lerpf(a0, a1, u)
	var r := lerpf(r0, r1, u)
	var local_pos := Vector3(sin(ang) * r, lerpf(START_LOCAL.y, end_pos.y, u), cos(ang) * r)

	var look := _look_from(xf * local_pos, xf * LOOK_AT)
	var w := smoothstep(HANDOFF_START, 1.0, u)
	if has_game:
		var target_basis: Basis = (xf.basis * _end_local.basis).orthonormalized()
		look.basis = look.basis.slerp(target_basis, w)
		_cine_cam.fov = lerpf(CINE_FOV, _end_fov, w)
	else:
		_cine_cam.fov = CINE_FOV
	_cine_cam.global_transform = look

func _look_from(from: Vector3, target: Vector3) -> Transform3D:
	return Transform3D(Basis.IDENTITY, from).looking_at(target, Vector3.UP)

## `drive` = the intro played out: drop into gear 1 and hand control back.
## false = the run was left mid-intro; just clean up.
func _finish(drive: bool) -> void:
	_active = false
	playing = false
	if drive:
		_play_go()
	var car: RigidBody3D = get_node_or_null(car_path)
	if car:
		if drive:
			car.actualgear = 1
			car.gear = 1
			# Full-auto assist drops back to N when stopped off-gas, then needs
			# 60 ticks of gas to re-engage - make that instant for the launch.
			car.sassistdel = 0
		car.freeze = false
	# Give the view back - unless the player already switched cameras.
	if _cine_cam and _cine_cam.current and is_instance_valid(_game_cam):
		_game_cam.make_current()

func _play_go() -> void:
	var stream := load(SFX_GO_PATH) as AudioStream
	if stream == null:
		push_warning("IntroPan: couldn't load %s" % SFX_GO_PATH)
		return
	var p := AudioStreamPlayer.new()
	p.stream = stream
	p.volume_db = linear_to_db(clampf(misc_graphics_settings.sfx_volume * misc_graphics_settings.master_volume, 0.0001,0.2) * SFX_GO_VOLUME)
	p.finished.connect(p.queue_free)
	add_child(p)
	p.play()
