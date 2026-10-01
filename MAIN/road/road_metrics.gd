class_name RoadMetrics
extends RefCounted

## Single source of truth for lane geometry - shared by road_generator.gd and
## the traffic system. Voxel Driver's traffic.js documents a real regression
## (AGENTS.md) where placeTrafficCar() inlined its own copy of the lane->x
## formula with a different scale factor than the visual lane-divider lines,
## bunching lanes toward the centerline. The fix there was "exactly one
## formula, everything calls through it, never reimplement it locally" -
## same rule applies here, hence this being its own file instead of living
## duplicated inside road_generator.gd and traffic_manager.gd.

const UNIT_SCALE := 3.268828 # units per metre, per this project's README
const LANES := 4
const ROAD_HALF_WIDTH := 6.0525 * LANES / 3.0 * UNIT_SCALE # core.js line 18, converted
const LANE_WIDTH := 2.0 * ROAD_HALF_WIDTH / LANES
## Paved strip between the outermost lane and the barrier, each side.
const SHOULDER_WIDTH := 2.2 * UNIT_SCALE
## Lanes are counted from this (right, -lateral) edge, which never moves.
## RoadLayout closes/opens lanes on the LEFT (+lateral, highest index) side,
## so a lane's centre is the same everywhere and only the left edge shifts.
## LANES is the widest the road ever gets - traffic sizes its per-lane arrays
## from it; RoadLayout.open_lanes_at() says how many exist at a distance.
const RIGHT_EDGE := -ROAD_HALF_WIDTH

## Normalized lane center, fraction of ROAD_HALF_WIDTH in [-1, 1]. Matches
## traffic.js's laneToX() exactly (as a fraction - see lane_to_x for world units).
static func lane_to_frac(lane: float) -> float:
	return (2.0 * (lane + 0.5) / LANES) - 1.0

## World-space lateral offset (in this project's units, already UNIT_SCALE'd).
static func lane_to_x(lane: float) -> float:
	return lane_to_frac(lane) * ROAD_HALF_WIDTH

static func x_to_lane(x_world: float) -> int:
	var frac: float = x_world / ROAD_HALF_WIDTH
	var lane: int = int(round((frac + 1.0) * LANES / 2.0 - 0.5))
	return clampi(lane, 0, LANES - 1)
