@tool
extends MeshInstance3D

## Live side mirror on a car's "Mirror_L" mesh (see ModularCarBuilder.
## _rig_mirrors(), which lays the mesh's UVs flat across the glass and passes
## its plane as mesh-local meta).
##
## How the reflection works: the viewer's eye (the active camera - the cockpit
## camera when driving) is reflected through the mirror plane, and a second
## camera at that reflected point looks at the mirror's centre, framed to the
## mirror's size. Its image, flipped left-right, is exactly what a flat mirror
## would show from that eye - including the car's own flank.
##
## Cost: it's a second render of the scene, so it only runs while
## misc_graphics_settings.side_mirror is on AND the active camera is within
## UPDATE_DISTANCE (cockpit view), at a small resolution, every UPDATE_EVERY
## frames. Otherwise the glass shows plain dark IDLE_COLOR and costs nothing.
##
## @tool: also live in a car's interior scene preview (car_interior.gd),
## reflecting from the interior scene's DriverCamera (else the hull's
## CockpitEye marker) instead of a game camera.
##
## Aim: the car's interior scene (car_interior.gd) holds mirror_l_yaw /
## mirror_l_pitch / mirror_l_fov_boost - they tilt the glass like a real
## mirror adjuster, so the reflection follows physically.

const TEX_WIDTH := 256
const UPDATE_DISTANCE := 8.0 # world units from the active camera
const UPDATE_EVERY := 2 # render every Nth frame (2 = half rate)
const FAR := 150.0 # mirror view distance - far scenery isn't worth re-rendering
## Used when the car has no interior scene (else its mirror_l_fov_boost).
const FOV_BOOST := 1.35
const IDLE_COLOR := Color(0.05, 0.06, 0.08)

var _viewport: SubViewport
var _cam: Camera3D
var _mat: StandardMaterial3D
var _live := false
var _frame := 0

func _ready() -> void:
	var aspect := float(get_meta("mirror_aspect", 2.0))
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(TEX_WIDTH, clampi(int(TEX_WIDTH / aspect), 32, 512))
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_cam = Camera3D.new()
	_cam.far = FAR
	_viewport.add_child(_cam)
	add_child(_viewport)
	_cam.current = true

	_mat = StandardMaterial3D.new()
	_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_mat.albedo_color = IDLE_COLOR
	# Mirror image: flip U (the camera sees the world un-mirrored).
	_mat.uv1_scale = Vector3(-1.0, 1.0, 1.0)
	_mat.uv1_offset = Vector3(1.0, 0.0, 0.0)
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

func _process(_delta: float) -> void:
	var centre: Vector3 = global_transform * (get_meta("mirror_center", Vector3.ZERO) as Vector3)
	var eye := Vector3.ZERO
	var live := false
	if Engine.is_editor_hint():
		# Interior scene preview: no game camera or settings autoload here -
		# reflect from the driver's eye marker and always stay live.
		var interior := _find_interior()
		var marker: Node3D = interior.find_child(ModularCarBuilder.DRIVER_CAMERA, true, false) as Node3D if interior else null
		if marker == null:
			marker = _find_eye_marker()
		if marker:
			eye = marker.global_position
			live = true
	else:
		var viewer := get_viewport().get_camera_3d()
		if viewer:
			eye = viewer.global_position
			live = misc_graphics_settings.side_mirror and is_visible_in_tree() \
				and eye.distance_to(centre) < UPDATE_DISTANCE
	if live != _live:
		_live = live
		_mat.albedo_texture = _viewport.get_texture() if live else null
		_mat.albedo_color = Color.WHITE if live else IDLE_COLOR
	if not live:
		return
	_frame += 1
	if _frame % UPDATE_EVERY != 0:
		return
	_place_camera(eye, centre)
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE

## The hull's CockpitEye (ModularCarBuilder), found by walking up to the hull.
func _find_eye_marker() -> Node3D:
	var n := get_parent()
	while n != null:
		var marker := n.get_node_or_null(ModularCarBuilder.COCKPIT_EYE) as Node3D
		if marker:
			return marker
		n = n.get_parent()
	return null

## The car's interior scene root (car_interior.gd): an ancestor in its own
## editor preview, the hull's "Interior" child in-game.
func _find_interior() -> Node:
	var n := get_parent()
	while n != null:
		if "mirror_l_yaw" in n:
			return n
		var child := n.get_node_or_null(ModularCarBuilder.INTERIOR_NODE)
		if child:
			return child
		n = n.get_parent()
	return null

func _place_camera(eye: Vector3, centre: Vector3) -> void:
	var n: Vector3 = (global_basis * (get_meta("mirror_normal", Vector3.BACK) as Vector3)).normalized()
	var half_up: Vector3 = global_basis * (get_meta("mirror_half_height", Vector3.UP * 0.05) as Vector3)
	if n.dot(eye - centre) < 0.0:
		n = -n # the reflecting side faces the viewer
	var glass_n := n # the real glass plane, before any adjuster tilt
	# Mirror adjuster: yaw about the car's up (outward = away from the car's
	# centreline, whichever side this mirror is on), then pitch (down = +).
	var interior := _find_interior()
	var fov_boost := FOV_BOOST
	var clip_extra := 0.0
	if interior and "mirror_l_yaw" in interior:
		var up := global_basis.y.normalized()
		var outward := signf((get_meta("mirror_center", Vector3.ZERO) as Vector3).x)
		n = Basis(up, -deg_to_rad(float(interior.mirror_l_yaw)) * outward) * n
		var tilt_axis := n.cross(up).normalized()
		n = Basis(tilt_axis, -deg_to_rad(float(interior.mirror_l_pitch))) * n
		fov_boost = float(interior.mirror_l_fov_boost)
		clip_extra = float(interior.mirror_l_clip)
	var plane_dist := (eye - centre).dot(n)
	var mirrored_eye := eye - 2.0 * plane_dist * n
	var to_mirror := centre - mirrored_eye
	var dist := to_mirror.length()
	if dist < 1e-3:
		return
	var view_dir := to_mirror / dist
	_cam.global_transform = Transform3D(Basis.looking_at(view_dir, half_up.normalized()), mirrored_eye)
	# Clip everything up to the glass's FARTHEST corner along the view: the
	# camera sits behind the glass (it's the reflected eye), so the mirror
	# housing - and the glass itself - lie between it and the reflection.
	# Clipping at the perpendicular distance to the glass plane left the
	# housing's front edge in view whenever the mirror is seen at an angle,
	# i.e. always from the seat. mirror_l_clip (interior scene) adds on top.
	var half_w := half_up.length() * float(get_meta("mirror_aspect", 2.0))
	var half_right := half_up.normalized().cross(glass_n).normalized() * half_w
	var far_corner := 0.0
	for corner in [half_up + half_right, half_up - half_right, -half_up + half_right, -half_up - half_right]:
		far_corner = maxf(far_corner, (centre + corner - mirrored_eye).dot(view_dir))
	_cam.near = maxf(far_corner + clip_extra, 0.05)
	_cam.fov = clampf(rad_to_deg(2.0 * atan(half_up.length() / dist)) * fov_boost, 5.0, 120.0)
