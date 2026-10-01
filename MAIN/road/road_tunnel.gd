class_name RoadTunnel
extends RefCounted

## Tunnel geometry for one chunk: the interior shell (walkways, white tiled
## walls, grey arch), sodium lamp rows, ceiling jet fans, glowing emergency
## boxes, and the portal headwalls (with a name plate on the way in). Which
## stretches are tunnels, their style (hill / urban trench) and the ground
## lifted over them all come from RoadLayout; the lid/hill surface itself is
## just the terrain following RoadGenerator._ground_pos.
##
## The cross-section is swept in the road's BANKED frame (it tilts with the
## road through curves) around the tunnel centre, which sits between the
## 3-lane shoulder edges. Profile coords are (u, h): u across from that centre
## (+ = left), h up from the banked road surface.
##
## Lighting: the lamp rows are emissive fittings only; their light on the
## walls/road is faked in tunnel_wall.gdshader / road_surface.gdshader.
## TunnelRig (tunnel_rig.gd) adds a few real moving lights near the player.

const M := RoadMetrics.UNIT_SCALE

const LAMP_COLOR := Color(1.0, 0.55, 0.2) # low-pressure sodium
const LAMP_SPACING := 4.0 * M
const LAMP_SIZE := Vector3(0.22, 0.16, 1.1) * M # depth, height, length
## Fake light on the road inside (road_surface.gdshader's tunnel_glow).
const ROAD_GLOW := 1.4

const WALKWAY := 0.75 * M # raised walkway between the shoulder edge and the wall
const CURB := 0.25 * M
const WALL_HEIGHT := 4.2 * M # tiled part; the arch springs from here
const ARCH_RISE := 4.4 * M
const ARCH_SEGMENTS := 12

const FAN_SPACING := 180.0 * M
const FAN_PORTAL_CLEAR := 80.0 * M
const FAN_RADIUS := 0.6 * M
const FAN_LENGTH := 4.0 * M
const FAN_OFFSET := 3.0 * M # either side of the centre
const FAN_DROP := 1.4 * M # fan axis below the arch surface above it

const BOX_SPACING := 90.0 * M
const PORTAL_EXTRA := 0.4 * M # trench headwall top stands this far above the lid (coping)
const PLATE_SIZE := Vector2(6.0, 0.75) * M
const PLATE_ROWS := 8
const PLATE_TEXTURE_PATH := "res://assets/road/tunnel_plates.png"
const PORTAL_DEEP := -20.0 * M # outline sides extended down to here (see _headwall)

static var _mats: Dictionary = {}

## `gen` is the RoadGenerator.
static func build(gen, chunk: Node3D, start_dist: float, end_dist: float) -> void:
	var layout: RoadLayout = gen.layout
	for t in layout.tunnels:
		if t.taper_end < start_dist or t.taper_start > end_dist:
			continue
		var a: float = maxf(start_dist, t.portal_in)
		var b: float = minf(end_dist, t.portal_out)
		if a < b:
			var node := Node3D.new()
			node.name = "Tunnel"
			chunk.add_child(node)
			node.add_child(_shell(gen, a, b))
			node.add_child(_lamps(gen, a, b))
			node.add_child(_fans(gen, t, a, b))
			node.add_child(_boxes(gen, t, a, b))
		if t.portal_in >= start_dist and t.portal_in < end_dist:
			chunk.add_child(_headwall(gen, t, t.portal_in, 1.0))
			chunk.add_child(_plate(gen, t))
		if t.portal_out >= start_dist and t.portal_out < end_dist:
			chunk.add_child(_headwall(gen, t, t.portal_out, -1.0))

## Banked tunnel frame at d: {origin (road surface at the tunnel centre), lat, up, fwd}.
static func _frame(gen, d: float) -> Dictionary:
	var f: Dictionary = gen.path.road_frame(d)
	var right0 := Vector3(cos(f.heading), 0.0, -sin(f.heading))
	return {
		"origin": gen.path.world_pos(d, RoadLayout.tunnel_center_lateral()),
		"lat": right0 * cos(f.bank) + Vector3.UP * sin(f.bank),
		"up": -right0 * sin(f.bank) + Vector3.UP * cos(f.bank),
		"fwd": Vector3(sin(f.heading), 0.0, cos(f.heading)),
		"heading": f.heading,
	}

static func _pt(fr: Dictionary, u: float, h: float) -> Vector3:
	return fr.origin + fr.lat * u + fr.up * h

## Half-widths at d: to the shoulder edge (curb face) and to the tiled wall.
static func _half(gen, d: float) -> Vector2:
	var w: float = (gen.layout.shoulder_edge(d, 1.0) - gen.layout.shoulder_edge(d, -1.0)) * 0.5
	return Vector2(w, w + WALKWAY)

## Interior profile, LEFT to RIGHT (decreasing u) so the swept faces point
## inward. Each entry: [Vector2(u, h), surface index of the segment that
## starts there] - 0 tiles, 1 arch, 2 walkway/curb.
static func _profile(half: Vector2) -> Array:
	var w: float = half.x
	var ww: float = half.y
	var p: Array = [
		[Vector2(w, 0.0), 2], [Vector2(w, CURB), 2], [Vector2(ww, CURB), 0], [Vector2(ww, WALL_HEIGHT), 1],
	]
	for i in range(1, ARCH_SEGMENTS):
		var ang: float = PI * float(i) / float(ARCH_SEGMENTS)
		p.append([Vector2(ww * cos(ang), WALL_HEIGHT + ARCH_RISE * sin(ang)), 1])
	p.append_array([
		[Vector2(-ww, WALL_HEIGHT), 0], [Vector2(-ww, CURB), 2], [Vector2(-w, CURB), 2], [Vector2(-w, 0.0), -1],
	])
	return p

static func crown_height() -> float:
	return WALL_HEIGHT + ARCH_RISE

static func _shell(gen, a: float, b: float) -> MeshInstance3D:
	var tools: Array[SurfaceTool] = []
	for i in 3:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools.append(st)
	var sub_len: float = RoadPath.SEG_LEN / float(gen.ROW_SUBDIVISIONS)
	var n: int = maxi(1, int(ceil((b - a) / sub_len)))
	var step: float = (b - a) / float(n)
	var rows: Array = []
	for i in n + 1:
		var d: float = a + float(i) * step
		var fr := _frame(gen, d)
		var prof := _profile(_half(gen, d))
		var pts: Array[Vector3] = []
		for e in prof:
			pts.append(_pt(fr, e[0].x, e[0].y))
		rows.append({"d": d, "fr": fr, "prof": prof, "pts": pts})
	for i in n:
		var r0: Dictionary = rows[i]
		var r1: Dictionary = rows[i + 1]
		for k in r0.prof.size() - 1:
			var surf: int = r0.prof[k][1]
			var st: SurfaceTool = tools[surf]
			var p: Vector2 = r0.prof[k][0]
			var q: Vector2 = r0.prof[k + 1][0]
			var t: Vector2 = (q - p).normalized()
			var n2 := Vector2(-t.y, t.x)
			var n0: Vector3 = (r0.fr.lat * n2.x + r0.fr.up * n2.y).normalized()
			var n1: Vector3 = (r1.fr.lat * n2.x + r1.fr.up * n2.y).normalized()
			var p1: Vector2 = r1.prof[k][0]
			var q1: Vector2 = r1.prof[k + 1][0]
			st.set_normal(n0); st.set_uv(Vector2(r0.d, p.y)); st.add_vertex(r0.pts[k])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, q.y)); st.add_vertex(r0.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, q1.y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n0); st.set_uv(Vector2(r0.d, p.y)); st.add_vertex(r0.pts[k])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, q1.y)); st.add_vertex(r1.pts[k + 1])
			st.set_normal(n1); st.set_uv(Vector2(r1.d, p1.y)); st.add_vertex(r1.pts[k])
	var mesh := ArrayMesh.new()
	for i in 3:
		tools[i].commit(mesh)
	var mi := MeshInstance3D.new()
	mi.name = "Shell"
	mi.mesh = mesh
	for i in 3:
		mi.set_surface_override_material(i, _wall_mat(i))
	return mi

static func _wall_mat(mode: int) -> ShaderMaterial:
	var key := "wall_%d" % mode
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = preload("res://MAIN/road/tunnel_wall.gdshader")
		m.set_shader_parameter("mode", mode)
		m.set_shader_parameter("lamp_color", LAMP_COLOR)
		m.set_shader_parameter("lamp_line_height", WALL_HEIGHT + 0.25 * M)
		m.set_shader_parameter("lamp_spacing", LAMP_SPACING)
		_mats[key] = m
	return _mats[key]

static func _emissive_mat(energy: float) -> ShaderMaterial:
	var key := "glow_%s" % energy
	if not _mats.has(key):
		var m := ShaderMaterial.new()
		m.shader = preload("res://MAIN/road/tunnel_emissive.gdshader")
		m.set_shader_parameter("energy", energy)
		_mats[key] = m
	return _mats[key]

static func _multimesh(mesh: Mesh, xforms: Array, colors: Array, mat: Material, node_name: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if mm.use_colors:
			mm.set_instance_color(i, colors[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	mmi.material_override = mat
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mmi

static func _basis(fr: Dictionary) -> Basis:
	return Basis(fr.lat, fr.up, fr.fwd)

## Two rows of lamp fittings where the arch springs from the tiles, on global
## multiples of LAMP_SPACING (no seams at chunk borders).
static func _lamps(gen, a: float, b: float) -> MultiMeshInstance3D:
	var xforms: Array = []
	var d: float = ceilf(a / LAMP_SPACING) * LAMP_SPACING
	while d < b:
		var fr := _frame(gen, d)
		var ww: float = _half(gen, d).y
		for side in [-1.0, 1.0]:
			xforms.append(Transform3D(_basis(fr), _pt(fr, side * (ww - LAMP_SIZE.x * 0.5), WALL_HEIGHT + 0.25 * M)))
		d += LAMP_SPACING
	var box := BoxMesh.new()
	box.size = LAMP_SIZE
	var colors: Array = []
	colors.resize(xforms.size())
	colors.fill(LAMP_COLOR)
	return _multimesh(box, xforms, colors, _emissive_mat(6.0), "Lamps")

## Pairs of jet fans hanging under the crown.
static func _fans(gen, t: Dictionary, a: float, b: float) -> MultiMeshInstance3D:
	var xforms: Array = []
	var lo: float = maxf(a, t.portal_in + FAN_PORTAL_CLEAR)
	var hi: float = minf(b, t.portal_out - FAN_PORTAL_CLEAR)
	var d: float = ceilf(lo / FAN_SPACING) * FAN_SPACING
	while d < hi:
		var fr := _frame(gen, d)
		var ww: float = _half(gen, d).y
		var arch_h: float = WALL_HEIGHT + ARCH_RISE * sqrt(maxf(0.0, 1.0 - pow(FAN_OFFSET / ww, 2.0)))
		for side in [-1.0, 1.0]:
			var basis: Basis = _basis(fr) * Basis(Vector3.RIGHT, PI * 0.5) # cylinder axis along the road
			xforms.append(Transform3D(basis, _pt(fr, side * FAN_OFFSET, arch_h - FAN_DROP)))
		d += FAN_SPACING
	var cyl := CylinderMesh.new()
	cyl.top_radius = FAN_RADIUS
	cyl.bottom_radius = FAN_RADIUS
	cyl.height = FAN_LENGTH
	cyl.radial_segments = 12
	cyl.rings = 1
	if not _mats.has("fan"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.32, 0.33, 0.34)
		m.metallic = 0.6
		m.roughness = 0.45
		_mats["fan"] = m
	return _multimesh(cyl, xforms, [], _mats["fan"], "JetFans")

## Glowing boxes on the walls every BOX_SPACING, alternating sides: a white
## extinguisher cabinet with a red lamp above it, a green emergency-exit sign,
## or a teal emergency-phone sign (picked per slot from the tunnel's seed).
static func _boxes(gen, t: Dictionary, a: float, b: float) -> MultiMeshInstance3D:
	var xforms: Array = []
	var colors: Array = []
	var d: float = ceilf(a / BOX_SPACING) * BOX_SPACING
	while d < b:
		var slot := int(round(d / BOX_SPACING))
		if d > t.portal_in + 20.0 * M and d < t.portal_out - 20.0 * M:
			var side: float = 1.0 if slot % 2 == 0 else -1.0
			var kind: int = absi(hash(Vector2i(slot, t.noise_seed))) % 3
			var fr := _frame(gen, d)
			var u: float = side * (_half(gen, d).y - 0.06 * M)
			var items: Array = []
			match kind:
				0:
					items.append([Vector3(0.12, 0.9, 1.0), 1.5, Color(1.0, 0.97, 0.9)])
					items.append([Vector3(0.12, 0.18, 0.18), 2.25, Color(1.0, 0.1, 0.05)])
				1:
					items.append([Vector3(0.12, 0.45, 0.8), 2.5, Color(0.1, 0.9, 0.35)])
				2:
					items.append([Vector3(0.12, 0.75, 0.55), 1.9, Color(0.2, 0.75, 0.9)])
			for it in items:
				var size: Vector3 = it[0] * M
				var basis: Basis = _basis(fr) * Basis.from_scale(size)
				xforms.append(Transform3D(basis, _pt(fr, u, it[1] * M)))
				colors.append(it[2])
		d += BOX_SPACING
	var box := BoxMesh.new() # unit box, scaled per instance
	return _multimesh(box, xforms, colors, _emissive_mat(1.6), "LightBoxes")

## Concrete face closing the lid/hill around a portal, with the tunnel arch
## cut out of it. Built in the vertical plane across the road at `dp`: the
## outline of the ground just inside the portal (hill or trench lid) and the
## arch are both sampled as rays from a point under the tunnel centre, and the
## band between them is filled - both outlines are star-shaped around that
## point, so the fill never folds. Drawn double-sided. `inward` = +1 if the
## tunnel lies ahead (+distance) of dp.
##
## Both outlines' sides are extended far below the road (PORTAL_DEEP): on a
## banked portal one side of the arch tilts up past the ray origin, and the
## near-horizontal rays used to slip under it, miss the arch and fill from
## the origin - a sliver of wall across the opening. Any ray where the ground
## isn't beyond the arch (missed, or the lid/hill is still lower than the
## arch there) gets no wall rather than a folded one.
static func _headwall(gen, t: Dictionary, dp: float, inward: float) -> MeshInstance3D:
	var fr := _frame(gen, dp)
	var right0 := Vector3(cos(fr.heading), 0.0, -sin(fr.heading))
	var o: Vector3 = fr.origin
	var to2d := func(p: Vector3) -> Vector2: return Vector2((p - o).dot(right0), p.y - o.y)
	var half := _half(gen, dp)
	var below := -1.0 * M

	var hole: Array[Vector2] = [to2d.call(_pt(fr, half.y, below))]
	for i in ARCH_SEGMENTS + 1:
		var ang: float = PI * float(i) / float(ARCH_SEGMENTS)
		hole.append(to2d.call(_pt(fr, half.y * cos(ang), WALL_HEIGHT + ARCH_RISE * sin(ang))))
	hole.append(to2d.call(_pt(fr, -half.y, below)))
	hole.insert(0, Vector2(hole[0].x, PORTAL_DEEP))
	hole.append(Vector2(hole[hole.size() - 1].x, PORTAL_DEEP))

	var di: float = dp + inward * 0.5 * M # sample the ground just inside
	var c: float = RoadLayout.tunnel_center_lateral()
	var reach: float
	var extra := 0.0
	if t.style == RoadLayout.Portal.HILL:
		reach = RoadLayout.HILL_PORTAL_TOP + RoadLayout.HILL_PORTAL_HEIGHT / RoadLayout.HILL_PORTAL_SLOPE + 1.0 * M
	else:
		reach = half.x + RoadBarriers.RETAIN_U1
		extra = PORTAL_EXTRA
	var outer: Array[Vector2] = []
	var samples := 32
	for i in samples + 1:
		var lat: float = c + reach - 2.0 * reach * float(i) / float(samples)
		var g: Vector3 = gen._ground_pos(di, lat)
		var v: Vector2 = to2d.call(g)
		outer.append(Vector2(v.x, v.y + extra))
	outer.insert(0, Vector2(outer[0].x, PORTAL_DEEP))
	outer.append(Vector2(outer[outer.size() - 1].x, PORTAL_DEEP))

	var center := Vector2(0.0, below * 0.5)
	var n := 48
	var inner_pts: Array[Vector2] = []
	var outer_pts: Array[Vector2] = []
	for i in n + 1:
		var ang: float = PI * float(i) / float(n)
		var dir := Vector2(cos(ang), sin(ang))
		var t_in := _ray_t(center, dir, hole, false)
		var t_out := _ray_t(center, dir, outer, true)
		if t_in < 0.0 or t_out <= t_in:
			# No ground beyond the arch along this ray - zero-width, no wall.
			t_in = maxf(t_in, t_out)
			t_out = t_in
		inner_pts.append(center + dir * maxf(t_in, 0.0))
		outer_pts.append(center + dir * maxf(t_out, 0.0))

	var to3d := func(v: Vector2) -> Vector3: return o + right0 * v.x + Vector3(0, v.y, 0)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var nrm: Vector3 = -fr.fwd * inward
	for i in n:
		var quad := [inner_pts[i], outer_pts[i], outer_pts[i + 1], inner_pts[i + 1]]
		for tri in [[0, 1, 2], [0, 2, 3], [0, 2, 1], [0, 3, 2]]:
			for k in tri:
				var v: Vector2 = quad[k]
				st.set_normal(nrm)
				st.set_uv(Vector2(v.x, v.y))
				st.add_vertex(to3d.call(v))
	var mi := MeshInstance3D.new()
	mi.name = "Portal"
	mi.mesh = st.commit()
	if not _mats.has("portal"):
		var m := ShaderMaterial.new()
		m.shader = preload("res://MAIN/road/barrier_concrete.gdshader")
		m.set_shader_parameter("base_color", Color(0.62, 0.62, 0.60))
		m.set_shader_parameter("grime_height", 2.0)
		_mats["portal"] = m
	mi.material_override = _mats["portal"]
	return mi

## Distance along a ray from `origin` in `dir` to where it crosses `poly`
## (an open polyline): the nearest crossing, or the farthest if `farthest`.
## -1 if it misses.
static func _ray_t(origin: Vector2, dir: Vector2, poly: Array[Vector2], farthest: bool) -> float:
	var best_t: float = -1.0
	for i in poly.size() - 1:
		var p: Vector2 = poly[i]
		var s: Vector2 = poly[i + 1] - p
		var denom: float = dir.cross(s)
		if absf(denom) < 1e-8:
			continue
		var w: Vector2 = p - origin
		var t: float = w.cross(s) / denom
		var u: float = w.cross(dir) / denom
		if t <= 0.0 or u < 0.0 or u > 1.0:
			continue
		if best_t < 0.0 or (farthest and t > best_t) or (not farthest and t < best_t):
			best_t = t
	return best_t

## Name plate above the entry portal's arch, facing approaching traffic.
static func _plate(gen, t: Dictionary) -> MeshInstance3D:
	var dp: float = t.portal_in
	var fr := _frame(gen, dp)
	var quad := QuadMesh.new()
	quad.size = PLATE_SIZE
	var row: int = absi(int(t.name_index)) % PLATE_ROWS
	var m := StandardMaterial3D.new()
	var tex: Texture2D = load(PLATE_TEXTURE_PATH)
	m.albedo_texture = tex
	m.uv1_scale = Vector3(1.0, 1.0 / float(PLATE_ROWS), 1.0)
	m.uv1_offset = Vector3(0.0, float(row) / float(PLATE_ROWS), 0.0)
	m.emission_enabled = true
	m.emission_texture = tex
	m.emission = Color.WHITE
	m.emission_energy_multiplier = 0.35
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var mi := MeshInstance3D.new()
	mi.name = "NamePlate"
	mi.mesh = quad
	mi.material_override = m
	var pos: Vector3 = fr.origin + Vector3(0, crown_height() + 1.25 * M, 0) - fr.fwd * 0.08 * M
	# QuadMesh faces +Z; turn it to face back down the road at the driver.
	mi.transform = Transform3D(Basis(Vector3.UP, fr.heading + PI), pos)
	return mi
