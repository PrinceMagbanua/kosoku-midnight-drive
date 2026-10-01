class_name RunGrade
extends RefCounted

## Letter grade for a finished run, from its total score (crash_overlay.gd).
## Tune the thresholds HERE - highest first, the first one the score reaches
## wins; anything under the last one is FLOOR.

const GRADES := [
	[50000, "S", HudFormat.COL_YELLOW],
	[25000, "A", HudFormat.COL_CYAN],
	[12000, "B", HudFormat.COL_CYAN],
	[6000, "C", HudFormat.COL_SMOKE],
	[3000, "D", HudFormat.COL_SMOKE],
	[1500, "E", HudFormat.COL_ROSE],
	[500, "F", HudFormat.COL_ROSE],
]
const FLOOR := "F-"
const FLOOR_COLOR := HudFormat.COL_ROSE

## {text: String, color: Color}
static func for_score(score: int) -> Dictionary:
	for g in GRADES:
		if score >= g[0]:
			return {"text": g[1], "color": g[2]}
	return {"text": FLOOR, "color": FLOOR_COLOR}
