class_name PathTracker
extends RefCounted

## Estimates a freely-moving RigidBody3D's "distance along the road" for a
## RoadPath. The player isn't mathematically locked to the track (real 3D
## physics, unlike the original three.js game's simplified travel model),
## so this is a genuine nearest-point-on-polyline problem - solved
## incrementally: each update searches only a small window of path points
## around the PREVIOUS estimate (not a full scan), matching how curved-
## track racers commonly estimate progress for a freely-moving car.
##
## This becomes the single source of truth for "player's dist" everywhere
## that used to just read `car.global_position.z` directly (valid only
## because the road used to be straight, where dist WAS z) - RunRewards,
## TrafficManager, RoadGenerator's chunk window, run_reset.gd.

var path: RoadPath
var dist: float = 0.0

const SEARCH_RADIUS_POINTS := 40 # window of path points searched each update

func _init(p: RoadPath, start_dist: float = 0.0) -> void:
	path = p
	dist = start_dist

## Call once per physics frame with the tracked body's current world
## position. Returns (and updates) the new `dist` estimate.
func update(world_pos: Vector3) -> float:
	var seg_len: float = RoadPath.SEG_LEN
	var last_idx: int = path.point_count() - 1
	var center_idx: int = clampi(int(round(dist / seg_len)), 0, last_idx)
	var lo: int = maxi(0, center_idx - SEARCH_RADIUS_POINTS)
	var hi: int = mini(last_idx, center_idx + SEARCH_RADIUS_POINTS)

	var best_idx: int = center_idx
	var best_sq: float = INF
	for i in range(lo, hi + 1):
		var dx: float = path.xs[i] - world_pos.x
		var dz: float = path.zs[i] - world_pos.z
		var sq: float = dx * dx + dz * dz
		if sq < best_sq:
			best_sq = sq
			best_idx = i

	dist = _refine_on_segments(best_idx, world_pos)
	return dist

## Snapping to the nearest SAMPLE point alone would make `dist` jumpy at
## SEG_LEN granularity - this projects onto the two segments adjacent to
## the nearest sample and picks whichever gives the closest point, for a
## smooth continuous estimate.
func _refine_on_segments(idx: int, world_pos: Vector3) -> float:
	var best: float = float(idx) * RoadPath.SEG_LEN
	var best_sq: float = INF
	var p := Vector2(world_pos.x, world_pos.z)
	for i in [idx - 1, idx]:
		if i < 0 or i + 1 >= path.point_count():
			continue
		var a := Vector2(path.xs[i], path.zs[i])
		var b := Vector2(path.xs[i + 1], path.zs[i + 1])
		var ab := b - a
		var t: float = 0.0
		if ab.length_squared() > 0.0001:
			t = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
		var proj: Vector2 = a + ab * t
		var sq: float = (p - proj).length_squared()
		if sq < best_sq:
			best_sq = sq
			best = (float(i) + t) * RoadPath.SEG_LEN
	return best
