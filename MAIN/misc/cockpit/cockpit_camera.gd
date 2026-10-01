extends Camera3D

## Cockpit/first-person camera. NOT parented to the car (mirrors Voxel Driver's
## `main.js`/`core.js` approach, which keeps the camera top-level and copies
## the car body's transform onto it every frame rather than parenting) so the
## yaw-lag math below matches the original 1:1 instead of fighting Godot's
## parent/child transform composition.
##
## Position, pitch and roll are copied rigidly from the car every frame.
## Only yaw is smoothed: exponential smoothing toward the car's true yaw,
## shortest-path-wrapped, with the *residual gap* hard-clamped so a fast spin
## never lets the view trail by more than MAX_YAW_LAG. See
## [[cockpit_camera_yaw_lag]] project memory / plan doc for the exact
## three.js algorithm this mirrors.
##
## Interior: the modular cars carry their own (seats, dash, steering wheel,
## door cards), so the camera sits INSIDE the real hull at the driver's eye -
## the hull's CockpitEye marker, placed by ModularCarBuilder from the steering
## wheel - plus the profile's cockpit_offset. The hull stays visible; only
## its ink outlines are hidden while inside (CarOutlines), since the inflated
## shells would otherwise wall off the cabin in black.
##
## Driver view: if the car's interior scene has a DriverCamera (swapped for a
## DriverEye marker at runtime - see ModularCarBuilder.DRIVER_CAMERA), its
## position, look direction, fov and near plane are used as-is, so the
## editor's camera Preview is the in-game view. Without one, the camera sits
## at the auto-placed CockpitEye looking straight ahead.
##
## Interior lights: each car's interior scene (MAIN/cars/interiors/
## <car>_Interior.tscn, edited in the editor with a live car preview) sits in
## the hull as "Interior", hidden - shown here only while in cockpit view.

const YAW_LAG_RATE := 2.5 ## matches COCKPIT_YAW_LAG in the three.js source
const MAX_YAW_LAG := deg_to_rad(15.0) ## matches COCKPIT_MAX_YAW_LAG

## This car's driving-forward direction is +Z in its own local space, not
## Godot's default camera-forward (-Z) - so a camera facing "backwards" here
## actually means it's facing the car's true forward correctly, just 180 off
## from a naive rotation copy. Add a yaw offset rather than fight the car's
## own convention (the car's forward is baked into physics/wheel raycasts
## elsewhere and isn't worth re-deriving here).
const FORWARD_YAW_OFFSET := PI

@export var car_path: NodePath = NodePath("../car")

var _car: Node3D
## Car-space nudge from the auto-placed eye point (CarProfile.cockpit_offset).
var _eye_offset: Vector3 = Vector3.ZERO
var _yaw_smooth: float = 0.0
var _yaw_initialized: bool = false

func _ready() -> void:
	_car = get_node_or_null(car_path)
	current = false

func _physics_process(delta: float) -> void:
	if _car == null or not current:
		return
	var driver_eye := _driver_eye()
	global_position = _eye_position(driver_eye)
	# The view's orientation relative to the car: the DriverCamera's own
	# (look direction as authored), else straight ahead along the car's +Z.
	var view_rel := Basis(Vector3.UP, FORWARD_YAW_OFFSET)
	if driver_eye:
		view_rel = (_car.global_transform.basis.orthonormalized().inverse() * driver_eye.global_transform.basis).orthonormalized()
		fov = float(driver_eye.get_meta("fov", fov))
		near = float(driver_eye.get_meta("near", near))

	var true_yaw := wrapf(_car.rotation.y + FORWARD_YAW_OFFSET, -PI, PI)

	# Rigid copy of the car's FULL orientation, turned 180 about the car's own
	# up axis so the camera looks along the car's +Z. It has to be composed
	# this way (car basis * flip), NOT by copying the car's Euler angles and
	# adding PI to yaw: that puts pitch/roll into a frame already turned 180,
	# which mirrors them (road pitches up -> view pitches down, roll inverted).
	var true_basis: Basis = _car.global_transform.basis.orthonormalized() * view_rel

	if not _yaw_initialized:
		_yaw_smooth = true_yaw
		_yaw_initialized = true

	var yaw_delta := wrapf(true_yaw - _yaw_smooth, -PI, PI)
	_yaw_smooth += yaw_delta * minf(1.0, YAW_LAG_RATE * delta)

	var yaw_gap := wrapf(true_yaw - _yaw_smooth, -PI, PI)
	yaw_gap = clampf(yaw_gap, -MAX_YAW_LAG, MAX_YAW_LAG)
	_yaw_smooth = true_yaw - yaw_gap

	# The camera lags only in world-space yaw: turn the true orientation back
	# by the gap about the world up axis.
	global_transform = Transform3D(Basis(Vector3.UP, -yaw_gap) * true_basis, global_position)
	_show_interior(true) # every frame: the hull (and its Interior) is replaced on part changes

## The interior scene's DriverEye, looked up every frame - the hull (and its
## Interior) is replaced on car/part changes.
func _driver_eye() -> Node3D:
	var interior := _car.get_node_or_null("VoxelCarMesh/" + ModularCarBuilder.INTERIOR_NODE)
	return interior.find_child(ModularCarBuilder.DRIVER_EYE, true, false) as Node3D if interior else null

## The driver's eye in world space: the interior's DriverEye, else the hull's
## auto-placed CockpitEye, else the car's CAMERA_CENTRE (non-modular hulls),
## plus the per-car nudge.
func _eye_position(driver_eye: Node3D) -> Vector3:
	if driver_eye:
		return driver_eye.global_position + _car.global_transform.basis * _eye_offset
	var eye: Node3D = _car.get_node_or_null("VoxelCarMesh/" + ModularCarBuilder.COCKPIT_EYE)
	if eye == null:
		eye = _car.get_node_or_null("CAMERA_CENTRE")
	var base: Vector3 = eye.global_position if eye else _car.global_position
	return base + _car.global_transform.basis * _eye_offset

## Called by CarProfileApplier with the selected car.
func apply_profile(profile: CarProfile) -> void:
	_eye_offset = profile.cockpit_offset

func activate() -> void:
	_yaw_initialized = false # re-sync instantly on switch, no lag from a stale angle
	current = true
	_suppress_outlines(true)
	_show_interior(true)

func deactivate() -> void:
	current = false
	_suppress_outlines(false)
	_show_interior(false)

## Cockpit-only dressing of the current hull: its interior scene (lights),
## plus the see-through "inside" glass and hidden windscreen sticker
## (ModularCarBuilder.set_cockpit_view()).
func _show_interior(on: bool) -> void:
	if _car == null:
		return
	var hull := _car.get_node_or_null("VoxelCarMesh")
	if hull == null:
		return
	var interior := hull.get_node_or_null(ModularCarBuilder.INTERIOR_NODE) as Node3D
	if interior and interior.visible != on:
		interior.visible = on
	ModularCarBuilder.set_cockpit_view(hull, on)

## Looked up by path (not the autoload name) so this keeps working if the
## CarOutlines autoload is ever removed.
func _suppress_outlines(on: bool) -> void:
	var outlines := get_node_or_null("/root/CarOutlines")
	if outlines and _car:
		outlines.set_suppressed(_car, on)
