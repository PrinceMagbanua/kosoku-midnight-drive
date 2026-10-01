class_name RoadOverpass
extends RefCounted

## Straight flyovers crossing above the road at RoadLayout.overpasses, each at
## its own skew (0 = square across, up to +-OVERPASS_MAX_SKEW diagonal). Built
## from the Blender kit in assets/road/overpass/ (source:
## C:/My Projects/Kosoku_Road/overpass_kit.blend): 20 m deck modules laid end to
## end along the crossing line, octagonal columns + hammer caps, and an end
## block (abutment) at each end. One MultiMesh per piece per overpass.
##
## The deck is level, CLEARANCE above the higher road edge at the crossing.
## Each half of the span runs out to OVERPASS_REACH but stops early if the
## (curving) road comes back under it, or the ground rises too close to the
## deck - so a diagonal crossing on a bend never lands on the road.
## Buildings, trees and streetlights stay out of its footprint via
## RoadLayout.overpass_blocks().

const M := RoadMetrics.UNIT_SCALE

const CLEARANCE := 5.5 * M # road edge to soffit
const DECK_DEPTH := 1.7 * M # soffit to deck top (the kit's girder)
const CAP_DEPTH := 1.3 * M
const MODULE_LEN := 20.0 * M
const ABUTMENT_LEN := 3.0 * M
const PIER_SPACING := 30.0 * M
## First column this far from the road centre (in the grass strip, clear of
## the barriers), measured square to the road.
const PIER_FIRST_LATERAL := 12.6 * M
const ROAD_KEEP_OUT := 12.0 * M # no column / span closer to any road than this
const GROUND_HEADROOM := 2.5 * M # span ends where the ground gets this close under it
const PROBE_STEP := 10.0 * M

const KIT := {
	"deck": "res://assets/road/overpass/overpass_deck.glb",
	"column": "res://assets/road/overpass/overpass_column.glb",
	"cap": "res://assets/road/overpass/overpass_cap.glb",
	"abutment": "res://assets/road/overpass/overpass_abutment.glb",
}
static var _meshes: Dictionary = {}

static func _mesh(key: String) -> Mesh:
	if not _meshes.has(key):
		var node: Node = (load(KIT[key]) as PackedScene).instantiate()
		_meshes[key] = RoadsideTrees._find_mesh(node)
		node.free()
	return _meshes[key]

static func build(gen, chunk: Node3D, start_dist: float, end_dist: float) -> void:
	for o in gen.layout.overpasses:
		if o.d >= start_dist and o.d < end_dist:
			chunk.add_child(_overpass(gen, o))

## Nearest road position to world point `p`: {dist, lateral}. Same inverse of
## RoadPath.world_pos the traffic uses (projection onto the road's right
## vector, undoing the bank's cos scale).
static func _road_near(gen, p: Vector3, seed_dist: float) -> Dictionary:
	var tracker := PathTracker.new(gen.path, seed_dist)
	var dist: float = clampf(tracker.update(p), 0.0, gen.path.total_length())
	var f: Dictionary = gen.path.road_frame(dist)
	var right := Vector3(cos(f.heading), 0.0, -sin(f.heading))
	var lateral: float = (p - f.pos).dot(right) / maxf(cos(f.bank), 0.2)
	return {"dist": dist, "lateral": lateral}

static func _overpass(gen, o: Dictionary) -> Node3D:
	var path: RoadPath = gen.path
	var layout: RoadLayout = gen.layout
	var f: Dictionary = path.road_frame(o.d)
	var center: Vector3 = path.world_pos(o.d, 0.0)
	var yaw_angle: float = f.heading + o.skew
	var yaw := Basis(Vector3.UP, yaw_angle) # kit's +X runs along the deck
	var dir: Vector3 = yaw * Vector3.RIGHT
	var cos_skew: float = cos(o.skew)
	var road_top: float = maxf(path.world_pos(o.d, layout.shoulder_edge(o.d, -1.0)).y,
		path.world_pos(o.d, layout.shoulder_edge(o.d, 1.0)).y)
	var soffit: float = road_top + CLEARANCE
	var deck_top: float = soffit + DECK_DEPTH
	var ground_at := func(p: Vector3, t: float) -> Dictionary:
		var near := _road_near(gen, p, o.d - t * sin(o.skew))
		near["y"] = gen._ground_pos(near.dist, near.lateral).y
		return near

	# How far each half of the span may reach (t = distance along the deck).
	var reach := {}
	var clear_of_crossing: float = (gen.SHOULDER_HALF_WIDTH + 20.0 * M) / cos_skew
	for sgn in [-1.0, 1.0]:
		var r: float = RoadLayout.OVERPASS_REACH
		var t: float = clear_of_crossing
		while t < RoadLayout.OVERPASS_REACH:
			var g: Dictionary = ground_at.call(center + dir * sgn * t, sgn * t)
			if absf(g.lateral) < ROAD_KEEP_OUT + 4.0 * M:
				r = t - 2.0 * PROBE_STEP # the road bends back under - stop well short
				break
			if g.y > soffit - GROUND_HEADROOM:
				r = t - PROBE_STEP
				break
			t += PROBE_STEP
		reach[sgn] = maxf(r, clear_of_crossing)

	var decks: Array[Transform3D] = []
	var columns: Array[Transform3D] = []
	var caps: Array[Transform3D] = []
	var abutments: Array[Transform3D] = []
	var scale_m := Basis.from_scale(Vector3.ONE * M)

	for sgn in [-1.0, 1.0]:
		var n: int = maxi(1, int(floor(reach[sgn] / MODULE_LEN)))
		for k in n:
			var t: float = (float(k) + 0.5) * MODULE_LEN * sgn
			decks.append(Transform3D(yaw * scale_m, center + dir * t + Vector3(0, deck_top - center.y, 0)))
		var end_t: float = float(n) * MODULE_LEN
		# End block, from the deck top down into the ground.
		var abut_pos: Vector3 = center + dir * sgn * (end_t + ABUTMENT_LEN * 0.5)
		var g_end: Dictionary = ground_at.call(abut_pos, sgn * end_t)
		var depth: float = deck_top - g_end.y + 0.3 * M
		abutments.append(Transform3D(yaw * Basis.from_scale(Vector3(M, depth, M)),
			Vector3(abut_pos.x, deck_top, abut_pos.z)))
		# Columns + caps: the first just outside the road, then every PIER_SPACING.
		var t_col: float = PIER_FIRST_LATERAL / cos_skew
		while t_col < end_t - 6.0 * M:
			var p: Vector3 = center + dir * sgn * t_col
			var g: Dictionary = ground_at.call(p, sgn * t_col)
			if absf(g.lateral) >= ROAD_KEEP_OUT:
				var top: float = soffit - CAP_DEPTH
				var h: float = top - g.y + 0.1 * M
				if h > 0.5 * M:
					columns.append(Transform3D(yaw * Basis.from_scale(Vector3(M, h, M)), Vector3(p.x, g.y, p.z)))
					caps.append(Transform3D(yaw * scale_m, Vector3(p.x, soffit, p.z)))
			t_col += PIER_SPACING

	var node := Node3D.new()
	node.name = "Overpass"
	node.add_child(_multimesh(_mesh("deck"), decks, "Deck"))
	node.add_child(_multimesh(_mesh("column"), columns, "Columns"))
	node.add_child(_multimesh(_mesh("cap"), caps, "Caps"))
	node.add_child(_multimesh(_mesh("abutment"), abutments, "Abutments"))
	return node

static func _multimesh(mesh: Mesh, xforms: Array[Transform3D], node_name: String) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	return mmi
