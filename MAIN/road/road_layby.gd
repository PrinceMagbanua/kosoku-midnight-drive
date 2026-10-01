class_name RoadLayby
extends RefCounted

## Dressing for the starting lay-by - a UK-style emergency bay (see
## RoadLayout's "Lay-by" section). The bay itself comes from the road
## generator: the right shoulder edge steps out, so the paved surface (its
## own orange band), the ground collision, the invisible wall and the
## guardrail (RoadLayout.barrier_type) already follow it, and the grass strip
## and footpath move out behind it. From the road outward that gives:
## bay - kerb - guardrail on the grass strip - footpath - fence.
## This adds the rest:
## - the kerb along the bay's outer edge;
## - the fence along the outside of the footpath (the mesh fence's own
##   parapet, mesh, top rail and posts, reused from RoadBarriers);
## - a double row of short dashes across the bay's mouth;
## - LIGHT_COUNT lamp posts behind the guardrail, each reaching an arm back
##   over the bay with a warm downward spot and the streetlights' beam cone;
## - the Blender props (source: C:/My Projects/Kosoku_Road/layby_kit.blend,
##   exported to assets/road/layby/): the blue SOS sign, the orange emergency
##   phone, and the arrow + "SOS" painted on the bay. Modelled in metres with
##   their front toward Blender -Y, which arrives here as +Z.
## Look: the constants below.

const M := RoadMetrics.UNIT_SCALE

# Kerb: (u outward from the bay's edge, height), inner-bottom -> top -> outer-bottom.
const KERB_PROFILE: Array[Vector2] = [
	Vector2(0.0, -0.05 * M), Vector2(0.0, 0.14 * M), Vector2(0.16 * M, 0.14 * M), Vector2(0.16 * M, -0.05 * M),
]

# Mouth marking: two rows of short dashes along the normal shoulder line.
const MOUTH_DASH_STEP := 2.0 * M
const MOUTH_DASH_LENGTH_SCALE := 0.42 # of the lane divider dash (2.4 m) -> ~1 m
const MOUTH_ROW_OFFSETS: Array[float] = [0.10 * M, -0.22 * M] # from the shoulder line, + = toward the lanes

const LIGHT_COUNT := 3
const LIGHT_HEIGHT := 7.0 * M
const LIGHT_POLE_OUT := 1.3 * M # pole foot, outward from the bay's outer edge (on the grass strip)
const LIGHT_ARM := 3.2 * M # arm length back toward the road (lamp ends up over the bay)
const LIGHT_COLOR := Color(1.0, 0.93, 0.8)
const LIGHT_ENERGY := 5.0
const LIGHT_ANGLE_DEG := 58.0
const LIGHT_RANGE_MULT := 1.7 # spot_range = height * this
const LIGHT_FADE_BEGIN := 250.0
const CONE_ANGLE_DEG := 26.0

const PROP_DIR := "res://assets/road/layby/"
const SIGN_OUT := 1.5 * M # behind the bay's edge, on the grass strip
const PHONE_OUT := 1.1 * M
const PHONE_ALONG := 0.66 # how far along the full-width bay, 0..1
const MARKINGS_AHEAD := 12.0 * M # arrow base, ahead of where the car spawns

static var _res: Dictionary = {}

## `gen` is the RoadGenerator.
static func build(gen, chunk: Node3D, start_dist: float, end_dist: float) -> void:
	var span := RoadLayout.layby_span()
	if end_dist <= span[0] or start_dist >= span[3]:
		return
	var a: float = maxf(start_dist, span[0])
	var b: float = minf(end_dist, span[3])
	var node := Node3D.new()
	node.name = "Layby"
	chunk.add_child(node)

	node.add_child(RoadBarriers._swept(gen, a, b, -1.0, RoadBarriers._const(KERB_PROFILE), true, true, RoadBarriers._mat("parapet")))
	_fence(gen, node, a, b)
	node.add_child(_mouth_marking(gen, a, b))

	# Lights evenly along the full-width bay; each chunk builds the ones in its span.
	for i in LIGHT_COUNT:
		var d: float = lerpf(span[1], span[2], (float(i) + 0.5) / float(LIGHT_COUNT))
		if d >= start_dist and d < end_dist:
			node.add_child(_light(gen, d))

	# Props. Each is placed by the chunk that contains its spot.
	var heading_at := func(d: float) -> float: return gen.path.road_frame(d).heading
	var sign_d: float = span[1]
	if sign_d >= start_dist and sign_d < end_dist:
		# Its face looks back up the road, at approaching traffic.
		_prop(node, "layby_sos_sign", gen._ground_pos(sign_d, gen.layout.shoulder_edge(sign_d, -1.0) - SIGN_OUT), heading_at.call(sign_d) + PI)
	var phone_d: float = lerpf(span[1], span[2], PHONE_ALONG)
	if phone_d >= start_dist and phone_d < end_dist:
		# Its door faces the bay (+lateral).
		_prop(node, "layby_phone", gen._ground_pos(phone_d, gen.layout.shoulder_edge(phone_d, -1.0) - PHONE_OUT), heading_at.call(phone_d) + PI * 0.5)
	var marks_d: float = RoadLayout.spawn_dist() + MARKINGS_AHEAD
	if marks_d >= start_dist and marks_d < end_dist:
		_prop(node, "layby_markings", gen.path.world_pos(marks_d, RoadLayout.spawn_lateral()), heading_at.call(marks_d))

## Instances res://assets/road/layby/<name>.glb at `pos`, turned `yaw` about
## the vertical and scaled from metres. Skipped if the file isn't imported yet.
static func _prop(parent: Node3D, prop_name: String, pos: Vector3, yaw: float) -> void:
	var path: String = PROP_DIR + prop_name + ".glb"
	if not _res.has(path):
		# Not cached when missing, so it's picked up once the editor has imported it.
		var loaded: PackedScene = null
		if ResourceLoader.exists(path):
			loaded = load(path) as PackedScene
		if loaded == null:
			return
		_res[path] = loaded
	var scene: PackedScene = _res[path]
	var inst := scene.instantiate() as Node3D
	if inst == null:
		return
	inst.transform = Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3.ONE * M), pos)
	parent.add_child(inst)

## The fence behind the footpath: RoadBarriers' mesh fence, moved out from the
## shoulder edge to the footpath's outer edge (which follows the bay).
static func _fence(gen, node: Node3D, a: float, b: float) -> void:
	var out: float = gen.SIDEWALK_HALF_WIDTH - gen.SHOULDER_HALF_WIDTH
	var base: Array[Vector2] = []
	for p in RoadBarriers.PARAPET_PROFILE:
		base.append(Vector2(p.x + out, p.y))
	var mesh_u: float = out + RoadBarriers.MESH_U
	var top: float = RoadBarriers.MESH_TOP
	var foot: float = RoadBarriers.PARAPET_HEIGHT
	node.add_child(RoadBarriers._swept(gen, a, b, -1.0, RoadBarriers._const(base), true, true, RoadBarriers._mat("parapet")))
	node.add_child(RoadBarriers._swept(gen, a, b, -1.0, RoadBarriers._const([Vector2(mesh_u, foot), Vector2(mesh_u, top)]), false, false, RoadBarriers._mat("mesh"), false))
	node.add_child(RoadBarriers._swept(gen, a, b, -1.0, RoadBarriers._const(RoadBarriers._box_profile(mesh_u, top, 0.06 * M)), true, true, RoadBarriers._mat("post_white")))
	var post := RoadBarriers._box(Vector3(RoadBarriers.MESH_POST_SIZE, top - foot, RoadBarriers.MESH_POST_SIZE))
	node.add_child(RoadBarriers._posts(gen, a, b, -1.0, RoadBarriers.MESH_POST_SPACING, mesh_u, foot, top, post, RoadBarriers._mat("post_white")))

## Two rows of short dashes along the normal shoulder line (the lane divider
## dash, shortened), on global multiples of the step.
static func _mouth_marking(gen, a: float, b: float) -> MultiMeshInstance3D:
	var line: float = RoadMetrics.RIGHT_EDGE - RoadMetrics.SHOULDER_WIDTH
	var xforms: Array[Transform3D] = []
	var d: float = ceilf(a / MOUTH_DASH_STEP) * MOUTH_DASH_STEP
	while d < b:
		var basis := Basis(Vector3.UP, gen.path.road_frame(d).heading).scaled(Vector3(1.0, 1.0, MOUTH_DASH_LENGTH_SCALE))
		for offset in MOUTH_ROW_OFFSETS:
			xforms.append(Transform3D(basis, gen.path.world_pos(d, line + offset)))
		d += MOUTH_DASH_STEP
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = gen._shared("dash_mesh")
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "MouthMarking"
	mmi.multimesh = mm
	mmi.material_override = gen._shared("dash_mat")
	return mmi

## One lamp post at road distance `d`: foot behind the guardrail, arm reaching
## toward the road (+X here, since the node is turned to the road's heading
## and the lay-by is on the -lateral side).
static func _light(gen, d: float) -> Node3D:
	var edge: float = gen.layout.shoulder_edge(d, -1.0)
	var root := Node3D.new()
	root.name = "LaybyLight"
	root.transform = Transform3D(Basis(Vector3.UP, gen.path.road_frame(d).heading), gen._ground_pos(d, edge - LIGHT_POLE_OUT))

	var frame := MeshInstance3D.new()
	frame.mesh = _frame_mesh(gen)
	frame.material_override = gen._shared("lamp_pole_mat")
	root.add_child(frame)

	var lamp := Vector3(LIGHT_ARM, LIGHT_HEIGHT - gen.LAMP_HEAD_SIZE.y * 0.5, 0.0)
	var head := MeshInstance3D.new()
	head.mesh = gen._shared("lamp_head")
	head.material_override = gen._shared("lamp_head_mat")
	head.position = lamp
	root.add_child(head)

	var light := SpotLight3D.new()
	light.position = lamp - Vector3(0.0, gen.LAMP_HEAD_SIZE.y * 0.5, 0.0)
	light.rotation.x = -PI / 2.0 # -Z (spot direction) -> straight down
	light.light_color = LIGHT_COLOR
	light.light_energy = LIGHT_ENERGY
	light.spot_range = LIGHT_HEIGHT * LIGHT_RANGE_MULT
	light.spot_angle = LIGHT_ANGLE_DEG
	light.spot_attenuation = 0.8
	light.shadow_enabled = false
	light.distance_fade_enabled = true
	light.distance_fade_begin = LIGHT_FADE_BEGIN
	light.distance_fade_length = 100.0
	root.add_child(light)

	var cone := MeshInstance3D.new()
	cone.mesh = _cone_mesh(gen)
	cone.material_override = gen._shared("lamp_cone_mat")
	cone.position = Vector3(LIGHT_ARM, 0.0, 0.0)
	root.add_child(cone)
	return root

## Pole + arm as one mesh (origin at the pole's foot), built once.
static func _frame_mesh(gen) -> ArrayMesh:
	if not _res.has("frame"):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(gen._lamp_cylinder(0.04, 0.06, LIGHT_HEIGHT), 0,
			Transform3D(Basis.IDENTITY, Vector3(0.0, LIGHT_HEIGHT * 0.5, 0.0)))
		# CylinderMesh's axis is Y; turned to lie along X, starting at the pole top.
		st.append_from(gen._lamp_cylinder(0.03, 0.03, LIGHT_ARM), 0,
			Transform3D(Basis.from_euler(Vector3(0.0, 0.0, -PI / 2.0)), Vector3(LIGHT_ARM * 0.5, LIGHT_HEIGHT, 0.0)))
		_res["frame"] = st.commit()
	return _res["frame"]

static func _cone_mesh(gen) -> ArrayMesh:
	if not _res.has("cone"):
		_res["cone"] = gen._build_fake_light_cone(LIGHT_HEIGHT - gen.LAMP_HEAD_SIZE.y, CONE_ANGLE_DEG, LIGHT_COLOR)
	return _res["cone"]
