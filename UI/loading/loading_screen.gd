class_name LoadingScreen
extends CanvasLayer

## Loading screen for starting a drive from the main menu or the garage
## (start_screen.gd / garage_screen.gd call LoadingScreen.enter_drive()).
## Restarts after a crash and pause -> resume don't use it, and neither does
## leaving the drive for the garage.
##
## Sequence: fade to black -> KŌSOKU wordmark (upper left) and the animated
## car (loading_car.gd, lower right) fade in -> the run starts behind it
## (GameState -> PLAYING: road + traffic rebuilt) -> shader warm-up -> the car
## launches off screen -> fade out onto the start cinematic.
##
## Why the warm-up: the first time a material is drawn its shader compiles,
## which stalls that frame (the lag right after DRIVE, and the one-off hitches
## at the first tunnel / bridge). Behind the black screen a temporary camera
## looks around the start area, then visits the run's first tunnel of each
## style, first sea bridge (with the sea) and first overpass - building those
## chunks just for the shot and freeing them after - so all of that compiles
## here instead of mid-drive. IntroPan holds its cinematic while `busy`.
##
## No autoload needed: the first enter_drive() creates the node under /root.

const FADE_TO_BLACK := 0.45
const CONTENT_FADE_IN := 0.35
const FADE_OUT := 0.6
const LAUNCH_TIME := 0.55 # car floors it off screen before the fade out
const MIN_SHOW_MS := 1800 # the screen stays at least this long, however fast the load
const WARM_FRAMES := 2 # frames rendered per warm-up shot
const WARM_FOV := 100.0
const WARM_HEIGHT := 6.0 * RoadMetrics.UNIT_SCALE # warm-up camera height above the road
const WARM_PITCH := -0.12 # radians, looking slightly down the road

const ACCENT := Color(0.91, 0.64, 0.24)
const MARGIN := 56.0
const CAR_BOX := Vector2(440, 130)

## True from enter_drive() until the fade out begins.
static var busy := false
static var _instance: LoadingScreen = null

var _root: Control
var _black: ColorRect
var _content: Control
var _car: Control
var _status: Label
var _bar_fill: ColorRect

## Covers the switch into a drive: `start` (which sets GameState to PLAYING)
## runs once the screen is black. Ignored while a load is already running.
static func enter_drive(start: Callable) -> void:
	if busy:
		return
	if not is_instance_valid(_instance):
		_instance = LoadingScreen.new()
		_instance.name = "LoadingScreen"
		(Engine.get_main_loop() as SceneTree).root.add_child(_instance)
	_instance._run(start)

func _ready() -> void:
	layer = 100 # over every game screen / HUD, under PerfMonitor
	process_mode = Node.PROCESS_MODE_ALWAYS # the menu / garage pause the tree
	_build_ui()
	visible = false

func _exit_tree() -> void:
	busy = false # static - never leave IntroPan held

## Swallows keys / clicks while loading (no pausing or menu input behind it).
func _input(event: InputEvent) -> void:
	if busy and (event is InputEventKey or event is InputEventMouseButton):
		get_viewport().set_input_as_handled()

func _run(start: Callable) -> void:
	busy = true
	visible = true
	_root.modulate.a = 1.0
	_black.modulate.a = 0.0
	_content.modulate.a = 0.0
	_set_progress(0.0, "")
	_car.reset()

	await _fade(_black, 1.0, FADE_TO_BLACK)
	_fade(_content, 1.0, CONTENT_FADE_IN)
	var t0 := Time.get_ticks_msec()
	_set_progress(0.05, "BUILDING THE ROAD")
	await _frames(2) # the loading screen is on screen before the heavy frame
	start.call()
	await _frames(1)
	await _warm_up()
	_set_progress(1.0, "READY")
	while Time.get_ticks_msec() - t0 < MIN_SHOW_MS:
		await get_tree().process_frame

	_car.launch()
	await get_tree().create_timer(LAUNCH_TIME, true, false, true).timeout
	busy = false # IntroPan starts its sweep now, revealed by the fade
	await _fade(_root, 0.0, FADE_OUT)
	visible = false

# --- warm-up -----------------------------------------------------------------

func _warm_up() -> void:
	var tree := get_tree()
	var rg: Node = tree.get_first_node_in_group("road_generator")
	var car: Node3D = tree.get_first_node_in_group("player_car") as Node3D
	var prev_cam: Camera3D = get_viewport().get_camera_3d()
	if rg == null or car == null or prev_cam == null or rg.path == null:
		await _frames(WARM_FRAMES)
		return
	var cam := Camera3D.new()
	cam.name = "LoadingWarmUpCamera"
	cam.environment = prev_cam.environment
	cam.attributes = prev_cam.attributes
	cam.cull_mask = prev_cam.cull_mask
	cam.near = prev_cam.near
	cam.far = prev_cam.far
	cam.fov = WARM_FOV
	rg.add_child(cam)
	cam.make_current()

	var shots := _plan_shots(rg)
	var built: Array[Node3D] = []
	for i in shots.size():
		var shot: Dictionary = shots[i]
		_set_progress(0.1 + 0.85 * float(i) / float(shots.size()), shot.label)
		for index in shot.get("chunks", []):
			var chunk: Node3D = rg.build_warmup_chunk(index)
			if chunk:
				built.append(chunk)
		if shot.has("at_car"):
			cam.global_transform = _pose(car.global_position + Vector3.UP * WARM_HEIGHT, shot.yaw)
		else:
			var d: float = shot.dist
			cam.global_transform = _pose(rg.path.world_pos(d, 0.0) + Vector3.UP * WARM_HEIGHT, rg.path.road_frame(d).heading + shot.yaw)
		rg.set_warmup_sea(shot.get("sea", NAN))
		await _frames(WARM_FRAMES)

	rg.set_warmup_sea(NAN)
	for chunk in built:
		chunk.queue_free()
	prev_cam.make_current()
	cam.queue_free()

## Camera shots: the start area in four directions, then each feature type
## this run has - {label, yaw (added to the road heading), dist or at_car,
## chunks (indices to build for the shot), sea (bridge dist)}.
func _plan_shots(rg: Node) -> Array[Dictionary]:
	var M := RoadMetrics.UNIT_SCALE
	var layout: RoadLayout = rg.layout
	var shots: Array[Dictionary] = []
	var heading: float = rg.path.road_frame(rg.tracker.dist).heading
	for k in 4:
		shots.append({"label": "WARMING UP", "at_car": true, "yaw": heading + PI * 0.5 * k})
	if layout == null:
		return shots
	var styles_seen := {}
	for t in layout.tunnels:
		if styles_seen.has(t.style):
			continue
		styles_seen[t.style] = true
		var outside: float = t.portal_in - 70.0 * M
		var inside: float = t.portal_in + 50.0 * M
		shots.append({"label": "SCOUTING THE TUNNEL", "dist": outside, "yaw": 0.0, "chunks": _chunks_around(rg, outside, inside)})
		shots.append({"label": "SCOUTING THE TUNNEL", "dist": inside, "yaw": 0.0})
	if not layout.bridges.is_empty():
		var b: Dictionary = layout.bridges[0]
		var d: float = b.sea_start + 80.0 * M
		shots.append({"label": "SCOUTING THE BRIDGE", "dist": d, "yaw": 0.0, "chunks": _chunks_around(rg, d - 200.0 * M, d), "sea": d})
		shots.append({"label": "SCOUTING THE BRIDGE", "dist": d, "yaw": PI * 0.5, "sea": d})
	if not layout.overpasses.is_empty():
		var d: float = layout.overpasses[0].d - 60.0 * M
		shots.append({"label": "SCOUTING THE ROAD AHEAD", "dist": d, "yaw": 0.0, "chunks": _chunks_around(rg, d, d + 80.0 * M)})
	return shots

## Chunk indices covering road distances [a, b] plus one chunk either side.
func _chunks_around(rg: Node, a: float, b: float) -> Array[int]:
	var out: Array[int] = []
	for i in range(int(floor(a / rg.CHUNK_LENGTH)) - 1, int(floor(b / rg.CHUNK_LENGTH)) + 2):
		out.append(i)
	return out

## Looking along `yaw` (0 = world +Z, the RoadPath heading convention),
## pitched slightly down.
func _pose(pos: Vector3, yaw: float) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw + PI) * Basis(Vector3.RIGHT, WARM_PITCH), pos)

# --- helpers -----------------------------------------------------------------

func _frames(n: int) -> void:
	for i in n:
		await RenderingServer.frame_post_draw

func _fade(node: CanvasItem, to: float, time: float) -> void:
	var tw := create_tween()
	tw.set_ignore_time_scale(true)
	tw.tween_property(node, "modulate:a", to, time)
	await tw.finished

func _set_progress(p: float, status: String) -> void:
	_status.text = status
	_bar_fill.size.x = CAR_BOX.x * clampf(p, 0.0, 1.0)

func _build_ui() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP # nothing behind is clickable
	add_child(_root)

	_black = ColorRect.new()
	_black.color = Color.BLACK
	_black.set_anchors_preset(Control.PRESET_FULL_RECT)
	_black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_black)

	_content = Control.new()
	_content.set_anchors_preset(Control.PRESET_FULL_RECT)
	_content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_content)

	# Upper left: the main menu's wordmark (same theme styles), scaled up.
	var mark := VBoxContainer.new()
	mark.position = Vector2(MARGIN, MARGIN - 8.0)
	mark.add_theme_constant_override("separation", 2)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(mark)
	mark.add_child(_label("高速 · HIGHWAY", &"WordmarkJp", 15))
	mark.add_child(_label("KŌSOKU", &"WordmarkTitle", 72))
	var rule := ColorRect.new()
	rule.color = ACCENT
	rule.custom_minimum_size = Vector2(72, 2)
	rule.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	mark.add_child(rule)
	mark.add_child(_label("An endless night drive", &"WordmarkSub", 15))

	# Lower right: the car, and a thin progress line + status under it.
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	box.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	box.offset_left = -MARGIN - CAR_BOX.x
	box.offset_right = -MARGIN
	box.offset_top = -MARGIN - CAR_BOX.y - 30.0
	box.offset_bottom = -MARGIN
	box.add_theme_constant_override("separation", 6)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_content.add_child(box)

	_car = preload("res://UI/loading/loading_car.gd").new()
	_car.custom_minimum_size = CAR_BOX
	box.add_child(_car)

	var track := ColorRect.new()
	track.color = Color(1, 1, 1, 0.08)
	track.custom_minimum_size = Vector2(CAR_BOX.x, 2)
	track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(track)
	_bar_fill = ColorRect.new()
	_bar_fill.color = ACCENT
	_bar_fill.size = Vector2(0, 2)
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	track.add_child(_bar_fill)

	_status = _label("", &"WordmarkJp", 12)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(_status)

func _label(text: String, variation: StringName, font_size: int) -> Label:
	var l := Label.new()
	l.text = text
	l.theme_type_variation = variation
	l.add_theme_font_size_override("font_size", font_size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l
