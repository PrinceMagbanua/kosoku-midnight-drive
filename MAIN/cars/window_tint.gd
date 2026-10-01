class_name WindowTint
extends RefCounted

## Window tint presets for the modular cars' glass (Customize screen, GLASS
## tab). A loadout stores the preset id under "tint" (CarManifest.sanitize()
## validates it); ModularCarBuilder applies it to the car's own glass
## material, a duplicate of materials/car_glass.tres.
##
## color's alpha is how opaque the glass is: CLEAR shows the cabin, LIMO and
## MIRROR all but hide it.

const DEFAULT := "light_smoke"
const TINT_META := "tint_id"

## Cockpit view (see apply()'s `inside`): LIMO's 0.88 opacity becomes 0.22.
const INSIDE_ALPHA_SCALE := 0.25
const INSIDE_METALLIC_SCALE := 0.3

## Display order in the GLASS tab.
const ORDER := ["clear", "light_smoke", "smoke", "limo", "blue", "green", "bronze", "mirror"]

const TINTS := {
	"clear":       {"label": "CLEAR",       "color": Color(0.85, 0.92, 0.95, 0.12), "metallic": 0.3,  "roughness": 0.05},
	"light_smoke": {"label": "LIGHT SMOKE", "color": Color(0.25, 0.28, 0.32, 0.35), "metallic": 0.4,  "roughness": 0.05},
	"smoke":       {"label": "SMOKE",       "color": Color(0.12, 0.13, 0.15, 0.6),  "metallic": 0.5,  "roughness": 0.05},
	"limo":        {"label": "LIMO",        "color": Color(0.03, 0.03, 0.04, 0.88), "metallic": 0.6,  "roughness": 0.04},
	"blue":        {"label": "BLUE",        "color": Color(0.15, 0.35, 0.6, 0.45),  "metallic": 0.5,  "roughness": 0.05},
	"green":       {"label": "GREEN",       "color": Color(0.2, 0.45, 0.3, 0.45),   "metallic": 0.5,  "roughness": 0.05},
	"bronze":      {"label": "BRONZE",      "color": Color(0.5, 0.33, 0.15, 0.5),   "metallic": 0.6,  "roughness": 0.05},
	"mirror":      {"label": "MIRROR",      "color": Color(0.6, 0.62, 0.66, 0.85),  "metallic": 0.95, "roughness": 0.02},
}

static func ids() -> Array[String]:
	var out: Array[String] = []
	out.assign(ORDER)
	return out

static func label(id: String) -> String:
	return str(TINTS.get(id, TINTS[DEFAULT]).label)

static func color(id: String) -> Color:
	return TINTS.get(id, TINTS[DEFAULT]).color

## Tints a glass material (car_glass.tres or a duplicate of it) in place.
## `inside` = the driver's view from the cockpit: like real tint film, far
## easier to see out of than into - opacity and mirror sheen are scaled down
## so even LIMO / MIRROR stay drivable. The id is remembered on the material
## (TINT_META) so the view can be flipped later without knowing the tint.
static func apply(mat: StandardMaterial3D, id: String, inside: bool = false) -> void:
	var t: Dictionary = TINTS.get(id, TINTS[DEFAULT])
	var c: Color = t.color
	if inside:
		c.a *= INSIDE_ALPHA_SCALE
	mat.albedo_color = c
	mat.metallic = t.metallic * (INSIDE_METALLIC_SCALE if inside else 1.0)
	mat.roughness = t.roughness
	mat.set_meta(TINT_META, id)
