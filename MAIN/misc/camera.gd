extends Marker3D

var default_cam_pos
var can_drag = false
var just_resetted = false


@export var mobile_controls = NodePath()
@export var car :NodePath = NodePath("../car")
@export var debugger = NodePath()

var drag_velocity = Vector2(0,0)
var last_pos = Vector2(0,0)
var x_drag_unlocked = false
var y_drag_unlocked = false

var resetdel = 0
var default_zoom

## Speed zoom-out: the camera eases further back as the car goes faster, over
## the same speed range as the speed shake (CameraShake.speed_frac). Scaled by
## DevConsole.speed_zoom (a dev console slider, for tuning).
const SPEED_ZOOM_MAX := 3.0 # world units further back at the top of the range
const SPEED_ZOOM_RATE := 2.5 # how fast it follows the speed (per real second)
var _speed_zoom := 0.0

# Node references, fetched once instead of every frame. The car is looked up
# again only when its path changes (the debug menu's car swapper) or the node
# goes away - see _target().
@onready var _orbit: Node3D = $orbit
@onready var _camera: Camera3D = $orbit/Camera
var _debugger_node: Node
var _car_node: Node3D
var _car_centre: Node3D # the car's CAMERA_CENTRE marker, if it has one
var _car_path_seen := NodePath()

func _ready():
	default_cam_pos = _camera.position
	default_zoom = default_cam_pos.z
	_debugger_node = get_node_or_null(debugger)

## The car this camera follows (null if there isn't one right now).
func _target() -> Node3D:
	if _debugger_node:
		car = _debugger_node.car
	if car != _car_path_seen or not is_instance_valid(_car_node):
		_car_path_seen = car
		_car_node = get_node_or_null(car) as Node3D
		_car_centre = (_car_node.get_node_or_null("CAMERA_CENTRE") as Node3D) if _car_node else null
	return _car_node

## During play the rig's heading is inherited frame to frame: look_at() aims
## from wherever this marker sat last frame toward the car, then the marker is
## moved onto the car and pushed 14.5 back along that direction. A stale
## direction (e.g. from the last crash) therefore survives while the car sits
## still at a run start - so at the START of a run only, IntroPan calls this
## to park the marker directly behind the car once. Normal driving is
## untouched.
func snap_to_car() -> void:
	var c := _target()
	if c == null:
		return
	var pivot: Vector3 = _car_centre.global_position if _car_centre else c.global_position
	var f: Vector3 = c.global_transform.basis.z # the car's forward (same axis nitro_boost.gd pushes along)
	f.y = 0.0
	if f.length_squared() < 0.0001:
		return
	global_position = pivot - f.normalized() * 10.5

func _process(delta):
	var c := _target()
	if c:

		if _car_centre:
			look_at(_car_centre.global_position,Vector3(0,1,0))
			position = _car_centre.global_position
		else:
			look_at(c.position,Vector3(0,1,0))
			position = c.position
		translate_object_local(Vector3(0,0,10.5))

		var zoom_target = 0.0
		if c is RigidBody3D:
			zoom_target = CameraShake.speed_frac(c.linear_velocity.length()) * SPEED_ZOOM_MAX * DevConsole.speed_zoom
		var real_delta = delta / maxf(Engine.time_scale, 0.001)
		_speed_zoom = lerpf(_speed_zoom, zoom_target, 1.0 - exp(-SPEED_ZOOM_RATE * real_delta))

		_orbit.global_position = c.global_position
		# +Z is away from the car (the same axis zoom_in/zoom_out move along).
		_camera.position = default_cam_pos -_orbit.position + Vector3(0, 0, _speed_zoom)

func _physics_process(delta):

	if Input.is_action_pressed("zoom_out"):
		default_cam_pos.z += 0.05
	elif Input.is_action_pressed("zoom_in"):
		default_cam_pos.z -= 0.05

	if Input.is_action_pressed("CAM_orbit_left"):
		_orbit.rotation_degrees.y += 1
	elif Input.is_action_pressed("CAM_orbit_right"):
		_orbit.rotation_degrees.y -= 1

	if Input.is_action_pressed("CAM_orbit_reset"):
		_orbit.rotation_degrees.y = 0.0
		default_cam_pos.z = default_zoom
		
	resetdel -= 1
		
func _input(event):
	if not str(mobile_controls) == "":
		if get_node(mobile_controls).visible:
			can_drag = true
			for i in get_node(mobile_controls).get_children():
				if i.is_pressed():
					can_drag = false
			if event is InputEventScreenTouch:
				if can_drag:
					last_pos = event.position
					if not event.is_pressed():
						if resetdel>0:
							_orbit.rotation_degrees.y = 0.0
							default_cam_pos.z = default_zoom
							just_resetted = true
						resetdel = 15
			else:
				just_resetted = false

			if event is InputEventScreenDrag:
				if can_drag and not just_resetted:
					drag_velocity.x = event.position.x - last_pos.x
					drag_velocity.y = event.position.y - last_pos.y
					last_pos = event.position
					
					if abs(drag_velocity.y)>5.0:
						y_drag_unlocked = true
					if abs(drag_velocity.x)>5.0:
						x_drag_unlocked = true
					
					if y_drag_unlocked:
						default_cam_pos.z += drag_velocity.y/200.0
					if x_drag_unlocked:
						_orbit.rotation_degrees.y -= drag_velocity.x/2.0
					resetdel = -1
			if event.is_action_released("gas_mouse"):
				x_drag_unlocked = false
				y_drag_unlocked = false
			
