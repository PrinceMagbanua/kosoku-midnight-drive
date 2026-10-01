class_name RoadsideTrees
extends RefCounted

## Roadside trees for one road chunk - built once when the chunk is built,
## freed with it. Every tree of one variant in a chunk is ONE
## MultiMeshInstance3D, so a chunk costs (variants used x 3 surfaces) draw
## calls no matter how many trees it holds, and nothing loops over trees per
## frame.
##
## No LOD levels: the Shapespark trees are already 370-650 tris each, which
## is cheap at this density. What costs more on the gl_compatibility
## renderer is draw calls (so few variants, all batched) and leaf overdraw
## (so thin forest density before adding more detail). Foliage materials are
## alpha scissor, so everything stays in the opaque pass. For the same reason
## the visibility range below is a hard cut with no fade: a self-fade would
## push the trees into the slower transparent pass.

const UNIT_SCALE := RoadMetrics.UNIT_SCALE

## Which addon trees to use. Each extra variant adds 3 draw calls per chunk
## it appears in - add more here if the variety is worth it.
const TREE_VARIANTS: Array[String] = [
	"res://addons/shapespark-low-poly-exterior-plants/meshes/tree-01-1-mesh.tscn",
	"res://addons/shapespark-low-poly-exterior-plants/meshes/tree-02-2-mesh.tscn",
	"res://addons/shapespark-low-poly-exterior-plants/meshes/tree-03-3-mesh.tscn",
	"res://addons/shapespark-low-poly-exterior-plants/meshes/tree-01-4-mesh.tscn",
]

const SCALE_MIN := 1.5
const SCALE_MAX := 2.0

## Hard cut-off (fade disabled), measured from the camera to the centre of a
## chunk's tree batch (its AABB), not to each tree - so it sits past the chase
## camera's far plane (1000) plus about half a chunk. It mostly matters for the
## cockpit camera, whose far plane is the default 4000.
const TREE_VIS_RANGE := 1150.0

## Grass strip between the barrier and the sidewalk (3 m wide).
const GRASS_SLOT_SPACING := 10.0 * UNIT_SCALE
const GRASS_CHANCE := 0.45
const GRASS_INSET := 0.9 * UNIT_SCALE # keep trunks off the barrier's outer slope
## Streetlight arms reach over the grass strip at about 6.5 m - keep this much road
## distance clear either side of each pole.
const STREETLIGHT_CLEARANCE := 4.0 * UNIT_SCALE

## Normal (building) chunks: sparse clusters behind the building zone.
const BACK_ROW_START := 38.0 * UNIT_SCALE # past the sidewalk edge; clears the deepest buildings
const BACK_ROW_DEPTH := 55.0 * UNIT_SCALE
const BACK_SLOT_SPACING := 18.0 * UNIT_SCALE
const BACK_CHANCE := 0.5
const BACK_CLUSTER_MIN := 2
const BACK_CLUSTER_MAX := 4
const BACK_CLUSTER_SPREAD := 8.0 * UNIT_SCALE

## Forest chunks: jittered grid from just past the streetlights outward.
const FOREST_GRASS_CHANCE := 0.85
const FOREST_START := 4.0 * UNIT_SCALE # past the sidewalk edge, clears the streetlight poles
const FOREST_DEPTH := 90.0 * UNIT_SCALE
const FOREST_SPACING := 8.0 * UNIT_SCALE
const FOREST_JITTER := 3.0 * UNIT_SCALE
const FOREST_NEAR_CHANCE := 0.85 # keep-chance at the forest's inner edge...
const FOREST_FAR_CHANCE := 0.35 # ...dropping to this at its outer edge

static var _meshes: Array[Mesh] = []

static func _get_meshes() -> Array[Mesh]:
	if _meshes.is_empty():
		for p in TREE_VARIANTS:
			var node: Node = (load(p) as PackedScene).instantiate()
			var mesh: Mesh = _find_mesh(node)
			node.free()
			if mesh:
				_meshes.append(mesh)
			else:
				push_warning("RoadsideTrees: no mesh found in " + p)
	return _meshes

static func _find_mesh(node: Node) -> Mesh:
	if node is MeshInstance3D and node.mesh:
		return node.mesh
	for c in node.get_children():
		var m := _find_mesh(c)
		if m:
			return m
	return null

## `gen` is the RoadGenerator (for path/_ground_pos and its width constants).
static func build(gen, start_dist: float, end_dist: float, rng: RandomNumberGenerator,
		forest: bool, density: float, visible: bool, shadows: bool) -> Node3D:
	var container := Node3D.new()
	container.name = "Trees"
	var meshes := _get_meshes()
	if meshes.is_empty() or density <= 0.0:
		return container

	var per_variant: Array = []
	for i in meshes.size():
		per_variant.append([])

	for side in [-1.0, 1.0]:
		_scatter_grass_strip(gen, per_variant, start_dist, end_dist, side, rng,
			(FOREST_GRASS_CHANCE if forest else GRASS_CHANCE) * density)
		if forest:
			_scatter_forest(gen, per_variant, start_dist, end_dist, side, rng, density)
		else:
			_scatter_back_row(gen, per_variant, start_dist, end_dist, side, rng, density)

	for i in meshes.size():
		var xforms: Array = per_variant[i]
		if xforms.is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = meshes[i]
		mm.instance_count = xforms.size()
		for n in xforms.size():
			mm.set_instance_transform(n, xforms[n])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.visibility_range_end = TREE_VIS_RANGE
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mmi.visible = visible
		mmi.add_to_group("roadside_trees")
		container.add_child(mmi)
	return container

static func _add_tree(gen, per_variant: Array, rng: RandomNumberGenerator, d: float, lateral: float) -> void:
	# Roll everything first so skipping a tree never reshuffles the rest.
	var s: float = UNIT_SCALE * rng.randf_range(SCALE_MIN, SCALE_MAX)
	var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3.ONE * s)
	var variant: int = rng.randi_range(0, per_variant.size() - 1)
	if not gen._tree_ok(d, lateral):
		return
	per_variant[variant].append(Transform3D(basis, gen._ground_pos(d, lateral)))

static func _scatter_grass_strip(gen, per_variant: Array, start_dist: float, end_dist: float,
		side: float, rng: RandomNumberGenerator, chance: float) -> void:
	var inner: float = gen.FENCE_HALF_WIDTH + GRASS_INSET
	var outer: float = gen.GRASS_HALF_WIDTH - 0.4 * UNIT_SCALE
	# Same per-side stagger as _build_streetlights.
	var spacing: float = gen.STREETLIGHT_SPACING
	var light_offset: float = 0.0 if side < 0.0 else spacing / 2.0
	var s := start_dist
	while s < end_dist:
		# Roll first so the RNG sequence doesn't depend on the clearance check.
		var roll := rng.randf()
		var d: float = s + rng.randf() * GRASS_SLOT_SPACING * 0.8
		var lateral: float = side * rng.randf_range(inner, outer)
		var to_light: float = fposmod(d - light_offset, spacing)
		to_light = minf(to_light, spacing - to_light)
		if roll < chance and to_light > STREETLIGHT_CLEARANCE:
			_add_tree(gen, per_variant, rng, d, lateral)
		s += GRASS_SLOT_SPACING

static func _scatter_back_row(gen, per_variant: Array, start_dist: float, end_dist: float,
		side: float, rng: RandomNumberGenerator, density: float) -> void:
	var base: float = gen.SIDEWALK_HALF_WIDTH + BACK_ROW_START
	var s := start_dist
	while s < end_dist:
		if rng.randf() < BACK_CHANCE * density:
			var cd: float = s + rng.randf() * BACK_SLOT_SPACING
			var cl: float = base + rng.randf() * BACK_ROW_DEPTH
			for k in rng.randi_range(BACK_CLUSTER_MIN, BACK_CLUSTER_MAX):
				var d: float = cd + rng.randf_range(-1.0, 1.0) * BACK_CLUSTER_SPREAD
				var l: float = cl + rng.randf_range(-1.0, 1.0) * BACK_CLUSTER_SPREAD
				_add_tree(gen, per_variant, rng, clampf(d, start_dist, end_dist), side * maxf(l, base))
		s += BACK_SLOT_SPACING

static func _scatter_forest(gen, per_variant: Array, start_dist: float, end_dist: float,
		side: float, rng: RandomNumberGenerator, density: float) -> void:
	var base: float = gen.SIDEWALK_HALF_WIDTH + FOREST_START
	var cols: int = int(FOREST_DEPTH / FOREST_SPACING)
	var s := start_dist + FOREST_SPACING * 0.5
	while s < end_dist:
		for c in cols:
			var t: float = float(c) / float(maxi(cols - 1, 1))
			var roll := rng.randf()
			var d: float = s + rng.randf_range(-1.0, 1.0) * FOREST_JITTER
			var l: float = base + float(c) * FOREST_SPACING + rng.randf() * FOREST_JITTER
			if roll < lerpf(FOREST_NEAR_CHANCE, FOREST_FAR_CHANCE, t) * density:
				_add_tree(gen, per_variant, rng, clampf(d, start_dist, end_dist), side * l)
		s += FOREST_SPACING
