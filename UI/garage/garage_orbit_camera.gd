extends Camera3D

## Preview camera for the garage/start showcase. Each mode's shot is a
## plain Marker3D under "Viewpoints" (GaragePreview.tscn: Viewpoints/start,
## Viewpoints/car, Viewpoints/map, Viewpoints/intro), each carrying a
## GarageCameraViewpoint script - select one in the Godot editor and move
## it with the normal 3D gizmo to set where the CAMERA stands, and move its
## own "LookAt" child marker to set where it's AIMED (not tied to the car's
## center - point it wherever you want). No code/numbers to edit for
## framing.
##
## Customize screen: focus() switches to an ORBIT around a viewpoint's
## LookAt point (Viewpoints/cust_overview, cust_front, cust_rear, cust_side,
## cust_top - same editor-placed markers; their h_offset is unused, see
## orbit_screen_shift), starting from where that marker stands;
## orbit_by()/zoom_by() (drag/scroll) then move it from there. The preview
## car is parked facing its authored heading meanwhile
## (garage_preview_settle.gd), so the markers always frame the same part.

@export var target_path: NodePath = NodePath("../PreviewCar")
@export var viewpoints_path: NodePath = NodePath("../Viewpoints")
## Customize orbit: where the orbit pivot sits across the screen, as a
## fraction of the half-width (0 = centre, 0.5 = middle of the left half,
## clear of the right-hand Customize panel). Kept by distance, so zooming
## doesn't slide the car under the panel.
@export var orbit_screen_shift: float = 0.5

const EASE_RATE := 3.0
const ORBIT_EASE_RATE := 6.0
const ORBIT_SENSITIVITY := 0.008 # radians per pixel of drag
const PITCH_MIN := -0.087 # -5 degrees
const PITCH_MAX := 1.396 # 80 degrees
const ZOOM_STEP := 1.12
const DIST_MIN := 5.0
const DIST_MAX := 30.0

var mode: String = "start"
var _h_offset: float = 0.0
var _look_at: Vector3 = Vector3.UP

# Orbit (customize) state: targets, eased toward in _process.
var _orbiting := false
var _pivot := Vector3.ZERO
var _yaw := 0.0
var _pitch := 0.0
var _dist := 12.0

func _viewpoint(name: String) -> GarageCameraViewpoint:
	var container: Node = get_node_or_null(viewpoints_path)
	if container == null:
		return null
	return container.get_node_or_null(name) as GarageCameraViewpoint

func _fallback_look_at() -> Vector3:
	var target: Node3D = get_node_or_null(target_path)
	return (target.global_position + Vector3.UP) if target else Vector3.UP

func _process(delta: float) -> void:
	if _orbiting:
		_process_orbit(delta)
		return
	var vp := _viewpoint(mode)
	if vp == null:
		return
	var lerp_t: float = clampf(delta * EASE_RATE, 0.0, 1.0)
	global_position = global_position.lerp(vp.global_position, lerp_t)
	_h_offset = lerpf(_h_offset, vp.h_offset, lerp_t)
	h_offset = _h_offset
	_look_at = _look_at.lerp(vp.get_look_at_position(_fallback_look_at()), lerp_t)

	if global_position.distance_squared_to(_look_at) > 0.0001:
		look_at(_look_at, Vector3.UP)

func _process_orbit(delta: float) -> void:
	var lerp_t: float = clampf(delta * ORBIT_EASE_RATE, 0.0, 1.0)
	var target_pos := _pivot + _orbit_offset(_yaw, _pitch, _dist)
	# Ease in spherical terms around the (eased) pivot so a big yaw change
	# swings around the car instead of cutting straight through it.
	_look_at = _look_at.lerp(_pivot, lerp_t)
	var rel := global_position - _look_at
	var cur_dist := maxf(rel.length(), 0.01)
	var cur_yaw := atan2(rel.x, rel.z)
	var cur_pitch := asin(clampf(rel.y / cur_dist, -1.0, 1.0))
	var want := target_pos - _pivot
	var want_yaw := atan2(want.x, want.z)
	cur_yaw = lerp_angle(cur_yaw, want_yaw, lerp_t)
	cur_pitch = lerpf(cur_pitch, _pitch, lerp_t)
	cur_dist = lerpf(cur_dist, _dist, lerp_t)
	global_position = _look_at + _orbit_offset(cur_yaw, cur_pitch, cur_dist)
	# h_offset slides the camera along its own X (no rotation), so the pivot
	# lands orbit_screen_shift of the half-width left of centre.
	var vp_size := get_viewport().get_visible_rect().size
	var aspect := vp_size.x / maxf(vp_size.y, 1.0)
	var want_h := orbit_screen_shift * cur_dist * tan(deg_to_rad(fov) * 0.5) * aspect
	_h_offset = lerpf(_h_offset, want_h, lerp_t)
	h_offset = _h_offset
	if global_position.distance_squared_to(_look_at) > 0.0001:
		look_at(_look_at, Vector3.UP)

static func _orbit_offset(yaw: float, pitch: float, dist: float) -> Vector3:
	return Vector3(sin(yaw) * cos(pitch), sin(pitch), cos(yaw) * cos(pitch)) * dist

func set_mode(new_mode: String) -> void:
	mode = new_mode
	_orbiting = false

## Customize: orbit around viewpoint `name`'s LookAt, starting from where the
## marker stands (eased there from the current shot).
func focus(viewpoint_name: String) -> void:
	var vp := _viewpoint(viewpoint_name)
	if vp == null:
		return
	_orbiting = true # eases from the current shot (_look_at/position) to this one
	_pivot = vp.get_look_at_position(_fallback_look_at())
	var rel := vp.global_position - _pivot
	_dist = clampf(rel.length(), DIST_MIN, DIST_MAX)
	_yaw = atan2(rel.x, rel.z)
	_pitch = clampf(asin(clampf(rel.y / maxf(rel.length(), 0.01), -1.0, 1.0)), PITCH_MIN, PITCH_MAX)

## Drag: `delta_px` is the mouse motion in screen pixels.
func orbit_by(delta_px: Vector2) -> void:
	if not _orbiting:
		return
	_yaw -= delta_px.x * ORBIT_SENSITIVITY
	_pitch = clampf(_pitch + delta_px.y * ORBIT_SENSITIVITY, PITCH_MIN, PITCH_MAX)

## Scroll: steps > 0 zooms in.
func zoom_by(steps: float) -> void:
	if not _orbiting:
		return
	_dist = clampf(_dist * pow(ZOOM_STEP, -steps), DIST_MIN, DIST_MAX)

## Snaps (not eases) straight to the "intro" viewpoint - used when the
## showcase was fully hidden before (see menu_showcase.gd) so it starts
## from a fresh wide establishing shot instead of picking up mid-glide from
## wherever the camera last was.
func reset_intro() -> void:
	var vp := _viewpoint("intro")
	if vp:
		_orbiting = false
		global_position = vp.global_position
		_h_offset = vp.h_offset
		_look_at = vp.get_look_at_position(_fallback_look_at())
