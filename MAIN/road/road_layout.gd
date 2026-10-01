class_name RoadLayout
extends RefCounted

## What the road IS at any distance along it: how many lanes are open, which
## barrier stands on each side, whether it's at grade / inside a tunnel / up
## on a viaduct / over the sea, and how high the ground around it is lifted.
## Every system that dresses or drives the road (RoadGenerator's builders,
## traffic, drift scoring, weather, audio) asks this one object instead of
## hard-coding a width or a biome, so adding a feature or a new lane pattern
## means changing the plan here, not every consumer.
##
## Planned once per run from the run's seed, BEFORE RoadPath is generated:
## RoadPath asks grade_override() so the bridges actually climb. bind_path()
## then reads the finished path for the heights (land under the viaduct, sea
## level) that only exist once the elevation profile does.
##
## Lanes: counted from RoadMetrics.RIGHT_EDGE, which never moves. A closure
## takes lanes away from the LEFT (+lateral) side - the painted edge line
## tapers across the closing lane first (hatched), then the barrier follows it
## in. Traffic treats the lane as closed for the whole closure span.

const US := RoadMetrics.UNIT_SCALE
const LANE_W := RoadMetrics.LANE_WIDTH
const MAX_LANES := RoadMetrics.LANES

enum Surface { AT_GRADE, COVERED, ELEVATED, SEA }
enum Barrier { NONE, JERSEY, GUARDRAIL, MESH_FENCE, NOISE_WALL, RETAINING, PARAPET }
enum Portal { HILL, TRENCH }
## For RoadGenerator.debug_first_feature.
## BRIDGE = the plain viaduct, BRIDGE_SUSPENSION = the Akashi (RoadSuspension).
enum Feature { RANDOM, TUNNEL_HILL, TUNNEL_TRENCH, BRIDGE, BRIDGE_SUSPENSION }

# --- Lane closures -------------------------------------------------------
const LANE_TAPER_LEN := 180.0 * US # painted edge line crosses the closing lane
const WALL_TAPER_LEN := 60.0 * US # then the barrier angles in behind it

# --- Tunnels ---------------------------------------------------------------
const TUNNEL_OPEN_LANES := 3
const TUNNEL_LEN_MIN := 900.0 * US
const TUNNEL_LEN_MAX := 2200.0 * US
const HILL_APPROACH := 40.0 * US # barrier-in -> portal, hill style
const TRENCH_LEN := 170.0 * US # ground rises over this before an urban portal
## Height of the lid/ground over a trench tunnel, above the road edge. Must
## clear RoadTunnel's crown (~8.5 m) plus bank tilt.
const LID_HEIGHT := 11.0 * US
## Hill: height at the portal (the concrete headwall), growing to the full
## hill over HILL_GROW_LEN. Top half-width is measured from the tunnel centre.
const HILL_PORTAL_HEIGHT := 12.5 * US
const HILL_MAX_HEIGHT := 36.0 * US
const HILL_GROW_LEN := 160.0 * US
const HILL_PORTAL_TOP := 11.0 * US
const HILL_TOP_GROWTH := 0.6 # extra top half-width per unit of extra height
const HILL_PORTAL_SLOPE := 2.0 # rise per run of the flanks at the portal...
const HILL_SLOPE := 0.7 # ...easing to this once grown
const HILL_NOISE := 7.0 * US
## Biome look forced around a tunnel so the hill is always grassy and the
## trench always city, however the forest regions happen to fall.
const BIOME_FORCE_PAD := 80.0 * US

# --- Bridges -------------------------------------------------------------
const BRIDGE_RAMP_LEN := 600.0 * US
const BRIDGE_RISE := 20.0 * US
const BRIDGE_SPAN_MIN := 1200.0 * US # over the sea, between the two ramps
const BRIDGE_SPAN_MAX := 2600.0 * US
const BRIDGE_BLEND := 120.0 * US # grade eases to flat either side
const GROUND_SETTLE_LEN := 40.0 * US # land under a ramp eases from road edge to the flat land level
const UNDER_ROAD_DROP := 0.3 * US # ground under a low viaduct stays this far below the deck
const SEA_DROP := 3.0 * US # sea surface below the lower shore
## Buildings stop this share of the way up the first ramp (and resume as far
## down the last).
const BRIDGE_BUILDING_CUTOFF := 0.5

# --- Suspension bridge (the Akashi - structure built by RoadSuspension) ----
## Spans match the Blender kit (Kosoku_Road/akashi_bridge.py): the whole
## suspended length is over the sea, anchorage to anchorage.
const SUSPENSION_MAIN_SPAN := 1260.0 * US
const SUSPENSION_SIDE_SPAN := 602.0 * US
## Higher and longer than a viaduct's ramps: the towers stand on piers
## 36 m below the deck, and the climb keeps about the same peak grade.
const SUSPENSION_RISE := 37.0 * US
const SUSPENSION_RAMP_LEN := 1000.0 * US
## The road runs dead straight (and so unbanked) from this far before the
## first anchorage to this far past the last, easing in/out of it over
## STRAIGHT_EASE - see straight_weight().
const STRAIGHT_PAD := 60.0 * US
const STRAIGHT_EASE := 240.0 * US

# --- Overpasses ----------------------------------------------------------
const OVERPASS_FIRST := 600.0 * US
const OVERPASS_GAP_MIN := 900.0 * US
const OVERPASS_GAP_MAX := 2200.0 * US
const OVERPASS_FEATURE_CLEARANCE := 200.0 * US
## Max angle off square to the road (radians); each overpass rolls its own.
const OVERPASS_MAX_SKEW := 0.6109 # 35 degrees
## Deck half-width (the Blender kit's deck is 11 m) and how far out it can reach.
const OVERPASS_HALF_WIDTH := 5.5 * US
const OVERPASS_REACH := 115.0 * US
## Extra clearance kept around the deck for buildings / trees / poles.
const OVERPASS_KEEP_CLEAR := 8.0 * US

# --- Lay-by (where every run starts) ---------------------------------------
## An emergency bay on the right (-lateral) side, UK motorway style: the
## paved edge steps out by LAYBY_WIDTH over LAYBY_TAPER (a straight diagonal),
## holds for LAYBY_BAY, and angles back in. The car spawns parked in it
## (spawn_dist / spawn_lateral) and has to pull out into traffic. It sits a
## little way down the road so there's road behind the car too, well before
## the first feature and the first overpass (600 m), and inside RoadPath's
## straight, level lead-in (START_STRAIGHT_LEN).
##
## Every length here is a multiple of the ribbon's sample spacing
## (RoadPath.SEG_LEN / RoadGenerator.ROW_SUBDIVISIONS = 3.5 m), so each corner
## of the trapezoid lands exactly on a mesh row, and the whole bay sits inside
## one chunk (224-336 m). RoadGenerator moves the right-side grass strip and
## footpath out with it; RoadLayby dresses it (kerb, fence, markings, props).
const LAYBY_START := 231.0 * US
const LAYBY_TAPER := 21.0 * US
const LAYBY_BAY := 63.0 * US
const LAYBY_WIDTH := 4.5 * US
const LAYBY_SPAWN_INTO_BAY := 17.5 * US # spawn point, measured from the start of the full-width bay
const LAYBY_SPAWN_OUT := 2.2 * US # car centre, measured outward from the normal shoulder edge
const LAYBY_BUILDING_MARGIN := 20.0 * US # no buildings on that side this far either end of it

# --- Planning --------------------------------------------------------------
const PLAN_END_MARGIN := 6000.0 * US

var seed_value: int
var tunnels: Array[Dictionary] = []
var bridges: Array[Dictionary] = []
var closures: Array[Dictionary] = [] # {start, end, open_lanes}
var overpasses: Array[Dictionary] = [] # {d, skew} - skew 0 = square across the road
var path: RoadPath = null

var _rng := RandomNumberGenerator.new()

## `opts` (all optional, distances in metres): first_feature_m, gap_min_m,
## gap_max_m, tunnel_weight (0..1, the rest are bridges), debug_first
## (Feature), overpasses (bool), suspension_bridges (how many of the run's
## bridges - the first ones planned - are suspension bridges).
func _init(seed: int, total_length: float, opts: Dictionary = {}) -> void:
	seed_value = seed
	_rng.seed = seed ^ 0x1A70
	_plan(total_length, opts)

## Called once RoadPath exists - fills in the heights that depend on it.
func bind_path(p: RoadPath) -> void:
	path = p
	for b in bridges:
		b.land_in_y = p.road_frame(b.ramp_start).pos.y
		b.land_out_y = p.road_frame(b.ramp_end).pos.y
		b.sea_y = minf(b.land_in_y, b.land_out_y) - SEA_DROP

# ==========================================================================
# Planning
# ==========================================================================

func _plan(total: float, opts: Dictionary) -> void:
	var first: float = float(opts.get("first_feature_m", 1500.0)) * US
	var gap_min: float = float(opts.get("gap_min_m", 1500.0)) * US
	var gap_max: float = maxf(gap_min, float(opts.get("gap_max_m", 3500.0)) * US)
	var tunnel_weight: float = float(opts.get("tunnel_weight", 0.55))
	var debug_first: int = int(opts.get("debug_first", Feature.RANDOM))
	var suspension_left: int = int(opts.get("suspension_bridges", 1))
	if debug_first != Feature.RANDOM:
		first = 350.0 * US

	var d := first
	var index := 0
	while d < total - PLAN_END_MARGIN:
		var pick: int = debug_first if index == 0 and debug_first != Feature.RANDOM else Feature.RANDOM
		if pick == Feature.RANDOM:
			pick = Feature.TUNNEL_HILL if _rng.randf() < tunnel_weight else Feature.BRIDGE
			if pick == Feature.BRIDGE and suspension_left > 0:
				pick = Feature.BRIDGE_SUSPENSION
		if pick == Feature.BRIDGE or pick == Feature.BRIDGE_SUSPENSION:
			var suspension: bool = pick == Feature.BRIDGE_SUSPENSION
			if suspension:
				suspension_left -= 1
			var b := _make_bridge(d, suspension)
			bridges.append(b)
			d = b.ramp_end + BRIDGE_BLEND
		else:
			var forced_style: int = -1
			if index == 0 and debug_first == Feature.TUNNEL_HILL:
				forced_style = Portal.HILL
			elif index == 0 and debug_first == Feature.TUNNEL_TRENCH:
				forced_style = Portal.TRENCH
			var t := _make_tunnel(d, forced_style)
			tunnels.append(t)
			closures.append({"start": t.taper_start, "end": t.taper_end, "open_lanes": TUNNEL_OPEN_LANES})
			d = t.taper_end
		d += _rng.randf_range(gap_min, gap_max)
		index += 1

	if opts.get("overpasses", true):
		var o := OVERPASS_FIRST
		if debug_first != Feature.RANDOM:
			o = first + 60000.0 # keep the debugged feature on its own
		while o < total - PLAN_END_MARGIN:
			if not _near_feature(o, OVERPASS_FEATURE_CLEARANCE):
				overpasses.append({"d": o, "skew": _rng.randf_range(-OVERPASS_MAX_SKEW, OVERPASS_MAX_SKEW)})
			o += _rng.randf_range(OVERPASS_GAP_MIN, OVERPASS_GAP_MAX)

func _make_tunnel(start: float, forced_style: int) -> Dictionary:
	var length: float = _rng.randf_range(TUNNEL_LEN_MIN, TUNNEL_LEN_MAX)
	var wall_start: float = start + LANE_TAPER_LEN
	var wall_end: float = wall_start + WALL_TAPER_LEN
	# Style needs the portal position, which needs the style's approach
	# length - decide from the biome where the tunnel would roughly sit.
	var style: int = forced_style
	if style < 0:
		var mid_guess: float = wall_end + length * 0.5
		style = Portal.HILL if BiomeMap.is_forest(mid_guess, seed_value) else Portal.TRENCH
	var approach: float = HILL_APPROACH if style == Portal.HILL else TRENCH_LEN
	var portal_in: float = wall_end + approach
	var portal_out: float = portal_in + length
	var exit_wall_start: float = portal_out + approach
	var exit_wall_end: float = exit_wall_start + WALL_TAPER_LEN
	return {
		"style": style,
		"taper_start": start,
		"wall_start": wall_start,
		"wall_end": wall_end,
		"portal_in": portal_in,
		"portal_out": portal_out,
		"exit_wall_start": exit_wall_start,
		"exit_wall_end": exit_wall_end,
		"taper_end": exit_wall_end + LANE_TAPER_LEN,
		"name_index": _rng.randi(),
		"noise_seed": _rng.randi(),
	}

func _make_bridge(start: float, suspension: bool) -> Dictionary:
	var span: float
	if suspension:
		span = SUSPENSION_MAIN_SPAN + 2.0 * SUSPENSION_SIDE_SPAN
	else:
		span = _rng.randf_range(BRIDGE_SPAN_MIN, BRIDGE_SPAN_MAX)
	var ramp_len: float = SUSPENSION_RAMP_LEN if suspension else BRIDGE_RAMP_LEN
	var ramp_start: float = start + BRIDGE_BLEND
	var sea_start: float = ramp_start + ramp_len
	var sea_end: float = sea_start + span
	return {
		"suspension": suspension,
		"ramp_len": ramp_len,
		"rise": SUSPENSION_RISE if suspension else BRIDGE_RISE,
		"ramp_start": ramp_start,
		"sea_start": sea_start,
		"sea_end": sea_end,
		"ramp_end": sea_end + ramp_len,
		# Filled by bind_path():
		"land_in_y": 0.0,
		"land_out_y": 0.0,
		"sea_y": 0.0,
	}

func _near_feature(d: float, pad: float) -> bool:
	for t in tunnels:
		if d > t.taper_start - pad and d < t.taper_end + pad:
			return true
	for b in bridges:
		if d > b.ramp_start - BRIDGE_BLEND - pad and d < b.ramp_end + BRIDGE_BLEND + pad:
			return true
	return false

static func _smooth(t: float) -> float:
	var c: float = clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

## 0 before `a`, 1 after `b`, smooth in between.
static func _ramp(d: float, a: float, b: float) -> float:
	return _smooth((d - a) / (b - a))

# ==========================================================================
# Path shaping
# ==========================================================================

## (weight, grade) RoadPath blends its own grade toward - weight 0 = leave the
## path alone. Bridges: flatten, climb the bridge's rise on a sine ramp (which
## integrates to exactly that height), hold level over the sea, descend the
## same way, flatten again.
func grade_override(d: float) -> Vector2:
	for b in bridges:
		if d < b.ramp_start - BRIDGE_BLEND or d > b.ramp_end + BRIDGE_BLEND:
			continue
		if d < b.ramp_start:
			return Vector2(_ramp(d, b.ramp_start - BRIDGE_BLEND, b.ramp_start), 0.0)
		if d > b.ramp_end:
			return Vector2(1.0 - _ramp(d, b.ramp_end, b.ramp_end + BRIDGE_BLEND), 0.0)
		var peak: float = b.rise * PI / (2.0 * b.ramp_len)
		if d < b.sea_start:
			return Vector2(1.0, peak * sin(PI * (d - b.ramp_start) / b.ramp_len))
		if d > b.sea_end:
			return Vector2(1.0, -peak * sin(PI * (d - b.sea_end) / b.ramp_len))
		return Vector2(1.0, 0.0)
	return Vector2.ZERO

## How much of its own curving RoadPath gives up at `d`: 0 = curve freely,
## 1 = dead straight (and so unbanked). A suspension bridge hangs from two
## straight cable planes, so its whole suspended span is 1; the ramps either
## side may still curve.
func straight_weight(d: float) -> float:
	for b in bridges:
		if not b.suspension:
			continue
		var a: float = b.sea_start - STRAIGHT_PAD
		var e: float = b.sea_end + STRAIGHT_PAD
		if d <= a - STRAIGHT_EASE or d >= e + STRAIGHT_EASE:
			continue
		return minf(_ramp(d, a - STRAIGHT_EASE, a), 1.0 - _ramp(d, e, e + STRAIGHT_EASE))
	return 0.0

# ==========================================================================
# Lanes
# ==========================================================================

## Painted lane count (fractional while the edge line tapers across a lane).
func lanes_painted(d: float) -> float:
	var lanes := float(MAX_LANES)
	for c in closures:
		if d <= c.start or d >= c.end:
			continue
		var closed: float = float(MAX_LANES - c.open_lanes)
		var w: float = minf(_ramp(d, c.start, c.start + LANE_TAPER_LEN), 1.0 - _ramp(d, c.end - LANE_TAPER_LEN, c.end))
		lanes = minf(lanes, float(MAX_LANES) - closed * w)
	return lanes

## Lane count the barrier is set for - lags the paint: it only moves in once
## the painted taper has finished, and moves out before the paint reopens.
func lanes_barrier(d: float) -> float:
	var lanes := float(MAX_LANES)
	for c in closures:
		var a: float = c.start + LANE_TAPER_LEN
		var b: float = c.end - LANE_TAPER_LEN
		if d <= a or d >= b:
			continue
		var closed: float = float(MAX_LANES - c.open_lanes)
		var w: float = minf(_ramp(d, a, a + WALL_TAPER_LEN), 1.0 - _ramp(d, b - WALL_TAPER_LEN, b))
		lanes = minf(lanes, float(MAX_LANES) - closed * w)
	return lanes

## Signed lateral of the outer edge of the travel lanes on `side` (-1 right, +1 left).
func lane_edge(d: float, side: float) -> float:
	if side < 0.0:
		return RoadMetrics.RIGHT_EDGE
	return RoadMetrics.RIGHT_EDGE + lanes_painted(d) * LANE_W

## Where the lane area ends and the plain shoulder begins on `side`: the
## hatched closure area lies between lane_edge() and this.
func hatch_edge(d: float, side: float) -> float:
	if side < 0.0:
		return RoadMetrics.RIGHT_EDGE
	return RoadMetrics.RIGHT_EDGE + lanes_barrier(d) * LANE_W

## Signed lateral of the shoulder's outer edge = barrier inner line = where the
## invisible collision wall stands. On the right it bulges out around the
## starting lay-by.
func shoulder_edge(d: float, side: float) -> float:
	if side < 0.0:
		return RoadMetrics.RIGHT_EDGE - RoadMetrics.SHOULDER_WIDTH - layby_width(d)
	return hatch_edge(d, side) + RoadMetrics.SHOULDER_WIDTH

# ==========================================================================
# Lay-by
# ==========================================================================

## Extra paved width on the right at `d`: 0 outside the lay-by, LAYBY_WIDTH in
## the bay, a straight line through the two tapers.
func layby_width(d: float) -> float:
	var bay_start: float = LAYBY_START + LAYBY_TAPER
	var bay_end: float = bay_start + LAYBY_BAY
	if d <= LAYBY_START or d >= bay_end + LAYBY_TAPER:
		return 0.0
	return LAYBY_WIDTH * clampf(minf((d - LAYBY_START) / LAYBY_TAPER, (bay_end + LAYBY_TAPER - d) / LAYBY_TAPER), 0.0, 1.0)

## How far the right-side verge (grass strip, footpath, terrain, poles, trees)
## is pushed outward at `d` to make room for the bay; 0 on the left.
func verge_shift(d: float, side: float) -> float:
	return layby_width(d) if side < 0.0 else 0.0

## [start of the entry taper, start of the full-width bay, its end, end of the exit taper].
static func layby_span() -> Array[float]:
	var bay_start: float = LAYBY_START + LAYBY_TAPER
	return [LAYBY_START, bay_start, bay_start + LAYBY_BAY, bay_start + LAYBY_BAY + LAYBY_TAPER]

func in_layby(d: float) -> bool:
	return layby_width(d) > 0.0

## Where a run starts: distance along the road and signed lateral of the car's centre.
static func spawn_dist() -> float:
	return LAYBY_START + LAYBY_TAPER + LAYBY_SPAWN_INTO_BAY

static func spawn_lateral() -> float:
	return RoadMetrics.RIGHT_EDGE - RoadMetrics.SHOULDER_WIDTH - LAYBY_SPAWN_OUT

## Lanes traffic may use at `d` (a closing lane counts as closed for its whole
## closure span, taper included).
func open_lanes_at(d: float) -> int:
	var n := MAX_LANES
	for c in closures:
		if d >= c.start and d < c.end:
			n = mini(n, c.open_lanes)
	return n

func lane_open(lane: int, d: float) -> bool:
	return lane >= 0 and lane < open_lanes_at(d)

## True if `lane` stays open over the whole [d0, d1] stretch.
func lane_open_over(lane: int, d0: float, d1: float) -> bool:
	if lane < 0 or lane >= MAX_LANES:
		return false
	for c in closures:
		if c.start < d1 and c.end > d0 and lane >= c.open_lanes:
			return false
	return true

## Distance where `lane` next closes at or after `d` (INF if it doesn't within `reach`).
func lane_closes_at(lane: int, d: float, reach: float) -> float:
	var best := INF
	for c in closures:
		if lane >= c.open_lanes and c.end > d and c.start < d + reach:
			best = minf(best, maxf(c.start, d))
	return best

## Where the barrier on a closing lane actually starts moving in - past this
## point a car still in the lane is heading into the wall.
func lane_hard_end(lane: int, d: float, reach: float) -> float:
	var best := INF
	for c in closures:
		if lane >= c.open_lanes and c.end > d and c.start < d + reach:
			best = minf(best, c.start + LANE_TAPER_LEN)
	return best

# ==========================================================================
# Surface / ground
# ==========================================================================

func surface_mode(d: float) -> int:
	for t in tunnels:
		if d >= t.portal_in and d < t.portal_out:
			return Surface.COVERED
	for b in bridges:
		if d >= b.ramp_start and d < b.ramp_end:
			return Surface.SEA if d >= b.sea_start and d < b.sea_end else Surface.ELEVATED
	return Surface.AT_GRADE

## The ground is a hard step at a tunnel portal (road surface -> lid, flat ->
## hill face), so the road/terrain meshes cut their rows exactly there and a
## row ON a portal has to say which side it belongs to - see portal_side().
const PORTAL_EPS := 0.01 * US

## Every tunnel portal distance strictly inside (a, b), ascending.
func portals_between(a: float, b: float) -> Array[float]:
	var out: Array[float] = []
	for t in tunnels:
		for p in [t.portal_in, t.portal_out]:
			if p > a and p < b:
				out.append(p)
	out.sort()
	return out

## `d` itself, unless it sits on a tunnel portal: then a hair inside the tunnel
## if `covered`, a hair outside it otherwise.
func portal_side(d: float, covered: bool) -> float:
	var into: float = PORTAL_EPS if covered else -PORTAL_EPS
	for t in tunnels:
		if absf(d - t.portal_in) < PORTAL_EPS:
			return t.portal_in + into
		if absf(d - t.portal_out) < PORTAL_EPS:
			return t.portal_out - into
	return d

func tunnel_at(d: float, pad: float = 0.0) -> Dictionary:
	for t in tunnels:
		if d >= t.taper_start - pad and d < t.taper_end + pad:
			return t
	return {}

func bridge_at(d: float, pad: float = 0.0) -> Dictionary:
	for b in bridges:
		if d >= b.ramp_start - pad and d < b.ramp_end + pad:
			return b
	return {}

func in_tunnel(d: float) -> bool:
	return surface_mode(d) == Surface.COVERED

## Flat land level under a viaduct at `d` (only meaningful in ELEVATED), or
## NAN if the ground should just follow the road edge. `edge_y` is the road
## edge height there, eased from over GROUND_SETTLE_LEN at each end so the
## land never steps where the viaduct begins.
func land_level(d: float, edge_y: float) -> float:
	for b in bridges:
		if d < b.ramp_start or d >= b.ramp_end:
			continue
		if d < b.sea_start:
			return lerpf(edge_y, b.land_in_y, _ramp(d, b.ramp_start, b.ramp_start + GROUND_SETTLE_LEN))
		if d >= b.sea_end:
			return lerpf(edge_y, b.land_out_y, _ramp(d, b.ramp_end, b.ramp_end - GROUND_SETTLE_LEN))
		return b.sea_y
	return NAN

## Height the ground is raised by at (d, lateral) - trench lids and tunnel
## hills. `center` is the tunnel's centre lateral (hills are symmetric about it).
func lift(d: float, lateral: float) -> float:
	for t in tunnels:
		if d < t.wall_end or d >= t.exit_wall_start:
			continue
		if t.style == Portal.TRENCH:
			return LID_HEIGHT * minf(_ramp(d, t.portal_in - TRENCH_LEN, t.portal_in), 1.0 - _ramp(d, t.portal_out, t.portal_out + TRENCH_LEN))
		if d < t.portal_in or d >= t.portal_out:
			return 0.0
		return _hill_height(t, d, lateral)
	return 0.0

func _hill_height(t: Dictionary, d: float, lateral: float) -> float:
	var grow: float = minf(_ramp(d, t.portal_in, t.portal_in + HILL_GROW_LEN), 1.0 - _ramp(d, t.portal_out - HILL_GROW_LEN, t.portal_out))
	var h: float = lerpf(HILL_PORTAL_HEIGHT, HILL_MAX_HEIGHT, grow)
	h += (_noise1(d * 0.004 / US, t.noise_seed) - 0.5) * 2.0 * HILL_NOISE * grow
	var top: float = HILL_PORTAL_TOP + (h - HILL_PORTAL_HEIGHT) * HILL_TOP_GROWTH
	var slope: float = lerpf(HILL_PORTAL_SLOPE, HILL_SLOPE, grow)
	var run: float = h / slope
	var u: float = absf(lateral - tunnel_center_lateral())
	# Lumpier sides once it's grown, so the far flank isn't a perfect ramp.
	u += (_noise1((d * 0.01 / US) + signf(lateral) * 37.0, t.noise_seed ^ 0x55) - 0.5) * 12.0 * US * grow
	if u <= top:
		return h
	return h * (1.0 - _smooth((u - top) / run))

## Tunnel centre lateral - midway between the 3-lane shoulder edges.
static func tunnel_center_lateral() -> float:
	var right: float = RoadMetrics.RIGHT_EDGE - RoadMetrics.SHOULDER_WIDTH
	var left: float = RoadMetrics.RIGHT_EDGE + float(TUNNEL_OPEN_LANES) * LANE_W + RoadMetrics.SHOULDER_WIDTH
	return (right + left) * 0.5

## Half the hill's full base width at `d` (0 outside a hill tunnel) - how far
## out the terrain needs fine lateral samples / trees need to sit on it.
func hill_reach(d: float) -> float:
	for t in tunnels:
		if t.style == Portal.HILL and d >= t.portal_in and d < t.portal_out:
			return HILL_PORTAL_TOP + (HILL_MAX_HEIGHT + HILL_NOISE) * (HILL_TOP_GROWTH + 1.0 / HILL_SLOPE) + 14.0 * US
	return 0.0

## 1 = force forest look, 0 = force city look, -1 = leave it to BiomeMap. The
## weight ramps over BIOME_FORCE_PAD so ground colour blends in.
func biome_override(d: float) -> Vector2:
	for t in tunnels:
		var a: float
		var b: float
		if t.style == Portal.HILL:
			a = t.portal_in - BIOME_FORCE_PAD
			b = t.portal_out + BIOME_FORCE_PAD
		else:
			a = t.portal_in - TRENCH_LEN - BIOME_FORCE_PAD
			b = t.portal_out + TRENCH_LEN + BIOME_FORCE_PAD
		if d > a - BIOME_FORCE_PAD and d < b + BIOME_FORCE_PAD:
			var w: float = minf(_ramp(d, a - BIOME_FORCE_PAD, a), 1.0 - _ramp(d, b, b + BIOME_FORCE_PAD))
			return Vector2(1.0 if t.style == Portal.HILL else 0.0, w)
	return Vector2(-1.0, 0.0)

## Whether a building of half-footprint `radius` may stand at (d, lateral).
func buildings_allowed(d: float, lateral: float, radius: float) -> bool:
	# None behind the starting lay-by - its footpath and fence stand where a
	# building's front would be.
	if lateral < 0.0:
		var span := layby_span()
		if d > span[0] - LAYBY_BUILDING_MARGIN and d < span[3] + LAYBY_BUILDING_MARGIN:
			return false
	for t in tunnels:
		if t.style == Portal.HILL and d > t.portal_in - BIOME_FORCE_PAD and d < t.portal_out + BIOME_FORCE_PAD:
			return false
	for b in bridges:
		var cutoff: float = b.ramp_len * BRIDGE_BUILDING_CUTOFF
		if d > b.ramp_start + cutoff and d < b.ramp_end - cutoff:
			return false
	return not overpass_blocks(d, lateral, radius + OVERPASS_KEEP_CLEAR)

## True if (d, lateral) is within `pad` of an overpass deck's footprint. The
## deck runs along the road-local line  dist = o.d - lateral * tan(skew)
## (straight-road approximation - generous pads cover the road's curvature).
func overpass_blocks(d: float, lateral: float, pad: float) -> bool:
	for o in overpasses:
		if absf(lateral) > OVERPASS_REACH + pad:
			continue
		var line_d: float = o.d - lateral * tan(o.skew)
		if absf(d - line_d) < OVERPASS_HALF_WIDTH / cos(o.skew) + pad:
			return true
	return false

# ==========================================================================
# Barriers
# ==========================================================================

## Which barrier stands on `side` at `d`. Tunnel interiors have none (the
## tunnel walls replace it), trench approaches get retaining walls, viaduct
## ramps over land the concrete + mesh fence, and the stretch over the sea a
## bare parapet with a low rail (nothing between you and the view); elsewhere a type is rolled per forest/city
## region (BiomeMap.FOREST_REGION_LENGTH, so it changes on chunk seams).
## Round the back of the starting lay-by it's always the low guardrail (it
## follows the shoulder edge, so it wraps the bay); RoadLayby adds the fence
## further back.
func barrier_type(d: float, side: float) -> int:
	if side < 0.0 and in_layby(d):
		return Barrier.GUARDRAIL
	for t in tunnels:
		if d >= t.portal_in and d < t.portal_out:
			return Barrier.NONE
		if t.style == Portal.TRENCH and d >= t.portal_in - TRENCH_LEN and d < t.portal_out + TRENCH_LEN:
			return Barrier.RETAINING
	for b in bridges:
		if d >= b.sea_start and d < b.sea_end:
			return Barrier.PARAPET
		if d >= b.ramp_start and d < b.ramp_end:
			return Barrier.MESH_FENCE
	var region := int(floor(d / BiomeMap.FOREST_REGION_LENGTH))
	var roll: float = float(absi(hash(Vector2i(region, seed_value ^ 0xBA11))) % 10000) / 10000.0
	var forest: bool = BiomeMap.is_forest(d, seed_value)
	var ov := biome_override(d)
	if ov.y > 0.5:
		forest = ov.x > 0.5
	if forest:
		return Barrier.GUARDRAIL if roll < 0.7 else Barrier.JERSEY
	if roll < 0.4:
		return Barrier.NOISE_WALL
	if roll < 0.7:
		return Barrier.MESH_FENCE
	return Barrier.JERSEY

# ==========================================================================
# Misc
# ==========================================================================

## Smooth 1D value noise in [0, 1].
static func _noise1(x: float, seed: int) -> float:
	var i: float = floorf(x)
	var f: float = x - i
	var a: float = float(absi(hash(Vector2i(int(i), seed))) % 10000) / 10000.0
	var b: float = float(absi(hash(Vector2i(int(i) + 1, seed))) % 10000) / 10000.0
	return lerpf(a, b, _smooth(f))
