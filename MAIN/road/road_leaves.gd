class_name RoadLeaves
extends RefCounted

## A few fallen leaves on the road for one chunk - mostly clustered on the
## shoulder against the barriers, with the odd stray on the lanes. Built once
## with the chunk, freed with it. The whole chunk's leaves are ONE
## MultiMeshInstance3D (1 draw call, 4 tris per leaf - clover-04 is a flat
## ground card), no shadows, no collision, and a short hard visibility cut
## (no fade, so the alpha-scissor material stays in the opaque pass).
## Toggle/density live on RoadGenerator ("Road Leaves" Inspector group).

const UNIT_SCALE := RoadMetrics.UNIT_SCALE

const LEAF_MESH_PATH := "res://addons/shapespark-low-poly-exterior-plants/meshes/clover-04-mesh.tscn"

## Shoulder slots, per side. A hit drops a small cluster.
const SLOT_SPACING := 12.0 * UNIT_SCALE
const FOREST_CHANCE := 0.18
const CITY_CHANCE := 0.07
const CLUSTER_MIN := 1
const CLUSTER_MAX := 3
const CLUSTER_SPREAD := 1.0 * UNIT_SCALE
## Shoulder strip the leaves land in: just off the edge line out to the barrier foot.
const SHOULDER_INNER_PAD := 0.3 * UNIT_SCALE
const SHOULDER_OUTER_PAD := 0.2 * UNIT_SCALE

## Chance per chunk of a single leaf somewhere on the travel lanes.
const LANE_STRAY_CHANCE := 0.25

## The card is ~1.6 m across unscaled - this puts a leaf patch at ~0.5-0.8 m.
const SCALE_MIN := 0.3
const SCALE_MAX := 0.5
const LIFT := 0.01 # keeps the card off the road surface (no z-fighting)

## Hard cut-off, camera to the chunk batch's AABB centre. The batch spans a
## whole chunk (~366 units), so a chunk's near end pops in at about
## VIS_RANGE - 183 units away (~66 m here) - far enough that a tiny leaf
## appearing doesn't read.
const VIS_RANGE := 400.0

static var _mesh: Mesh = null

static func _get_mesh() -> Mesh:
	if _mesh == null:
		var node: Node = (load(LEAF_MESH_PATH) as PackedScene).instantiate()
		_mesh = RoadsideTrees._find_mesh(node)
		node.free()
		if _mesh == null:
			push_warning("RoadLeaves: no mesh found in " + LEAF_MESH_PATH)
	return _mesh

## `gen` is the RoadGenerator (for path and its width constants). Returns null
## when the chunk rolled no leaves, so the caller adds nothing.
static func build(gen, start_dist: float, end_dist: float, rng: RandomNumberGenerator,
		forest: bool, density: float) -> MultiMeshInstance3D:
	var mesh := _get_mesh()
	if mesh == null or density <= 0.0:
		return null

	var xforms: Array[Transform3D] = []
	var chance: float = (FOREST_CHANCE if forest else CITY_CHANCE) * density
	# Shoulder strip per side comes from RoadLayout (it moves with lane
	# closures); no leaves inside tunnels.
	var layout: RoadLayout = gen.layout
	for side in [-1.0, 1.0]:
		var s := start_dist
		while s < end_dist:
			if rng.randf() < chance:
				var cd: float = s + rng.randf() * SLOT_SPACING
				var inner: float = absf(layout.lane_edge(cd, side)) + SHOULDER_INNER_PAD
				var outer: float = maxf(inner, absf(layout.shoulder_edge(cd, side)) - SHOULDER_OUTER_PAD)
				var cl: float = rng.randf_range(inner, outer)
				for k in rng.randi_range(CLUSTER_MIN, CLUSTER_MAX):
					var d: float = clampf(cd + rng.randf_range(-1.0, 1.0) * CLUSTER_SPREAD, start_dist, end_dist)
					var l: float = clampf(cl + rng.randf_range(-1.0, 1.0) * CLUSTER_SPREAD, inner, outer)
					if not layout.in_tunnel(d):
						xforms.append(_leaf_xform(gen, rng, d, side * l))
			s += SLOT_SPACING

	if rng.randf() < LANE_STRAY_CHANCE * density:
		var d: float = rng.randf_range(start_dist, end_dist)
		var l: float = rng.randf_range(RoadMetrics.RIGHT_EDGE, layout.lane_edge(d, 1.0))
		if not layout.in_tunnel(d):
			xforms.append(_leaf_xform(gen, rng, d, l))

	if xforms.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Leaves"
	mmi.multimesh = mm
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = VIS_RANGE
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	return mmi

## Lies flat on the (possibly banked) road surface: the card's up axis is the
## local surface normal, sampled from world_pos a little either side, so it
## never half-buries or floats on a banked curve. Random spin about that normal.
static func _leaf_xform(gen, rng: RandomNumberGenerator, d: float, lateral: float) -> Transform3D:
	var path: RoadPath = gen.path
	var pos: Vector3 = path.world_pos(d, lateral)
	var across: Vector3 = path.world_pos(d, lateral + 0.5) - path.world_pos(d, lateral - 0.5)
	var along: Vector3 = path.world_pos(d + 0.5, lateral) - path.world_pos(d - 0.5, lateral)
	var n: Vector3 = along.cross(across).normalized()
	if n.y < 0.0:
		n = -n
	var x: Vector3 = (across - n * across.dot(n)).normalized()
	var basis := Basis(x, n, x.cross(n))
	basis = Basis(n, rng.randf() * TAU) * basis
	basis = basis.scaled(Vector3.ONE * UNIT_SCALE * rng.randf_range(SCALE_MIN, SCALE_MAX))
	return Transform3D(basis, pos + n * LIFT)
