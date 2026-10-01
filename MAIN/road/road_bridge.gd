class_name RoadBridge
extends RefCounted

## Viaduct structure for one chunk wherever RoadLayout says the road is
## ELEVATED (ramps over land) or over the SEA: a deck slab swept under the
## road (lip to lip, following curves and bank) and a hammerhead pier every
## PIER_SPACING down to the land / into the sea. The deck's top surface and
## its barriers (concrete + mesh) are the road ribbon and RoadBarriers; the
## sea is one camera-following plane (make_sea / update_sea) shown only near
## a bridge. A suspension bridge (RoadSuspension) keeps the deck slab but has
## no piers over the sea - its deck hangs from the cables.

const M := RoadMetrics.UNIT_SCALE
const S := RoadLayout.Surface

const DECK_DEPTH := 1.8 * M # road surface to soffit
const DECK_CHAMFER := 0.6 * M # the slab's outer face drops this far before tucking in
const DECK_TUCK := 1.2 * M # how far in from the lip the soffit starts
const PIER_SPACING := 40.0 * M
const PIER_MIN_HEIGHT := 1.5 * M # no pier where the deck is lower than this above ground
const COLUMN_SIZE := Vector2(3.0, 2.0) * M # lateral, along
const CAP_HEIGHT := 1.5 * M
const CAP_DEPTH := 2.2 * M
const CAP_INSET := 1.0 * M # cap stops this far inside each lip
const SEA_BURY := 2.0 * M # piers run this far below the sea surface

static var _mats: Dictionary = {}

static func build(gen, chunk: Node3D, start_dist: float, end_dist: float) -> void:
	var layout: RoadLayout = gen.layout
	var b: Dictionary = layout.bridge_at(start_dist, gen.CHUNK_LENGTH)
	if b.is_empty():
		return
	var a: float = maxf(start_dist, b.ramp_start)
	var e: float = minf(end_dist, b.ramp_end)
	if a >= e:
		return
	var node := Node3D.new()
	node.name = "Viaduct"
	chunk.add_child(node)
	node.add_child(_deck(gen, a, e))
	var piers := _piers(gen, b, a, e)
	if piers:
		node.add_child(piers)

## Soffit profile at d, listed from the LEFT lip to the right (decreasing
## lateral) so faces point outward/down with the barrier sweep's convention.
## (lateral, height-offset-below-edge-level).
static func _profile(gen, d: float) -> Array[Vector2]:
	var layout: RoadLayout = gen.layout
	var ls: float = layout.shoulder_edge(d, 1.0) + gen.DECK_LIP
	var rs: float = layout.shoulder_edge(d, -1.0) - gen.DECK_LIP
	return [
		Vector2(ls, 0.0), Vector2(ls, -DECK_CHAMFER), Vector2(ls - DECK_TUCK, -DECK_DEPTH),
		Vector2(rs + DECK_TUCK, -DECK_DEPTH), Vector2(rs, -DECK_CHAMFER), Vector2(rs, 0.0),
	]

static func _deck(gen, a: float, b: float) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sub_len: float = RoadPath.SEG_LEN / float(gen.ROW_SUBDIVISIONS)
	var n: int = maxi(1, int(ceil((b - a) / sub_len)))
	var step: float = (b - a) / float(n)
	var rows: Array = []
	for i in n + 1:
		var d: float = a + float(i) * step
		var prof := _profile(gen, d)
		var pts: Array[Vector3] = []
		for p in prof:
			var top: Vector3 = gen._edge_level_pos(d, p.x)
			var y: float = top.y + p.y
			# Near the start of a ramp the deck is barely off the ground - never dig in.
			y = maxf(y, gen._ground_pos(d, p.x).y + 0.05 * M)
			pts.append(Vector3(top.x, minf(y, top.y), top.z))
		rows.append({"d": d, "prof": prof, "pts": pts, "lat": gen._right_dir(d)})
	for i in n:
		var r0: Dictionary = rows[i]
		var r1: Dictionary = rows[i + 1]
		for k in r0.prof.size() - 1:
			var t: Vector2 = (r0.prof[k + 1] - r0.prof[k]).normalized()
			var n2 := Vector2(-t.y, t.x)
			var n0: Vector3 = (r0.lat * n2.x + Vector3.UP * n2.y).normalized()
			var n1: Vector3 = (r1.lat * n2.x + Vector3.UP * n2.y).normalized()
			st.set_normal(n0); st.set_uv(Vector2(r0.d, r0.pts[k].y)); st.add_vertex(r0.pts[k])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, r0.pts[k + 1].y)); st.add_vertex(r0.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, r1.pts[k + 1].y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, r0.pts[k].y)); st.add_vertex(r0.pts[k])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, r1.pts[k + 1].y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, r1.pts[k].y)); st.add_vertex(r1.pts[k])
	var mi := MeshInstance3D.new()
	mi.name = "Deck"
	mi.mesh = st.commit()
	mi.material_override = _concrete()
	return mi

static func _concrete() -> Material:
	if not _mats.has("concrete"):
		var m := ShaderMaterial.new()
		m.shader = preload("res://MAIN/road/barrier_concrete.gdshader")
		m.set_shader_parameter("base_color", Color(0.52, 0.52, 0.50))
		m.set_shader_parameter("panel_length", 40.0)
		m.set_shader_parameter("grime_height", 0.0)
		_mats["concrete"] = m
	return _mats["concrete"]

## Hammerhead piers on global multiples of PIER_SPACING: one column from the
## land (or below the sea surface) up to a cap under the deck. Unit boxes
## scaled per instance, one MultiMesh.
static func _piers(gen, b: Dictionary, a: float, e: float) -> MultiMeshInstance3D:
	var layout: RoadLayout = gen.layout
	var xforms: Array[Transform3D] = []
	var d: float = ceilf(a / PIER_SPACING) * PIER_SPACING
	while d < e:
		# A suspension bridge's deck hangs from its cables (RoadSuspension).
		if b.suspension and layout.surface_mode(d) == S.SEA:
			d += PIER_SPACING
			continue
		var rs: float = layout.shoulder_edge(d, -1.0) - gen.DECK_LIP
		var ls: float = layout.shoulder_edge(d, 1.0) + gen.DECK_LIP
		var mid_lat: float = (rs + ls) * 0.5
		var top: Vector3 = gen.path.world_pos(d, mid_lat)
		var soffit: float = minf(gen._edge_level_pos(d, rs).y, gen._edge_level_pos(d, ls).y) - DECK_DEPTH
		var ground: float
		if layout.surface_mode(d) == S.SEA:
			ground = b.sea_y - SEA_BURY
		else:
			ground = gen._ground_pos(d, mid_lat).y
		if soffit - ground > PIER_MIN_HEIGHT:
			var yaw := Basis(Vector3.UP, gen.path.road_frame(d).heading)
			var cap_w: float = (ls - rs) - 2.0 * CAP_INSET
			var cap_c := Vector3(top.x, soffit - CAP_HEIGHT * 0.5, top.z)
			xforms.append(Transform3D(yaw * Basis.from_scale(Vector3(cap_w, CAP_HEIGHT, CAP_DEPTH)), cap_c))
			var col_h: float = soffit - CAP_HEIGHT - ground + 0.1 * M
			var col_c := Vector3(top.x, ground + col_h * 0.5, top.z)
			xforms.append(Transform3D(yaw * Basis.from_scale(Vector3(COLUMN_SIZE.x, col_h, COLUMN_SIZE.y)), col_c))
		d += PIER_SPACING
	if xforms.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = BoxMesh.new() # 1x1x1
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Piers"
	mmi.multimesh = mm
	if not _mats.has("pier"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.48, 0.48, 0.46)
		m.roughness = 0.9
		_mats["pier"] = m
	mmi.material_override = _mats["pier"]
	return mmi

# --- Sea -------------------------------------------------------------------

const SEA_SIZE := 5000.0 # world units, well past the chase camera's far plane
## The sea shows while the player is within this road distance of a bridge.
const SEA_SHOW_PAD := 700.0 * M
const SEA_GROUP := "sea"

static func make_sea() -> MeshInstance3D:
	var plane := PlaneMesh.new()
	plane.size = Vector2(SEA_SIZE, SEA_SIZE)
	var mi := MeshInstance3D.new()
	mi.name = "Sea"
	mi.mesh = plane
	var m := ShaderMaterial.new()
	m.shader = preload("res://MAIN/road/sea.gdshader")
	mi.material_override = m
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	mi.add_to_group(SEA_GROUP) # skyline.gd finds it to set up the city-light reflection
	return mi

## Shows the sea around the camera at the nearest bridge's sea level, hides
## it elsewhere (land chunks sit above it, so it only shows where there's no
## land - under and around the bridge, out to the horizon skyline).
static func update_sea(gen, sea: MeshInstance3D, dist: float, cam: Camera3D) -> void:
	var b: Dictionary = gen.layout.bridge_at(dist, SEA_SHOW_PAD)
	sea.visible = not b.is_empty() and cam != null
	if sea.visible:
		sea.global_position = Vector3(cam.global_position.x, b.sea_y, cam.global_position.z)
		clip_sea(gen, sea, b)

## Cuts the sea off across the road at both ends of bridge `b` (the ramp
## feet - the land under a ramp stays at shore level, above the sea, but
## past it the road's own grade takes over and can drop below sea level).
static func clip_sea(gen, sea: MeshInstance3D, b: Dictionary) -> void:
	# Same bridge on the same path (a new run brings a new path) - already set.
	var key := "%d:%s" % [gen.path.get_instance_id(), b.ramp_start]
	if sea.get_meta("clip_for", "") == key:
		return
	sea.set_meta("clip_for", key)
	var m: ShaderMaterial = sea.material_override
	m.set_shader_parameter("clip_a", _clip_plane(gen, b.ramp_start, 1.0))
	m.set_shader_parameter("clip_b", _clip_plane(gen, b.ramp_end, -1.0))

## (normal.x, normal.z, offset) of the vertical plane across the road at `d`,
## normal pointing along the road (`dir` 1) or back (-1) toward the water.
static func _clip_plane(gen, d: float, dir: float) -> Vector3:
	var f: Dictionary = gen.path.road_frame(d)
	var n := Vector2(sin(f.heading), cos(f.heading)) * dir
	return Vector3(n.x, n.y, n.dot(Vector2(f.pos.x, f.pos.z)))
