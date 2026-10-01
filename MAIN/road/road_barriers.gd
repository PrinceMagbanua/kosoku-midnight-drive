class_name RoadBarriers
extends RefCounted

## Roadside barriers for one chunk side. Which type stands where comes from
## RoadLayout.barrier_type() (tied to biome, viaducts, tunnels); this only
## builds them. Every type is swept along the path at the ribbon's sub-row
## spacing from the layout's shoulder edge outward, so it follows curves,
## grade and lane closures (angling in when a lane closes) the same way the
## collision wall does. Adjacent sub-rows of the same type form one run; a
## run that meets a different type (or none) gets a flat end cap.
##
## Profiles are (u, h): u = metres*UNIT_SCALE outward from the shoulder edge,
## h = height above the edge level (RoadGenerator._edge_level_pos), listed
## inner-bottom -> over the top -> outer-bottom. Collision is NOT here - the
## chunk's invisible per-row wall boxes do that job for every type.
##
##   JERSEY      the original sloped concrete barrier
##   GUARDRAIL   W-beam on white posts (forest)
##   MESH_FENCE  concrete parapet + white posts + see-through mesh (city, viaducts)
##   NOISE_WALL  concrete parapet + tall ribbed grey panels on H-posts (city)
##   RETAINING   trench wall, rises with the ground toward an urban tunnel
##   PARAPET     concrete parapet + one low metal rail (the open sea stretch)

const M := RoadMetrics.UNIT_SCALE

const JERSEY_OFFSET := 0.35 * M # RoadGenerator.FENCE_PROFILE is centred this far out

# Guardrail
const RAIL_PROFILE: Array[Vector2] = [ # a single W-beam sheet, road side, drawn double-sided
	Vector2(0.24 * M, 0.45 * M), Vector2(0.17 * M, 0.54 * M), Vector2(0.24 * M, 0.625 * M),
	Vector2(0.17 * M, 0.71 * M), Vector2(0.24 * M, 0.80 * M),
]
const RAIL_POST_SPACING := 2.0 * M
const RAIL_POST_U := 0.36 * M
const RAIL_POST_HEIGHT := 0.85 * M
const RAIL_POST_RADIUS := 0.07 * M

# Concrete parapet under the mesh fence / noise wall.
const PARAPET_HEIGHT := 0.95 * M
const PARAPET_PROFILE: Array[Vector2] = [
	Vector2(0.05 * M, -0.05 * M), Vector2(0.05 * M, 0.88 * M), Vector2(0.10 * M, PARAPET_HEIGHT),
	Vector2(0.40 * M, PARAPET_HEIGHT), Vector2(0.45 * M, 0.88 * M), Vector2(0.45 * M, -0.05 * M),
]

# Mesh fence
const MESH_U := 0.25 * M
const MESH_TOP := 3.0 * M
const MESH_POST_SPACING := 2.5 * M
const MESH_POST_SIZE := 0.08 * M

# Parapet (sea stretch): a metal rail on short posts above the concrete.
const PARAPET_RAIL_TOP := 1.35 * M
const PARAPET_POST_SPACING := 2.0 * M

# Noise wall
const PANEL_U0 := 0.20 * M
const PANEL_U1 := 0.30 * M
const PANEL_TOP := 4.0 * M
const PANEL_POST_SPACING := 4.0 * M
const PANEL_POST_SIZE := Vector2(0.22, 0.22) * M

# Retaining wall
const RETAIN_U0 := 0.05 * M
const RETAIN_U1 := 0.65 * M
const RETAIN_COPING := 0.4 * M # how far the wall top stands above the lifted ground

# Crash cushion in front of a closing lane's angled barrier.
const CUSHION_SIZE := Vector3(0.9, 1.0, 3.0) * M # width, height, length
const CUSHION_SEGMENTS := 6
const CUSHION_OFFSET := 4.0 * M # past where the barrier starts angling in

static var _mats: Dictionary = {}
static var _meshes: Dictionary = {} # post / reflector meshes, shared by every chunk

## `gen` is the RoadGenerator (path, layout, position helpers, shared materials).
static func build(gen, chunk: Node3D, start_dist: float, end_dist: float, side: float) -> void:
	var layout: RoadLayout = gen.layout
	var sub_len: float = RoadPath.SEG_LEN / float(gen.ROW_SUBDIVISIONS)
	var n: int = int(round((end_dist - start_dist) / sub_len))
	var runs: Array = []
	var cur := -1
	var run_start := start_dist
	for i in n:
		var d0: float = start_dist + float(i) * sub_len
		var t: int = layout.barrier_type(d0 + sub_len * 0.5, side)
		if t != cur:
			if cur >= 0:
				runs.append([cur, run_start, d0])
			cur = t
			run_start = d0
	runs.append([cur, run_start, end_dist])

	var container := Node3D.new()
	container.name = "Barrier_%s" % ("L" if side > 0.0 else "R")
	chunk.add_child(container)
	for r in runs:
		var type: int = r[0]
		var a: float = r[1]
		var b: float = r[2]
		# End caps only where the barrier really ends, not at chunk seams.
		var cap_a: bool = layout.barrier_type(a - sub_len * 0.5, side) != type
		var cap_b: bool = layout.barrier_type(b + sub_len * 0.5, side) != type
		match type:
			RoadLayout.Barrier.JERSEY:
				var prof: Array[Vector2] = []
				for p in gen.FENCE_PROFILE:
					prof.append(Vector2(p.x + JERSEY_OFFSET, p.y))
				container.add_child(_swept(gen, a, b, side, _const(prof), cap_a, cap_b, gen._barrier_material))
			RoadLayout.Barrier.GUARDRAIL:
				container.add_child(_swept(gen, a, b, side, _const(RAIL_PROFILE), false, false, _mat("rail"), false))
				container.add_child(_posts(gen, a, b, side, RAIL_POST_SPACING, RAIL_POST_U, 0.0, RAIL_POST_HEIGHT, _cylinder(RAIL_POST_RADIUS, RAIL_POST_HEIGHT), _mat("post_white")))
			RoadLayout.Barrier.MESH_FENCE:
				container.add_child(_swept(gen, a, b, side, _const(PARAPET_PROFILE), cap_a, cap_b, _mat("parapet")))
				container.add_child(_swept(gen, a, b, side, _const([Vector2(MESH_U, PARAPET_HEIGHT), Vector2(MESH_U, MESH_TOP)]), false, false, _mat("mesh"), false))
				var rail := _box_profile(MESH_U, MESH_TOP, 0.06 * M)
				container.add_child(_swept(gen, a, b, side, _const(rail), cap_a, cap_b, _mat("post_white")))
				container.add_child(_posts(gen, a, b, side, MESH_POST_SPACING, MESH_U, PARAPET_HEIGHT, MESH_TOP, _box(Vector3(MESH_POST_SIZE, MESH_TOP - PARAPET_HEIGHT, MESH_POST_SIZE)), _mat("post_white")))
			RoadLayout.Barrier.PARAPET:
				container.add_child(_swept(gen, a, b, side, _const(PARAPET_PROFILE), cap_a, cap_b, _mat("parapet")))
				var top_rail := _box_profile(MESH_U, PARAPET_RAIL_TOP, 0.05 * M)
				container.add_child(_swept(gen, a, b, side, _const(top_rail), cap_a, cap_b, _mat("rail")))
				var post_h: float = PARAPET_RAIL_TOP - PARAPET_HEIGHT
				container.add_child(_posts(gen, a, b, side, PARAPET_POST_SPACING, MESH_U, PARAPET_HEIGHT, PARAPET_RAIL_TOP, _box(Vector3(0.06 * M, post_h, 0.06 * M)), _mat("rail")))
			RoadLayout.Barrier.NOISE_WALL:
				container.add_child(_swept(gen, a, b, side, _const(PARAPET_PROFILE), cap_a, cap_b, _mat("parapet")))
				var panel: Array[Vector2] = [
					Vector2(PANEL_U0, PARAPET_HEIGHT - 0.02 * M), Vector2(PANEL_U0, PANEL_TOP),
					Vector2(PANEL_U1, PANEL_TOP), Vector2(PANEL_U1, PARAPET_HEIGHT - 0.02 * M),
				]
				container.add_child(_swept(gen, a, b, side, _const(panel), cap_a, cap_b, _mat("panel")))
				var post_h: float = PANEL_TOP + 0.1 * M - PARAPET_HEIGHT
				container.add_child(_posts(gen, a, b, side, PANEL_POST_SPACING, (PANEL_U0 + PANEL_U1) * 0.5, PARAPET_HEIGHT, PANEL_TOP + 0.1 * M, _box(Vector3(PANEL_POST_SIZE.x, post_h, PANEL_POST_SIZE.y)), _mat("post_grey")))
			RoadLayout.Barrier.RETAINING:
				var fn := func(d: float) -> Array[Vector2]:
					var lifted: float = layout.lift(d, side * (absf(layout.shoulder_edge(d, side)) + RETAIN_U1 + 0.5 * M))
					var top: float = maxf(gen.FENCE_HEIGHT, lifted + RETAIN_COPING)
					return [
						Vector2(RETAIN_U0, -0.05 * M), Vector2(RETAIN_U0, top),
						Vector2(RETAIN_U1, top), Vector2(RETAIN_U1, minf(lifted, top) - 0.05 * M),
					]
				container.add_child(_swept(gen, a, b, side, fn, cap_a, cap_b, _mat("retaining")))
	var reflectors := _delineators(gen, start_dist, end_dist, side)
	if reflectors:
		container.add_child(reflectors)
	if side > 0.0:
		_crash_cushions(gen, chunk, start_dist, end_dist)

static func _const(profile: Array) -> Callable:
	var typed: Array[Vector2] = []
	for p in profile:
		typed.append(p)
	return func(_d: float) -> Array[Vector2]: return typed

## Closed square tube profile centred on (u, h).
static func _box_profile(u: float, h: float, s: float) -> Array[Vector2]:
	return [Vector2(u - s, h - s), Vector2(u - s, h + s), Vector2(u + s, h + s), Vector2(u + s, h - s)]

## Sweeps `profile_fn(d)` (profile at distance d) from `a` to `b` on `side`.
## Same winding/normal convention as the road ribbon: points sorted by
## increasing signed lateral (reversed on the -1 side), each segment's normal
## is its direction rotated 90 degrees CCW. UV = (distance, height) in world
## units, which barrier_concrete.gdshader and the panel/mesh shaders key off.
static func _swept(gen, a: float, b: float, side: float, profile_fn: Callable,
		cap_a: bool, cap_b: bool, mat: Material, solid: bool = true) -> MeshInstance3D:
	var layout: RoadLayout = gen.layout
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sub_len: float = RoadPath.SEG_LEN / float(gen.ROW_SUBDIVISIONS)
	var n: int = maxi(1, int(round((b - a) / sub_len)))
	var step: float = (b - a) / float(n)
	var rows: Array = [] # per sample: {pts: Array[Vector3], prof: Array[Vector2] (signed), lat: Vector3}
	for i in n + 1:
		var d: float = a + float(i) * step
		var edge: float = layout.shoulder_edge(d, side)
		var prof: Array[Vector2] = []
		for p in profile_fn.call(d):
			prof.append(Vector2(edge + side * p.x, p.y))
		if side < 0.0:
			prof.reverse()
		var pts: Array[Vector3] = []
		for p in prof:
			pts.append(gen._edge_level_pos(d, p.x) + Vector3(0, p.y, 0))
		rows.append({"d": d, "pts": pts, "prof": prof, "lat": gen._right_dir(d)})
	for i in n:
		var r0: Dictionary = rows[i]
		var r1: Dictionary = rows[i + 1]
		for k in r0.prof.size() - 1:
			var p: Vector2 = r0.prof[k]
			var q: Vector2 = r0.prof[k + 1]
			var t: Vector2 = (q - p).normalized()
			var n2 := Vector2(-t.y, t.x)
			var n0: Vector3 = (r0.lat * n2.x + Vector3.UP * n2.y).normalized()
			var n1: Vector3 = (r1.lat * n2.x + Vector3.UP * n2.y).normalized()
			var p1: Vector2 = r1.prof[k]
			var q1: Vector2 = r1.prof[k + 1]
			st.set_normal(n0); st.set_uv(Vector2(r0.d, p.y)); st.add_vertex(r0.pts[k])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, q.y)); st.add_vertex(r0.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, q1.y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, p.y)); st.add_vertex(r0.pts[k])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, q1.y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, p1.y)); st.add_vertex(r1.pts[k])
	if solid:
		if cap_a:
			_cap(st, rows[0], -1.0, gen)
		if cap_b:
			_cap(st, rows[n], 1.0, gen)
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	mi.material_override = mat
	return mi

## Flat fan closing a profile's open end, drawn both ways round so the
## winding never matters. `dir` = -1 at a run's start, +1 at its end.
static func _cap(st: SurfaceTool, row: Dictionary, dir: float, gen) -> void:
	var pts: Array = row.pts
	var c := Vector3.ZERO
	for p in pts:
		c += p
	c /= float(pts.size())
	var h: float = gen.path.road_frame(row.d).heading
	var nrm := Vector3(sin(h), 0.0, cos(h)) * dir
	for k in pts.size():
		var p0: Vector3 = pts[k]
		var p1: Vector3 = pts[(k + 1) % pts.size()]
		for tri in [[c, p0, p1], [c, p1, p0]]:
			for v in tri:
				st.set_normal(nrm)
				st.set_uv(Vector2(row.d, v.y - c.y))
				st.add_vertex(v)

## Posts on global multiples of `spacing` (no seams at chunk borders), mesh
## origin at its centre, standing from h0 to h1 at offset `u`.
static func _posts(gen, a: float, b: float, side: float, spacing: float, u: float,
		h0: float, h1: float, mesh: Mesh, mat: Material) -> MultiMeshInstance3D:
	var layout: RoadLayout = gen.layout
	var xforms: Array[Transform3D] = []
	var d: float = ceilf(a / spacing) * spacing
	while d < b:
		var lat: float = layout.shoulder_edge(d, side) + side * u
		var f: Dictionary = gen.path.road_frame(d)
		var pos: Vector3 = gen._edge_level_pos(d, lat) + Vector3(0, (h0 + h1) * 0.5, 0)
		xforms.append(Transform3D(Basis(Vector3.UP, f.heading), pos))
		d += spacing
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	return mmi

static func _cylinder(r: float, h: float) -> CylinderMesh:
	var key := "cyl_%s_%s" % [r, h]
	if not _meshes.has(key):
		var m := CylinderMesh.new()
		m.top_radius = r
		m.bottom_radius = r
		m.height = h
		m.radial_segments = 8
		m.rings = 1
		_meshes[key] = m
	return _meshes[key]

static func _box(size: Vector3) -> BoxMesh:
	var key := "box_%s" % size
	if not _meshes.has(key):
		var m := BoxMesh.new()
		m.size = size
		_meshes[key] = m
	return _meshes[key]

static func _mat(key: String) -> Material:
	if _mats.has(key):
		return _mats[key]
	var m: Material
	match key:
		"rail":
			var s := StandardMaterial3D.new()
			s.albedo_color = Color(0.80, 0.82, 0.85)
			s.metallic = 0.7
			s.roughness = 0.35
			s.cull_mode = BaseMaterial3D.CULL_DISABLED
			m = s
		"post_white":
			var s := StandardMaterial3D.new()
			s.albedo_color = Color(0.88, 0.89, 0.9)
			s.roughness = 0.5
			m = s
		"post_grey":
			var s := StandardMaterial3D.new()
			s.albedo_color = Color(0.55, 0.57, 0.6)
			s.metallic = 0.4
			s.roughness = 0.5
			m = s
		"parapet":
			var s := ShaderMaterial.new()
			s.shader = preload("res://MAIN/road/barrier_concrete.gdshader")
			s.set_shader_parameter("base_color", Color(0.72, 0.72, 0.70))
			m = s
		"retaining":
			var s := ShaderMaterial.new()
			s.shader = preload("res://MAIN/road/barrier_concrete.gdshader")
			s.set_shader_parameter("base_color", Color(0.50, 0.50, 0.48))
			s.set_shader_parameter("panel_length", 9.0)
			m = s
		"mesh":
			var s := ShaderMaterial.new()
			s.shader = preload("res://MAIN/road/mesh_fence.gdshader")
			m = s
		"panel":
			var s := ShaderMaterial.new()
			s.shader = preload("res://MAIN/road/noise_wall.gdshader")
			s.set_shader_parameter("panel_length", PANEL_POST_SPACING)
			m = s
		"cushion":
			var s := StandardMaterial3D.new()
			s.vertex_color_use_as_albedo = true
			s.roughness = 0.6
			m = s
	_mats[key] = m
	return m

## Where a type's road-facing surface is for the reflectors: (u, h).
static func _face(gen, type: int) -> Vector2:
	match type:
		RoadLayout.Barrier.JERSEY:
			# The jersey's upper face slopes away as it rises - use where it
			# reaches furthest in, at the plate's bottom edge.
			var lo: Vector2 = gen.FENCE_PROFILE[1]
			var hi: Vector2 = gen.FENCE_PROFILE[2]
			var bottom_h: float = gen.DELINEATOR_HEIGHT - gen.DELINEATOR_SIZE.y * 0.5
			return Vector2(lerpf(lo.x, hi.x, (bottom_h - lo.y) / (hi.y - lo.y)) + JERSEY_OFFSET, gen.DELINEATOR_HEIGHT)
		RoadLayout.Barrier.GUARDRAIL:
			return Vector2(0.17 * M, 0.625 * M)
		RoadLayout.Barrier.MESH_FENCE, RoadLayout.Barrier.NOISE_WALL, RoadLayout.Barrier.PARAPET:
			return Vector2(0.05 * M, 0.6 * M)
		RoadLayout.Barrier.RETAINING:
			return Vector2(RETAIN_U0, gen.DELINEATOR_HEIGHT)
	return Vector2(-1.0, 0.0)

## Row of yellow reflector plates on the barrier's road face, only where the
## road curves hard enough (RoadGenerator.DELINEATOR_CURVE_THRESHOLD). Sampled
## on global multiples of DELINEATOR_SPACING so spacing never seams at chunk
## borders. Unlit by ambient - see delineator.gdshader. Null on a straight
## stretch (no plates).
static func _delineators(gen, start_dist: float, end_dist: float, side: float) -> MultiMeshInstance3D:
	var layout: RoadLayout = gen.layout
	# Upright tab turned about vertical so its road-facing side swings back
	# toward approaching traffic (flush on the wall it was seen nearly
	# edge-on). -side mirrors it so both walls angle back down the road.
	var yaw_rad: float = deg_to_rad(gen.DELINEATOR_YAW_DEG)
	var yaw := Basis(Vector3.UP, -side * yaw_rad)
	# Stand off far enough that the rotated plate's back edge clears the wall.
	var clearance: float = gen.DELINEATOR_SIZE.x * 0.5 * sin(yaw_rad) + gen.DELINEATOR_SIZE.z

	var transforms: Array[Transform3D] = []
	var d: float = ceilf(start_dist / gen.DELINEATOR_SPACING) * gen.DELINEATOR_SPACING
	while d < end_dist:
		var f: Dictionary = gen.path.road_frame(d)
		if absf(f.curvature) >= gen.DELINEATOR_CURVE_THRESHOLD:
			var face := _face(gen, layout.barrier_type(d, side))
			if face.x >= 0.0:
				var lat: float = layout.shoulder_edge(d, side) + side * (face.x - clearance)
				var pos: Vector3 = gen._edge_level_pos(d, lat) + Vector3(0, face.y, 0)
				transforms.append(Transform3D(Basis(Vector3.UP, f.heading) * yaw, pos))
		d += gen.DELINEATOR_SPACING
	if transforms.is_empty():
		return null

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	# Local X = lateral (plate thickness), Y = up, Z = along the road.
	mm.mesh = _box(Vector3(gen.DELINEATOR_SIZE.z, gen.DELINEATOR_SIZE.y, gen.DELINEATOR_SIZE.x))
	mm.instance_count = transforms.size()
	for i in range(transforms.size()):
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = gen._delineator_material
	return mmi

## Red/white striped crash cushion where a closing lane's barrier starts to
## angle in, lined up with the angled barrier, plus a collision box on the
## chunk body (so CrashSystem treats it like the guardrail).
static func _crash_cushions(gen, chunk: Node3D, start_dist: float, end_dist: float) -> void:
	var layout: RoadLayout = gen.layout
	for c in layout.closures:
		var d: float = c.start + RoadLayout.LANE_TAPER_LEN + CUSHION_OFFSET
		if d < start_dist or d >= end_dist:
			continue
		var half_len: float = CUSHION_SIZE.z * 0.5
		var lat: float = layout.shoulder_edge(d, 1.0) - CUSHION_SIZE.x * 0.5
		var back: Vector3 = gen._edge_level_pos(d - half_len, layout.shoulder_edge(d - half_len, 1.0) - CUSHION_SIZE.x * 0.5)
		var front: Vector3 = gen._edge_level_pos(d + half_len, layout.shoulder_edge(d + half_len, 1.0) - CUSHION_SIZE.x * 0.5)
		var center: Vector3 = gen._edge_level_pos(d, lat) + Vector3(0, CUSHION_SIZE.y * 0.5, 0)
		var along: Vector3 = front - back
		along.y = 0.0
		var basis := Basis(Vector3.UP, atan2(along.x, along.z))
		var xform := Transform3D(basis, center)

		var seg_len: float = CUSHION_SIZE.z / float(CUSHION_SEGMENTS)
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _box(Vector3(CUSHION_SIZE.x, CUSHION_SIZE.y, seg_len * 0.98))
		mm.instance_count = CUSHION_SEGMENTS
		for i in CUSHION_SEGMENTS:
			var z: float = -CUSHION_SIZE.z * 0.5 + seg_len * (float(i) + 0.5)
			mm.set_instance_transform(i, xform * Transform3D(Basis.IDENTITY, Vector3(0, 0, z)))
			mm.set_instance_color(i, Color(0.85, 0.08, 0.06) if i % 2 == 0 else Color(0.92, 0.92, 0.9))
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "CrashCushion"
		mmi.multimesh = mm
		mmi.material_override = _mat("cushion")
		chunk.add_child(mmi)

		var shape := BoxShape3D.new()
		shape.size = CUSHION_SIZE
		var col := CollisionShape3D.new()
		col.shape = shape
		col.transform = xform
		chunk.add_child(col)
