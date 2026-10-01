class_name RoadPath
extends RefCounted

## Precomputed centerline for one run - the logical "path" (position/heading/
## bank per fixed-spacing point), kept fully separate from the actual 3D mesh
## chunks (still windowed/freed by road_generator.gd exactly as before).
## Ported from Voxel Driver's js/core.js `buildPath()`/`getFrame()`/
## `worldPos()` (curve/bank/grade math, self-intersection avoidance, NaN
## guards) - see the plan file's "curves, elevation/banking, biome tinting,
## and particle effects" section for the full research this is based on.
##
## Deliberately NOT ported (real scope, not an oversight): exit/bridge/toll/
## tunnel chapter decorations - every chapter here is geometrically either
## `sweeper` (curvable+banked) or `plain` (straight, still graded), matching
## the original's own actual geometry (its other "types" only differ by
## decorations, not curve/grade math).
##
## A full run's worth of points is a few thousand floats - trivially cheap to
## keep resident for the whole run even though the 3D meshes sampling it stay
## streamed/windowed.

const UNIT_SCALE := RoadMetrics.UNIT_SCALE

const SEG_LEN := 14.0 * UNIT_SCALE
const CURVE_MAX_DHEADING := 0.03 # rad/step peak, unitless (radians, no scale conversion)
const BANK_MAX := 0.18 # rad, ~10.3 degrees peak roll
const BANK_PER_RATE := BANK_MAX / CURVE_MAX_DHEADING
const GRADE_MAX := 0.06 # 6% grade ceiling, unitless slope ratio
const GRADE_EASE_FRAC := 0.3
const CURVE_GRADE_TRADEOFF := 0.3
const ELEVATION_SOFT_CAP := 80.0 * UNIT_SCALE
const SWEEPER_INTERVAL := 2500.0 * UNIT_SCALE
const TOTAL_LENGTH := 60000.0 * UNIT_SCALE
## Every path begins with this much dead-straight, level, unbanked road (a
## whole number of SEG_LEN) before the first curve. The starting lay-by
## (RoadLayout LAYBY_*, ending at 336 m) must sit inside it: the car parks
## there, and its props are placed rigidly.
const START_STRAIGHT_LEN := 420.0 * UNIT_SCALE
const PATH_SELF_CLEARANCE := 110.0 * UNIT_SCALE
const MAX_RETRIES := 6

const PLAIN_LEN_MIN := 500.0 * UNIT_SCALE
const PLAIN_LEN_MAX := 900.0 * UNIT_SCALE
const SWEEPER_LEN_MIN := 900.0 * UNIT_SCALE
const SWEEPER_LEN_MAX := 1600.0 * UNIT_SCALE

# Arc length of a half-circle at max sustained curvature - points within this
# trailing distance of the chapter currently being generated are the SAME
# curve, not a real self-intersection, so they're excluded from the
# proximity check.
const EXCLUDE_TAIL_DIST := (SEG_LEN / CURVE_MAX_DHEADING) * PI

const SPATIAL_CELL := PATH_SELF_CLEARANCE

var xs: PackedFloat32Array = PackedFloat32Array()
var ys: PackedFloat32Array = PackedFloat32Array()
var zs: PackedFloat32Array = PackedFloat32Array()
var headings: PackedFloat32Array = PackedFloat32Array()
var banks: PackedFloat32Array = PackedFloat32Array()
var grades: PackedFloat32Array = PackedFloat32Array() # dy/ds at each point - the exact per-step slope already computed during generation, kept for the Hermite tangent below

## chapter metadata (start/end distance, whether it curves) - useful for
## debugging/HUD later, not required for basic sampling.
var chapters: Array = []

var _rng := RandomNumberGenerator.new()
var _spatial: Dictionary = {} # Vector2i cell -> Array of point indices
var _target_length: float

## Kept (not just consumed into _rng) so other per-run systems keyed off this
## same run's identity - e.g. BiomeMap - reshuffle every run exactly like the
## curve layout does, without needing their own separate seed plumbed in.
var seed_value: int = 0

## Optional - bridges in it bend this path's grade and can hold it straight
## (see RoadLayout.grade_override / straight_weight).
var _layout: RoadLayout = null

func _init(seed: int, target_length: float = TOTAL_LENGTH, layout: RoadLayout = null) -> void:
	_rng.seed = seed
	seed_value = seed
	_target_length = target_length
	_layout = layout
	_generate()

func point_count() -> int:
	return xs.size()

func total_length() -> float:
	return float(point_count() - 1) * SEG_LEN

## Cubic Hermite spline between the two bracketing precomputed points, using
## each point's own recorded heading/grade as its exact analytic tangent
## direction (scaled by SEG_LEN) - NOT a straight-line lerp. Was a plain
## lerp originally; changed because a straight-line lerp between two
## RoadPath points is geometrically a NO-OP smoothing-wise (a chord doesn't
## curve), which is the actual reason "just sample road_frame() more often"
## didn't help the bumpy-road complaint. This still passes through both
## endpoint positions EXACTLY (so chunk/segment boundaries stay perfectly
## continuous, same as the old lerp), but also matches the exact recorded
## tangent DIRECTION at each endpoint, giving C1 (tangent) continuity across
## every point instead of the old sharp polyline kink.
##
## `heading` here is the CURVE's own tangent direction at `t` (derived from
## the Hermite derivative, atan2(dx/dt, dz/dt) matching this file's
## sin/cos-heading convention) - NOT a separate lerp of the stored heading
## values. This is deliberate: world_pos()'s banked cross-section rotates
## by `heading`, so heading here MUST match the actual curve tangent or the
## banked surface would twist away from the direction of travel - the same
## bug class as the traffic roll-axis fix (rolling around the wrong axis),
## just for the road surface itself instead of a car.
## One-entry cache: chunk builders sample many laterals at the same distance
## (world_pos per band vertex), so the same frame is asked for back to back.
## Callers must not modify the returned Dictionary.
var _cache_dist: float = NAN
var _cache_frame: Dictionary = {}

func road_frame(dist: float) -> Dictionary:
	if dist == _cache_dist:
		return _cache_frame
	_cache_frame = _road_frame_uncached(dist)
	_cache_dist = dist
	return _cache_frame

func _road_frame_uncached(dist: float) -> Dictionary:
	var d: float = clampf(dist, 0.0, total_length())
	var idx: int = clampi(int(floor(d / SEG_LEN)), 0, point_count() - 2)
	var t: float = (d - float(idx) * SEG_LEN) / SEG_LEN

	var p0 := Vector3(xs[idx], ys[idx], zs[idx])
	var p1 := Vector3(xs[idx + 1], ys[idx + 1], zs[idx + 1])
	var m0 := Vector3(sin(headings[idx]), grades[idx], cos(headings[idx])) * SEG_LEN
	var m1 := Vector3(sin(headings[idx + 1]), grades[idx + 1], cos(headings[idx + 1])) * SEG_LEN

	var t2: float = t * t
	var t3: float = t2 * t
	var h00: float = 2.0 * t3 - 3.0 * t2 + 1.0
	var h10: float = t3 - 2.0 * t2 + t
	var h01: float = -2.0 * t3 + 3.0 * t2
	var h11: float = t3 - t2
	var pos: Vector3 = h00 * p0 + h10 * m0 + h01 * p1 + h11 * m1

	var dh00: float = 6.0 * t2 - 6.0 * t
	var dh10: float = 3.0 * t2 - 4.0 * t + 1.0
	var dh01: float = -6.0 * t2 + 6.0 * t
	var dh11: float = 3.0 * t2 - 2.0 * t
	var tangent: Vector3 = dh00 * p0 + dh10 * m0 + dh01 * p1 + dh11 * m1
	var heading: float = atan2(tangent.x, tangent.z) if tangent.length_squared() > 0.0000001 else lerp_angle(headings[idx], headings[idx + 1], t)

	var bank: float = lerp_angle(banks[idx], banks[idx + 1], t)
	var curvature: float = (headings[idx + 1] - headings[idx]) / SEG_LEN
	return {"pos": pos, "heading": heading, "bank": bank, "curvature": curvature}

## Banked cross-section transform - matches worldPos(). `lateral` positive
## matches this project's existing flat-road convention (RoadMetrics'
## lane_to_x/x_to_lane, already live in traffic/lane math): +lateral is the
## SAME direction +x_frac already means today, so swapping a straight-road
## caller over to this function at heading=0 is a no-op.
func world_pos(dist: float, lateral: float) -> Vector3:
	var f := road_frame(dist)
	var heading: float = f.heading
	var bank: float = f.bank
	var cb := cos(bank)
	var sb := sin(bank)
	var rx := cos(heading)
	var rz := -sin(heading)
	var p: Vector3 = f.pos
	return Vector3(p.x + rx * lateral * cb, p.y + lateral * sb, p.z + rz * lateral * cb)

## --- Generation ------------------------------------------------------

func _generate() -> void:
	xs.append(0.0); ys.append(0.0); zs.append(0.0)
	headings.append(0.0); banks.append(0.0); grades.append(0.0)
	_spatial_insert(0)

	# Straight, flat, unbanked lead-in (see START_STRAIGHT_LEN): every run
	# starts parked in the lay-by, which sits inside it.
	var lead_points: int = int(round(START_STRAIGHT_LEN / SEG_LEN))
	for i in range(1, lead_points + 1):
		xs.append(0.0); ys.append(0.0); zs.append(float(i) * SEG_LEN)
		headings.append(0.0); banks.append(0.0); grades.append(0.0)
		_spatial_insert(i)
	chapters.append({"start_dist": 0.0, "end_dist": float(lead_points) * SEG_LEN, "is_sweeper": false})

	var dist := float(lead_points) * SEG_LEN
	var heading := 0.0
	var grade_prev := 0.0
	var elevation := 0.0
	var since_sweeper := SWEEPER_INTERVAL # the first chapter after the lead-in is a sweeper
	var next_sweeper_dir := 1.0

	while dist < _target_length:
		var is_sweeper: bool = since_sweeper >= SWEEPER_INTERVAL
		var len_min: float = SWEEPER_LEN_MIN if is_sweeper else PLAIN_LEN_MIN
		var len_max: float = SWEEPER_LEN_MAX if is_sweeper else PLAIN_LEN_MAX
		var dir: float = next_sweeper_dir

		var start_pos := Vector2(xs[xs.size() - 1], zs[zs.size() - 1])
		var result := _build_chapter(start_pos, dist, heading, grade_prev, elevation, is_sweeper, dir, len_min, len_max)

		var start_idx: int = point_count() - 1
		for pt in result.points:
			xs.append(pt.x); ys.append(pt.y); zs.append(pt.z)
			headings.append(pt.heading); banks.append(pt.bank); grades.append(pt.grade)
		for i in range(start_idx + 1, point_count()):
			_spatial_insert(i)

		chapters.append({"start_dist": dist, "end_dist": dist + result.length, "is_sweeper": is_sweeper})

		dist += result.length
		heading = result.end_heading
		grade_prev = result.end_grade
		elevation = result.end_elevation
		since_sweeper = 0.0 if is_sweeper else since_sweeper + result.length
		if is_sweeper:
			next_sweeper_dir = -dir

## Builds one chapter's worth of points (not yet committed to xs/ys/zs),
## retrying with loosened curve/length on a self-intersection or non-finite
## value, matching the original's own defensive approach - a real NaN bug
## in the source game was traced to exactly this generation step, so the
## finite-value guard is kept even in this fresh implementation.
func _build_chapter(start_pos: Vector2, start_dist: float, start_heading: float, grade_prev: float, start_elevation: float, is_sweeper: bool, dir: float, len_min: float, len_max: float) -> Dictionary:
	for attempt in range(MAX_RETRIES + 1):
		var loosen_curve: float = pow(0.75, attempt)
		var loosen_len: float = pow(0.8, attempt)
		var last_resort: bool = attempt == MAX_RETRIES
		var chapter_len: float = len_min + _rng.randf() * (len_max - len_min) * loosen_len
		var n: int = maxi(1, int(round(chapter_len / SEG_LEN)))

		var grade_target: float = clampf((_rng.randf() * 2.0 - 1.0) * GRADE_MAX, -GRADE_MAX, GRADE_MAX)
		if absf(start_elevation) > ELEVATION_SOFT_CAP:
			grade_target = -signf(start_elevation) * absf(grade_target)
		var grade_ease_steps: int = maxi(1, int(floor(float(n) * GRADE_EASE_FRAC)))

		var noise := _build_noise_track(n)

		var curvable: bool = is_sweeper and not last_resort
		var ease_steps: int = maxi(1, n / 3)
		var hold_steps: int = maxi(0, n - 2 * ease_steps)

		var pts: Array = []
		var x := start_pos.x
		var z := start_pos.y
		var heading := start_heading
		var grade := grade_prev
		var y := 0.0
		var valid := true

		for i in range(n):
			var d_heading := 0.0
			if curvable:
				var envelope: float
				if i < ease_steps:
					envelope = _smoothstep(float(i) / float(ease_steps))
				elif i < ease_steps + hold_steps:
					envelope = 1.0
				else:
					var tail: float = float(i - ease_steps - hold_steps) / float(ease_steps)
					envelope = 1.0 - _smoothstep(tail)
				var max_d_heading: float = CURVE_MAX_DHEADING * loosen_curve
				var rate: float = max_d_heading * envelope + noise[i]
				rate = clampf(rate, -max_d_heading, max_d_heading)
				d_heading = dir * rate
				# A planned feature (suspension bridge) can demand a straight
				# road - the bank below follows d_heading, so it goes flat too.
				if _layout:
					d_heading *= 1.0 - _layout.straight_weight(start_dist + float(i + 1) * SEG_LEN)
			heading += d_heading
			x += sin(heading) * SEG_LEN
			z += cos(heading) * SEG_LEN

			var g_t: float = clampf(float(i) / float(grade_ease_steps), 0.0, 1.0)
			grade = lerpf(grade_prev, grade_target, _smoothstep(g_t))
			var grade_scale: float = (1.0 - CURVE_GRADE_TRADEOFF * absf(d_heading) / CURVE_MAX_DHEADING) if curvable else 1.0
			var effective_grade: float = grade * grade_scale # the actual dy/ds used below - stored per-point as the Hermite tangent's Y component, not the raw (pre-curve-tradeoff) `grade`
			# A planned feature (bridge ramp) takes over the grade outright -
			# no curve tradeoff, so the climb integrates to exactly its height.
			if _layout:
				var ov: Vector2 = _layout.grade_override(start_dist + float(i + 1) * SEG_LEN)
				effective_grade = lerpf(effective_grade, ov.y, ov.x)
			y += effective_grade * SEG_LEN

			# Negated relative to the original three.js formula - this
			# project's own established lateral convention has +X (positive
			# lateral/x_frac) as the car's LEFT side, not right (verified
			# earlier via the traffic turn-signal fix), opposite of what the
			# ported sign assumed. Verified empirically: a left turn
			# (d_heading > 0) must raise the RIGHT/outside edge and dip the
			# LEFT/inside edge (real-world superelevation) - without this
			# negation it came out backwards (left edge raised on a left
			# turn), which is exactly the bug the user caught by eye.
			var bank: float = clampf(-d_heading * BANK_PER_RATE, -BANK_MAX, BANK_MAX) if curvable else 0.0

			if not (is_finite(x) and is_finite(z) and is_finite(y) and is_finite(heading) and is_finite(bank) and is_finite(effective_grade)):
				valid = false
				break

			pts.append({"x": x, "y": start_elevation + y, "z": z, "heading": heading, "bank": bank, "grade": effective_grade})

		if valid and (last_resort or not _intersects_existing(pts, start_dist)):
			return {
				"points": pts,
				"length": float(n) * SEG_LEN,
				"end_heading": heading,
				"end_grade": grade,
				"end_elevation": start_elevation + y,
			}

	# Unreachable (the last_resort attempt always returns) - kept as a
	# defensive fallback matching the original's own "should essentially
	# never happen" escape hatch.
	return {"points": [], "length": 0.0, "end_heading": start_heading, "end_grade": grade_prev, "end_elevation": start_elevation}

## Cheap value-noise: a handful of random control points, smoothstep-
## interpolated between them - matches buildNoiseTrack()'s organic wiggle
## layered on top of the curve envelope.
func _build_noise_track(n: int) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(n)
	var spacing: int = _rng.randi_range(10, 20)
	var amplitude: float = CURVE_MAX_DHEADING * (0.15 + _rng.randf() * 0.15)
	var control: Array = []
	var i := 0
	while i <= n:
		control.append((_rng.randf() * 2.0 - 1.0) * amplitude)
		i += spacing
	if control.is_empty():
		control.append(0.0)
	for idx in range(n):
		var f: float = float(idx) / float(spacing)
		var c0: int = clampi(int(floor(f)), 0, control.size() - 1)
		var c1: int = clampi(c0 + 1, 0, control.size() - 1)
		var t: float = f - floor(f)
		out[idx] = lerpf(control[c0], control[c1], _smoothstep(t))
	return out

func _smoothstep(t: float) -> float:
	var c: float = clampf(t, 0.0, 1.0)
	return c * c * (3.0 - 2.0 * c)

## Rejects a candidate chapter if any of its points land within
## PATH_SELF_CLEARANCE of an already-committed point more than
## EXCLUDE_TAIL_DIST behind (spatial-hash lookup, not a full scan).
func _intersects_existing(pts: Array, start_dist: float) -> bool:
	var exclude_after_dist: float = start_dist - EXCLUDE_TAIL_DIST
	for pt in pts:
		var cell := Vector2i(int(floor(pt.x / SPATIAL_CELL)), int(floor(pt.z / SPATIAL_CELL)))
		for dx in range(-1, 2):
			for dz in range(-1, 2):
				var key := Vector2i(cell.x + dx, cell.y + dz)
				if not _spatial.has(key):
					continue
				for idx in _spatial[key]:
					var idx_dist: float = float(idx) * SEG_LEN
					if idx_dist > exclude_after_dist:
						continue
					var dxp: float = xs[idx] - pt.x
					var dzp: float = zs[idx] - pt.z
					if dxp * dxp + dzp * dzp < PATH_SELF_CLEARANCE * PATH_SELF_CLEARANCE:
						return true
	return false

func _spatial_insert(idx: int) -> void:
	var cell := Vector2i(int(floor(xs[idx] / SPATIAL_CELL)), int(floor(zs[idx] / SPATIAL_CELL)))
	if not _spatial.has(cell):
		_spatial[cell] = []
	_spatial[cell].append(idx)
