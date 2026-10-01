class_name RoadSuspension
extends RefCounted

## The Akashi-style suspension bridge standing around a RoadLayout bridge
## marked `suspension`: two towers on round piers, two main cables, a hanger
## every 14 m, the truss under the deck, an anchorage at each shore, and its
## lights. The road itself, the deck slab under it and the parapets are still
## the normal road ribbon / RoadBridge / RoadBarriers - this adds only the
## structure around them. RoadLayout keeps the road dead straight and level
## across the span (straight_weight / grade_override).
##
## The parts come from the Blender kit in assets/road/akashi/ (source:
## C:/My Projects/Kosoku_Road/akashi_bridge.py) and are assembled here with
## the same recipe as that script's placements() and cable_z(). The constants
## below mirror the script's, in metres - change both together.
##
## Width: nothing in the kit is as wide as the road. Side parts (tower legs,
## truss panels, hangers, cables) sit on the cable plane, WALKWAY outside the
## deck lip, and are never stretched - the left one is the right one turned
## half a turn, so nothing is mirrored. Cross parts (tower struts and
## X-braces, the anchorage block) are unit boxes / extrusions placed by
## length and angle. The deck width is read from RoadLayout, so a wider road
## just moves the two sides apart.
##
## One node per bridge, built whole (about 5,500 triangles, 10 draw calls)
## once the player is within SHOW_PAD of it and freed HIDE_PAD past it - see
## update(). The big pieces and the lights use shaders that keep them from
## being cut off by the camera's far plane (akashi_landmark.gdshader), so the
## towers fade in from a distance instead of popping in.

const M := RoadMetrics.UNIT_SCALE

# --- Mirrors akashi_bridge.py (metres) ---------------------------------------
const HALF_MAIN := RoadLayout.SUSPENSION_MAIN_SPAN / M * 0.5
const SIDE_SPAN := RoadLayout.SUSPENSION_SIDE_SPAN / M
const END := HALF_MAIN + SIDE_SPAN # anchorage, measured from midspan
const HANGER_PITCH := 14.0
const MODULE := 28.0 # truss panel length / cable segment

const TOWER_UP := 125.0 # above the road
const TOWER_DOWN := 36.0 # road down to the pier top
const LEG_LEAN := 3.1 # leg centre at road level sits this far outside the cable plane
const LEAN_PER_M := LEG_LEAN / TOWER_UP
const LEG_HW_BASE := 2.0
const LEG_HW_TOP := 1.6
const LEG_HL_BASE := 4.5
const PLINTH_H := 2.5
const PORTAL_CLEAR := 9.5 # road to the underside of the first strut
const STRUT_H := 3.0
const STRUT_MID_H := 2.4
const STRUT_TOP_H := 6.0
const STRUT_DEPTH := 3.2 # along the road
const TIERS_UP := 4 # X-brace tiers above the portal strut
const BRACE_W := 2.0 # along the road
const BRACE_T := 1.5
const BURY := 0.7 # how far cross members run into the legs
## Pier depth below the sea surface. Kept small: seen from afar the far-plane
## shader draws the pier in front of the (flat) sea, so its buried part shows.
const PIER_BURY := 2.0

const WALKWAY := 1.6 # deck lip to the cable plane
const TRUSS_DEPTH := 9.0
const TRUSS_TOP := -0.35

const CABLE_R := 0.45
const CABLE_SIDES := 6
const CABLE_TOP := TOWER_UP + 1.5 # in the saddle
const CABLE_MID := 4.0 # above the road at midspan
const CABLE_ANCHOR := 3.0 # where it enters the anchorage
const SIDE_SAG := 14.0
const HANGER_BASE := -0.30

const ANCHOR_MARGIN := 4.0 # the block reaches this far outside the cable plane

# --- Look --------------------------------------------------------------------
const STEEL_COLOR := Color(0.68, 0.74, 0.64)
const CABLE_COLOR := Color(0.79, 0.82, 0.75)
const CONCRETE_COLOR := Color(0.52, 0.52, 0.50) # the viaduct deck's grey
const TOWER_LIGHT_COLOR := Color(1.0, 0.93, 0.8)
const BEACON_COLOR := Color(1.0, 0.08, 0.04)
const BEACON_ENERGY := 6.0
const BEACON_PERIOD := 2.4 # seconds per blink
const BEAD_SIZE := 0.9 * M
const BEACON_SIZE := 1.8 * M
## Stand-ins for the deck and its streetlights, which the streamed road chunks
## only show as far as the skyline band: a dark slab that sits hidden inside
## the real deck slab (so it only shows where the real one has ended), and a
## dot at every real lamp head that stays dark until the real lamp is about
## to go. Without them a distant bridge is towers and cables with nothing
## between, and the legs below the deck show through where it should be.
const FAR_DECK_COLOR := Color(0.17, 0.17, 0.18) # close to the road's asphalt
const FAR_DECK_INSET := 0.8 # narrower than the real slab each side...
const FAR_DECK_TOP := -0.25 # ...and inside it top and bottom
const FAR_DECK_BOTTOM := -0.9
const FAR_LAMP_COLOR := Color(1.0, 0.9, 0.6) # the streetlight heads' colour
const FAR_LAMP_ENERGY := 3.0
const FAR_LAMP_SIZE := 1.2 * M
const FAR_LAMP_HIDE_NEAR := 225.0 * M
const FAR_LAMP_HIDE_FAR := 255.0 * M

# --- Distance (world units) --------------------------------------------------
## Built this far before the first ramp, freed this far past the last. Both
## leave the nearest piece beyond FADE_FAR, so it never pops in or out.
const SHOW_PAD := 900.0 * M
const HIDE_PAD := 900.0 * M
## Towers, cables, anchorages and lights fade in between these distances.
const FADE_NEAR := 1100.0 * M
const FADE_FAR := 1800.0 * M
## Hangers are hairlines by then - gone before the skyline band would cut them.
const HANGER_FADE_NEAR := 190.0 * M
const HANGER_FADE_FAR := 245.0 * M
## Past COMPRESS_START the shaders pull vertices toward the camera, into the
## thin shell up to COMPRESS_END - just in front of the skyline band
## (skyline.gd city_radius, 840), which is what really ends the view near the
## horizon (the camera's far plane is 1000). The shell is kept thin on
## purpose: a road object between COMPRESS_START and the skyline can be drawn
## over by a bridge piece that is really behind it, so that range should be
## as short as the depth buffer allows (about 15 m here).
const COMPRESS_START := 790.0
const COMPRESS_END := 836.0
const COMPRESS_SCALE := 2500.0
const CULL_MARGIN := 16384.0 # never frustum-culled by the (too near) far plane

const KIT := {
	"leg": "res://assets/road/akashi/akashi_tower_leg.glb",
	"bar": "res://assets/road/akashi/akashi_bar.glb",
	"truss": "res://assets/road/akashi/akashi_truss_side.glb",
	"hanger": "res://assets/road/akashi/akashi_hanger.glb",
	"pier": "res://assets/road/akashi/akashi_pier.glb",
	"anchorage": "res://assets/road/akashi/akashi_anchorage.glb",
	"house": "res://assets/road/akashi/akashi_anchor_house.glb",
}
const TRUSS_TEXTURE := "res://assets/road/akashi/akashi_truss.png"
const LANDMARK_SHADER := preload("res://MAIN/road/akashi_landmark.gdshader")
const LIGHT_SHADER := preload("res://MAIN/road/akashi_light.gdshader")

## Bridge space: X across the road, Y along it, Z up, metres, origin on the
## road at midspan - the kit's own axes in Blender. A kit mesh arrives through
## glTF (Y up, -Z = the kit's +Y); this turns it back.
const KIT_BASIS := Basis(Vector3(1, 0, 0), Vector3(0, 0, 1), Vector3(0, -1, 0))
## Half a turn about the vertical: the right-hand part becomes the left-hand one.
const TURN := Basis(Vector3(-1, 0, 0), Vector3(0, -1, 0), Vector3(0, 0, 1))

static var _meshes: Dictionary = {}

static func _mesh(key: String) -> Mesh:
	if not _meshes.has(key):
		var scene := load(KIT[key]) as PackedScene
		if scene == null:
			return null
		var node: Node = scene.instantiate()
		_meshes[key] = RoadsideTrees._find_mesh(node)
		node.free()
	return _meshes[key]

# =============================================================================
# Streaming
# =============================================================================

## Builds each suspension bridge's structure as the player nears it and frees
## it once it is well behind. `gen` is the RoadGenerator; the nodes are kept
## in its suspension_nodes (bridge ramp_start -> node).
static func update(gen, dist: float) -> void:
	for b in gen.layout.bridges:
		if not b.suspension:
			continue
		var key: float = b.ramp_start
		var want: bool = dist > b.ramp_start - SHOW_PAD and dist < b.ramp_end + HIDE_PAD
		var have: bool = gen.suspension_nodes.has(key)
		if want and not have:
			var node := build(gen, b)
			gen.add_child(node)
			gen.suspension_nodes[key] = node
		elif have and not want:
			gen.suspension_nodes[key].queue_free()
			gen.suspension_nodes.erase(key)

## Frees every built bridge (a new run brings a new layout).
static func clear(gen) -> void:
	for node in gen.suspension_nodes.values():
		if is_instance_valid(node):
			node.queue_free()
	gen.suspension_nodes.clear()

# =============================================================================
# Shape
# =============================================================================

## Cable centre height above the road at `y` metres from midspan: a parabola
## between the towers, a straight run with a little sag down to each anchorage.
static func cable_z(y: float) -> float:
	var a: float = absf(y)
	if a <= HALF_MAIN:
		var u: float = a / HALF_MAIN
		return CABLE_MID + (CABLE_TOP - CABLE_MID) * u * u
	var t: float = minf((a - HALF_MAIN) / SIDE_SPAN, 1.0)
	return lerpf(CABLE_TOP, CABLE_ANCHOR, t) - 4.0 * SIDE_SAG * t * (1.0 - t)

## Leg centre / inner face, measured from the road centreline, at height `z`.
## `c` is the cable plane's offset (deck half-width + WALKWAY).
static func _leg_center(c: float, z: float) -> float:
	return c + LEAN_PER_M * (TOWER_UP - z)

static func _leg_inner(c: float, z: float) -> float:
	var half: float = lerpf(LEG_HW_BASE, LEG_HW_TOP, (z + TOWER_DOWN) / (TOWER_UP + TOWER_DOWN))
	return _leg_center(c, z) - half

static func _pier_radius(c: float) -> float:
	var x: float = _leg_center(c, -TOWER_DOWN) + LEG_HW_BASE + 1.5
	return Vector2(x, LEG_HL_BASE + 1.5).length() + 2.0

## Tower cross members: struts as (z centre, height), X-brace tiers as
## (z low, z high). Below the deck: a strut on the plinths, one under the
## truss, an X between. Above: the portal strut, TIERS_UP X tiers split by
## slimmer struts, and the top strut.
static func _tower_levels() -> Dictionary:
	var struts: Array[Vector2] = []
	var tiers: Array[Vector2] = []
	var low: float = -TOWER_DOWN + PLINTH_H + STRUT_H * 0.5 + 0.5
	var under: float = TRUSS_TOP - TRUSS_DEPTH - 0.6 - STRUT_H * 0.5
	struts.append(Vector2(low, STRUT_H))
	struts.append(Vector2(under, STRUT_H))
	if (under - STRUT_H * 0.5) - (low + STRUT_H * 0.5) >= 10.0:
		tiers.append(Vector2(low + STRUT_H * 0.5, under - STRUT_H * 0.5))
	var portal: float = PORTAL_CLEAR + STRUT_H * 0.5
	var top: float = TOWER_UP - 2.0 - STRUT_TOP_H * 0.5
	struts.append(Vector2(portal, STRUT_H))
	struts.append(Vector2(top, STRUT_TOP_H))
	var z0: float = portal + STRUT_H * 0.5
	var z1: float = top - STRUT_TOP_H * 0.5
	var tier_h: float = ((z1 - z0) - float(TIERS_UP - 1) * STRUT_MID_H) / float(TIERS_UP)
	for i in TIERS_UP:
		var lo: float = z0 + float(i) * (tier_h + STRUT_MID_H)
		tiers.append(Vector2(lo, lo + tier_h))
		if i < TIERS_UP - 1:
			struts.append(Vector2(lo + tier_h + STRUT_MID_H * 0.5, STRUT_MID_H))
	return {"struts": struts, "tiers": tiers}

## One hanger per HANGER_PITCH, except at the towers and in the last bay
## before each anchorage (the cable is inside its housing there).
static func _hanger_stations() -> Array[float]:
	var ys: Array[float] = []
	var n: int = int(round(END / HANGER_PITCH))
	for k in range(-n + 1, n):
		var y: float = float(k) * HANGER_PITCH
		if absf(absf(y) - HALF_MAIN) < 1.0 or absf(y) > END - 20.0:
			continue
		ys.append(y)
	return ys

## Cable ring positions: every MODULE, counted from each tower (where the
## curve has its corner), plus the two ends.
static func _cable_stations() -> Array[float]:
	var half: Array[float] = [END]
	var y: float = HALF_MAIN
	while y < END:
		half.append(y)
		y += MODULE
	y = HALF_MAIN - MODULE
	while y > 0.0:
		half.append(y)
		y -= MODULE
	var ys: Array[float] = []
	for v in half:
		ys.append(v)
		ys.append(-v)
	ys.sort()
	return ys

## A kit part at `pos` in bridge space, turned / scaled by `basis` (also
## bridge space: X across, Y along, Z up).
static func _place(pos: Vector3, basis: Basis = Basis.IDENTITY) -> Transform3D:
	return Transform3D(basis * KIT_BASIS, pos)

# =============================================================================
# Building
# =============================================================================

static func build(gen, b: Dictionary) -> Node3D:
	var root := Node3D.new()
	root.name = "SuspensionBridge"
	for key in KIT:
		if _mesh(key) == null:
			push_warning("RoadSuspension: %s is missing or not imported yet." % KIT[key])
			return root

	var layout: RoadLayout = gen.layout
	var path: RoadPath = gen.path
	var mid: float = (b.sea_start + b.sea_end) * 0.5
	var right_lip: float = layout.shoulder_edge(mid, -1.0) - gen.DECK_LIP
	var left_lip: float = layout.shoulder_edge(mid, 1.0) + gen.DECK_LIP
	var center_lat: float = (right_lip + left_lip) * 0.5
	var deck_half: float = (left_lip - right_lip) * 0.5 / M
	var c: float = deck_half + WALKWAY # the cable plane

	# The span is straight and level, so one rigid frame fits all of it. Taken
	# from its two ends (not the heading at one point) so nothing drifts off
	# the deck over 2.5 km.
	var p0: Vector3 = path.world_pos(b.sea_start, center_lat)
	var p1: Vector3 = path.world_pos(b.sea_end, center_lat)
	var along := Vector3(p1.x - p0.x, 0.0, p1.z - p0.z).normalized()
	var across: Vector3 = along.cross(Vector3.UP)
	var origin: Vector3 = (p0 + p1) * 0.5
	root.transform = Transform3D(Basis(across * M, along * M, Vector3.UP * M), origin)

	var legs: Array[Transform3D] = []
	var bars: Array[Transform3D] = []
	var piers: Array[Transform3D] = []
	var panels: Array[Transform3D] = []
	var hangers: Array[Transform3D] = []
	var anchorages: Array[Transform3D] = []
	var houses: Array[Transform3D] = []

	# Towers, each on its pier (which runs from the tower's foot into the sea).
	var levels: Dictionary = _tower_levels()
	var sea_z: float = (b.sea_y - origin.y) / M
	var pier_depth: float = maxf(1.0, -TOWER_DOWN - sea_z + PIER_BURY)
	var pier_r: float = _pier_radius(c)
	var leg_x: float = _leg_center(c, 0.0)
	for yt: float in [-HALF_MAIN, HALF_MAIN]:
		legs.append(_place(Vector3(leg_x, yt, 0.0)))
		legs.append(_place(Vector3(-leg_x, yt, 0.0), TURN))
		for s: Vector2 in levels.struts:
			var length: float = 2.0 * (_leg_inner(c, s.x) + BURY)
			bars.append(_place(Vector3(0.0, yt, s.x), Basis.from_scale(Vector3(length, STRUT_DEPTH, s.y))))
		for t: Vector2 in levels.tiers:
			for sgn: float in [1.0, -1.0]:
				# From one leg's inner face low down to the other's higher up.
				var a := Vector2(-sgn * _leg_inner(c, t.x), t.x)
				var e := Vector2(sgn * _leg_inner(c, t.y), t.y)
				var dir: Vector2 = (e - a).normalized()
				a -= dir * BURY
				e += dir * BURY
				var delta: Vector2 = e - a
				var centre: Vector2 = (a + e) * 0.5
				var tilt := Basis(Vector3(0, 1, 0), -atan2(delta.y, delta.x))
				bars.append(_place(Vector3(centre.x, yt, centre.y),
					tilt * Basis.from_scale(Vector3(delta.length(), BRACE_W, BRACE_T))))
		piers.append(_place(Vector3(0.0, yt, -TOWER_DOWN), Basis.from_scale(Vector3(pier_r, pier_r, pier_depth))))

	var y: float = -END + MODULE * 0.5
	while y < END:
		panels.append(_place(Vector3(c, y, 0.0)))
		panels.append(_place(Vector3(-c, y, 0.0), TURN))
		y += MODULE

	for hy in _hanger_stations():
		var stretch := Basis.from_scale(Vector3(1.0, 1.0, cable_z(hy) - HANGER_BASE))
		for sgn: float in [1.0, -1.0]:
			hangers.append(_place(Vector3(sgn * c, hy, HANGER_BASE), stretch))

	for end: float in [1.0, -1.0]:
		var turn: Basis = Basis.IDENTITY if end > 0.0 else TURN
		anchorages.append(_place(Vector3(0.0, end * END, 0.0),
			turn * Basis.from_scale(Vector3(2.0 * (c + ANCHOR_MARGIN), 1.0, 1.0))))
		for sgn: float in [1.0, -1.0]:
			houses.append(_place(Vector3(sgn * c, end * END, 0.0), turn))

	var tower_mat := _landmark(STEEL_COLOR, 0.55, FADE_NEAR, FADE_FAR)
	tower_mat.set_shader_parameter("uplight_color", TOWER_LIGHT_COLOR)
	tower_mat.set_shader_parameter("uplight_energy", gen.bridge_tower_light_energy)
	tower_mat.set_shader_parameter("uplight_base_y", origin.y)
	tower_mat.set_shader_parameter("uplight_height", TOWER_UP * M)
	tower_mat.set_shader_parameter("uplight_axis", along)
	var concrete := _landmark(CONCRETE_COLOR, 0.9, FADE_NEAR, FADE_FAR)
	var cable_mat := _landmark(CABLE_COLOR, 0.5, FADE_NEAR, FADE_FAR)

	root.add_child(_instances("leg", legs, "TowerLegs", tower_mat, true))
	root.add_child(_instances("bar", bars, "TowerBracing", tower_mat, true))
	root.add_child(_instances("pier", piers, "Piers", concrete, true))
	root.add_child(_instances("anchorage", anchorages, "Anchorages", concrete, true))
	root.add_child(_instances("house", houses, "CableHouses", concrete, true))
	root.add_child(_instances("truss", panels, "Truss", _truss_material(), false))
	root.add_child(_instances("hanger", hangers, "Hangers",
		_landmark(CABLE_COLOR, 0.5, HANGER_FADE_NEAR, HANGER_FADE_FAR), false))

	var cables := MeshInstance3D.new()
	cables.name = "Cables"
	cables.mesh = _cable_mesh(c)
	cables.material_override = cable_mat
	_dress(cables, true)
	root.add_child(cables)

	# Lights: a bead on both cables every HANGER_PITCH (not at the towers -
	# the cable is inside its saddle there), and a slow red beacon on each
	# tower top.
	var beads: Array[Transform3D] = []
	var n: int = int(round(END / HANGER_PITCH))
	for k in range(-n + 1, n):
		var by: float = float(k) * HANGER_PITCH
		if absf(absf(by) - HALF_MAIN) < 1.0:
			continue
		for sgn: float in [1.0, -1.0]:
			beads.append(Transform3D(Basis.IDENTITY, Vector3(sgn * c, by, cable_z(by) + CABLE_R + 0.25)))
	root.add_child(_lights(beads, "CableLights",
		_light(gen.bridge_cable_light_color, gen.bridge_cable_light_energy, BEAD_SIZE, 0.0)))
	var beacons: Array[Transform3D] = []
	for yt: float in [-HALF_MAIN, HALF_MAIN]:
		for sgn: float in [1.0, -1.0]:
			beacons.append(Transform3D(Basis.IDENTITY, Vector3(sgn * c, yt, TOWER_UP + 4.5)))
	root.add_child(_lights(beacons, "Beacons", _light(BEACON_COLOR, BEACON_ENERGY, BEACON_SIZE, BEACON_PERIOD)))

	# Far stand-ins (see FAR_DECK_*): the deck as a row of dark bars turned to
	# run along the road, and a dot at each streetlight head - same global
	# spacing and stagger as RoadGenerator._build_streetlights, so each dot
	# sits on its real lamp. The deck is cut into MODULE-long bars, not one
	# 2.5 km bar: the shader pulls far vertices toward the camera, and a face
	# whose corners are all far away gets dragged up through the road (and
	# its fade, read at the corners, says "far" all along it).
	var far_deck: Array[Transform3D] = []
	var deck_scale := Basis(Vector3(0, 0, 1), PI * 0.5) * Basis.from_scale(
		Vector3(MODULE, 2.0 * (deck_half - FAR_DECK_INSET), FAR_DECK_TOP - FAR_DECK_BOTTOM))
	var seg: float = -END + MODULE * 0.5
	while seg < END:
		far_deck.append(_place(Vector3(0.0, seg, (FAR_DECK_TOP + FAR_DECK_BOTTOM) * 0.5), deck_scale))
		seg += MODULE
	root.add_child(_instances("bar", far_deck, "FarDeck", _landmark(FAR_DECK_COLOR, 0.9, FADE_NEAR, FADE_FAR), true))
	var lamps: Array[Transform3D] = []
	var spacing: float = gen.STREETLIGHT_SPACING
	var lamp_z: float = (gen.STREETLIGHT_HEIGHT - gen.ARM_DROP) / M
	for side: float in [-1.0, 1.0]:
		var offset: float = 0.0 if side < 0.0 else spacing * 0.5
		var lateral: float = layout.shoulder_edge(mid, side) \
			+ side * (gen.DECK_LIP - 0.2 * M - gen.ROAD_HALF_WIDTH * gen.ARM_REACH_FRAC)
		var d: float = ceilf((b.sea_start - offset) / spacing) * spacing + offset
		while d < b.sea_end:
			# Bridge X runs toward -lateral (see the frame above).
			lamps.append(Transform3D(Basis.IDENTITY, Vector3(-(lateral - center_lat) / M, (d - mid) / M, lamp_z)))
			d += spacing
	var lamp_mat := _light(FAR_LAMP_COLOR, FAR_LAMP_ENERGY, FAR_LAMP_SIZE, 0.0)
	lamp_mat.set_shader_parameter("hide_near", FAR_LAMP_HIDE_NEAR)
	lamp_mat.set_shader_parameter("hide_far", FAR_LAMP_HIDE_FAR)
	root.add_child(_lights(lamps, "FarLamps", lamp_mat))
	return root

static func _instances(key: String, xforms: Array[Transform3D], node_name: String, material: Material, far: bool) -> MultiMeshInstance3D:
	var mmi := RoadOverpass._multimesh(_mesh(key), xforms, node_name)
	mmi.material_override = material
	_dress(mmi, far)
	return mmi

## No shadows (the far-plane shaders would cast them from the wrong place),
## never a decimated LOD, and for the pieces drawn past the far plane a margin
## that stops the engine culling them by it.
static func _dress(node: GeometryInstance3D, far: bool) -> void:
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.lod_bias = 64.0
	if far:
		node.extra_cull_margin = CULL_MARGIN

static func _compress(m: ShaderMaterial, fade_near: float, fade_far: float) -> void:
	m.set_shader_parameter("compress_start", COMPRESS_START)
	m.set_shader_parameter("compress_end", COMPRESS_END)
	m.set_shader_parameter("compress_scale", COMPRESS_SCALE)
	m.set_shader_parameter("fade_near", fade_near)
	m.set_shader_parameter("fade_far", fade_far)

static func _landmark(color: Color, roughness: float, fade_near: float, fade_far: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = LANDMARK_SHADER
	m.set_shader_parameter("albedo", color)
	m.set_shader_parameter("roughness", roughness)
	_compress(m, fade_near, fade_far)
	return m

static func _light(color: Color, energy: float, size: float, blink_period: float) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = LIGHT_SHADER
	m.set_shader_parameter("color", color)
	m.set_shader_parameter("energy", energy)
	m.set_shader_parameter("size", size)
	m.set_shader_parameter("blink_period", blink_period)
	_compress(m, FADE_NEAR, FADE_FAR)
	return m

## The truss panels: the members are painted in akashi_truss.png, clear
## between them (alpha scissor, so it stays in the opaque pass).
static func _truss_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = load(TRUSS_TEXTURE) as Texture2D
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	m.alpha_scissor_threshold = 0.5
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.roughness = 0.55
	return m

## One camera-facing quad per light (akashi_light.gdshader does the facing).
static func _lights(xforms: Array[Transform3D], node_name: String, material: Material) -> MultiMeshInstance3D:
	var quad := QuadMesh.new() # 1 x 1, the shader sizes it
	var mmi := RoadOverpass._multimesh(quad, xforms, node_name)
	mmi.material_override = material
	_dress(mmi, true)
	return mmi

## Both main cables as one mesh: a CABLE_SIDES-sided tube through cable_z(),
## in bridge space. Ends are open - they sit inside the anchorage housings.
static func _cable_mesh(c: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stations := _cable_stations()
	for sgn: float in [1.0, -1.0]:
		var rings: Array[PackedVector3Array] = []
		var normals: Array[PackedVector3Array] = []
		for y in stations:
			var y0: float = maxf(y - 0.5, -END)
			var y1: float = minf(y + 0.5, END)
			var tangent := Vector3(0.0, 1.0, (cable_z(y1) - cable_z(y0)) / (y1 - y0)).normalized()
			var u := Vector3(1, 0, 0)
			var v: Vector3 = tangent.cross(u)
			var centre := Vector3(sgn * c, y, cable_z(y))
			var pts := PackedVector3Array()
			var nrm := PackedVector3Array()
			for i in CABLE_SIDES:
				var ang: float = TAU * float(i) / float(CABLE_SIDES)
				var out: Vector3 = u * cos(ang) + v * sin(ang)
				pts.append(centre + out * CABLE_R)
				nrm.append(out)
			rings.append(pts)
			normals.append(nrm)
		for k in rings.size() - 1:
			for i in CABLE_SIDES:
				var j: int = (i + 1) % CABLE_SIDES
				_tri(st, rings[k][i], rings[k][j], rings[k + 1][j], normals[k][i], normals[k][j], normals[k + 1][j])
				_tri(st, rings[k][i], rings[k + 1][j], rings[k + 1][i], normals[k][i], normals[k + 1][j], normals[k + 1][i])
	return st.commit()

## One triangle, wound so the side its normals point to is the front (Godot's
## front faces are clockwise).
static func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3) -> void:
	if (b - a).cross(c - a).dot(na + nb + nc) > 0.0:
		var p := b
		b = c
		c = p
		var q := nb
		nb = nc
		nc = q
	st.set_normal(na)
	st.add_vertex(a)
	st.set_normal(nb)
	st.add_vertex(b)
	st.set_normal(nc)
	st.add_vertex(c)
