class_name HudFormat
extends RefCounted

## Shared HUD colours + text formatting, so the element scenes don't each
## carry their own copy.
##
## Palette (NFS Heat style): cyan = positive / nitro, yellow = reward,
## rose = negative / danger, smoke = neutral, asphalt = dark outline/shadow.

const COL_CYAN := Color(0.0, 1.0, 1.0) # #00ffff
const COL_YELLOW := Color(1.0, 1.0, 0.0) # #ffff00
const COL_ROSE := Color(1.0, 0.0, 0.502) # #ff0080
const COL_SMOKE := Color(0.945, 0.973, 0.988) # #f1f8fc
const COL_ASPHALT := Color(0.098, 0.098, 0.098) # #191919

const COL_GOOD := COL_SMOKE
const COL_WARN := COL_YELLOW
const COL_DANGER := COL_ROSE

## 79453 -> "79,453"
static func commas(n: int) -> String:
	var s := str(absi(n))
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out

## "1", "1.4", "10" - one decimal, trailing ".0" dropped.
static func mult_text(mult: float) -> String:
	return ("%.1f" % mult).trim_suffix(".0")

static func combo_color(mult: float) -> Color:
	if mult >= 7:
		return COL_ROSE
	if mult >= 3:
		return COL_YELLOW
	return COL_SMOKE

static func hp_color(frac: float) -> Color:
	if frac <= 0.25:
		return COL_ROSE
	if frac <= 0.5:
		return COL_YELLOW
	return COL_SMOKE
