class_name HeadlightSpec
extends RefCounted

## Shared tuning constants for every car's headlight SpotLight3Ds (player and
## traffic alike) - factored out so headlight_lights.gd and traffic_car.gd
## don't carry two copies that can drift apart.

const LIGHT_ENERGY := 70.0 # 25 * 3, per user request
const LIGHT_RANGE := 500.0 # 5.0 * 5, per user request
const LIGHT_SPOT_ANGLE := 32.0

## Traffic real-light LOD tier (traffic_car.gd's set_real_headlights_enabled,
## driven by traffic_manager.gd's distance-based selection) - deliberately
## cheaper than the player's own values: shorter range means fewer OTHER
## meshes (road chunks, buildings) this light competes to affect, keeping
## it well inside gl_compatibility's per-mesh real-time-light budget even
## with several of these active near the player at once.
const TRAFFIC_LIGHT_ENERGY := 10.0
const TRAFFIC_LIGHT_RANGE := 22.0
const TRAFFIC_LIGHT_SPOT_ANGLE := 28.0
const TRAFFIC_DOWNWARD_TILT_DEG := -4.0

## Fake forward-facing headlight cone (purely visual, no Light3D) - same
## "translucent gradient cone" trick road_generator.gd's streetlights use
## (_build_fake_light_cone), just extending forward along local -Z instead
## of straight down along -Y. Built to shine along local -Z specifically so
## it needs ZERO extra rotation when parented under a headlight mesh node -
## matching set_real_headlights_enabled()'s own existing SpotLight3D, which
## already relies on exactly that same "-Z is forward once hull's 180 flip
## is inherited" convention (see its own comment). Cheap enough (a handful
## of triangles, no real-time light) to put on every traffic car
## unconditionally, unlike the real SpotLight3D LOD tier above.
const CONE_LENGTH := 9.0
const CONE_HALF_ANGLE_DEG := 22.0
const CONE_APEX_ALPHA := 0.0
const CONE_BASE_ALPHA := 0.16

static func build_forward_cone(color: Color) -> MeshInstance3D:
	var length: float = CONE_LENGTH
	var radius: float = length * tan(deg_to_rad(CONE_HALF_ANGLE_DEG))
	var segments := 12
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var apex := Vector3.ZERO
	var apex_color := Color(color.r, color.g, color.b, CONE_APEX_ALPHA)
	var base_color := Color(color.r, color.g, color.b, CONE_BASE_ALPHA)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var p0 := Vector3(cos(a0) * radius, sin(a0) * radius, -length)
		var p1 := Vector3(cos(a1) * radius, sin(a1) * radius, -length)
		st.set_color(apex_color); st.add_vertex(apex)
		st.set_color(base_color); st.add_vertex(p0)
		st.set_color(base_color); st.add_vertex(p1)
	var mesh := st.commit()
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mi.material_override = mat
	return mi
