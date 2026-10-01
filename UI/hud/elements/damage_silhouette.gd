@tool
class_name DamageSilhouette
extends Control

## Top-down car outline in the HUD's bottom-left corner (front at the top,
## car's left on the left) showing each armor piece of CarDamageModel - the
## only damage readout, there's no HP bar. Styled as angular carbon-fibre
## panels (procedural twill weave) with a rose accent strip:
## - healthy: plain carbon, faint white edge
## - worn / critical: yellow / rose edge, carbon tinted to match
## - lost: no panel, a dim rose outline where it was
## A piece flashes white when it takes damage. The cabin is tinted by
## chassis HP (HudFormat.hp_color). `hit` fires on any piece or chassis loss
## so live_hud.gd can flare the whole outline.
##
## live_hud.gd calls show_damage() every frame; the flash is detected here
## by comparing against the previous frame's values.

const EDGE_HEALTHY := Color(1.0, 1.0, 1.0, 0.45)
const OUTLINE := Color(1.0, 1.0, 1.0, 0.16)
const ACCENT := HudFormat.COL_ROSE
const LOST_ALPHA := 0.4
const WORN_BELOW := 0.66
const CRITICAL_BELOW := 0.33
const DAMAGE_TINT := 0.4 # how much a worn/critical piece's carbon takes its edge colour
const CABIN_ALPHA := 0.3
const EDGE_WIDTH := 1.5
const FLASH_TIME := 0.35 # real seconds
const STRIP_HEIGHT := 3.0 # px, red accent at the bottom
const STRIP_GAP := 3.0

## Carbon weave: WEAVE_TILE px tile of 2x2 strand blocks, alternating
## direction, each shaded across its width like a round tow of fibres.
const WEAVE_TILE := 8
const CARBON_DARK := Color(0.045, 0.05, 0.058)
const CARBON_LIGHT := Color(0.2, 0.215, 0.235)

## Piece polygons in 0..1 of the car area (front at y = 0).
signal hit

const PIECES := {
	"front_bumper": [Vector2(0.24, 0.0), Vector2(0.76, 0.0), Vector2(0.94, 0.09), Vector2(0.06, 0.09)],
	"bonnet": [Vector2(0.18, 0.13), Vector2(0.82, 0.13), Vector2(0.76, 0.34), Vector2(0.24, 0.34)],
	"rear_bumper": [Vector2(0.06, 0.91), Vector2(0.94, 0.91), Vector2(0.8, 1.0), Vector2(0.2, 1.0)],
	"door_l": [Vector2(0.0, 0.38), Vector2(0.11, 0.33), Vector2(0.11, 0.74), Vector2(0.0, 0.69)],
	"door_r": [Vector2(0.89, 0.33), Vector2(1.0, 0.38), Vector2(1.0, 0.69), Vector2(0.89, 0.74)],
	"door_lf": [Vector2(0.0, 0.36), Vector2(0.11, 0.31), Vector2(0.11, 0.52), Vector2(0.0, 0.52)],
	"door_lr": [Vector2(0.0, 0.55), Vector2(0.11, 0.55), Vector2(0.11, 0.76), Vector2(0.0, 0.71)],
	"door_rf": [Vector2(0.89, 0.31), Vector2(1.0, 0.36), Vector2(1.0, 0.52), Vector2(0.89, 0.52)],
	"door_rr": [Vector2(0.89, 0.55), Vector2(1.0, 0.55), Vector2(1.0, 0.71), Vector2(0.89, 0.76)],
}
const BODY := [
	Vector2(0.2, 0.03), Vector2(0.8, 0.03), Vector2(0.9, 0.12), Vector2(0.9, 0.88),
	Vector2(0.8, 0.97), Vector2(0.2, 0.97), Vector2(0.1, 0.88), Vector2(0.1, 0.12),
]
const CABIN := [Vector2(0.27, 0.38), Vector2(0.73, 0.38), Vector2(0.79, 0.74), Vector2(0.21, 0.74)]

## Editor preview.
var _fracs := {"front_bumper": 1.0, "bonnet": 0.5, "rear_bumper": 0.2, "door_l": 1.0, "door_r": 0.0}
var _chassis := 1.0
var _flash := {} # piece id -> seconds left

static var _weave: ImageTexture

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	texture_repeat = CanvasItem.TEXTURE_REPEAT_ENABLED # the weave tiles via UVs > 1

## `fracs` = CarDamageModel.piece_fracs(), `chassis` = chassis HP 0..1.
func show_damage(fracs: Dictionary, chassis: float) -> void:
	var changed := chassis != _chassis or fracs.size() != _fracs.size()
	var was_hit := chassis < _chassis - 0.0001
	for id in fracs:
		var prev: float = _fracs.get(id, 1.0)
		if fracs[id] < prev - 0.0001:
			_flash[id] = FLASH_TIME
			was_hit = true
		if fracs[id] != prev:
			changed = true
	_fracs = fracs.duplicate()
	_chassis = chassis
	if changed:
		queue_redraw()
	if was_hit and not Engine.is_editor_hint():
		hit.emit()

func _process(delta: float) -> void:
	if _flash.is_empty():
		return
	var real_delta := delta / maxf(Engine.time_scale, 0.001)
	for id in _flash.keys():
		_flash[id] -= real_delta
		if _flash[id] <= 0.0:
			_flash.erase(id)
	queue_redraw()

func _draw() -> void:
	var weave := _weave_texture()
	_outline(_px(BODY), OUTLINE, 1.0)
	var cabin := _px(CABIN)
	_carbon(cabin, weave, Color(HudFormat.hp_color(_chassis), 1.0).lerp(Color.WHITE, 1.0 - CABIN_ALPHA))
	_outline(cabin, Color(HudFormat.hp_color(_chassis), 0.7), 1.0)
	for id in _fracs:
		if not PIECES.has(id):
			continue
		var pts := _px(PIECES[id])
		var f: float = _fracs[id]
		if f <= 0.0:
			_outline(pts, Color(HudFormat.COL_DANGER, LOST_ALPHA), 1.0)
		else:
			var edge := _edge_color(f)
			var tint := Color.WHITE if f >= WORN_BELOW else Color.WHITE.lerp(Color(edge, 1.0), DAMAGE_TINT)
			_carbon(pts, weave, tint)
			_outline(pts, edge, EDGE_WIDTH)
		if _flash.has(id):
			draw_colored_polygon(pts, Color(1, 1, 1, 0.85 * _flash[id] / FLASH_TIME))
	# Red accent strip, cut at an angle on both ends.
	var y := size.y - STRIP_HEIGHT
	var s := STRIP_HEIGHT
	draw_colored_polygon(PackedVector2Array([
		Vector2(s, y), Vector2(size.x, y), Vector2(size.x - s, size.y), Vector2(0, size.y)]), ACCENT)

func _carbon(pts: PackedVector2Array, weave: Texture2D, tint: Color) -> void:
	var uvs := PackedVector2Array()
	for p in pts:
		uvs.append(p / float(WEAVE_TILE))
	draw_colored_polygon(pts, tint, uvs, weave)

func _outline(pts: PackedVector2Array, color: Color, width: float) -> void:
	var closed := pts.duplicate()
	closed.append(pts[0])
	draw_polyline(closed, color, width, true)

func _edge_color(f: float) -> Color:
	if f < CRITICAL_BELOW:
		return HudFormat.COL_DANGER
	if f < WORN_BELOW:
		return HudFormat.COL_WARN
	return EDGE_HEALTHY

## 0..1 polygon -> pixels in the car area (everything above the accent strip).
func _px(poly: Array) -> PackedVector2Array:
	var area := Vector2(size.x, size.y - STRIP_HEIGHT - STRIP_GAP)
	var out := PackedVector2Array()
	for p in poly:
		out.append((p as Vector2) * area)
	return out

## Procedural twill weave tile, made once.
static func _weave_texture() -> ImageTexture:
	if _weave:
		return _weave
	var img := Image.create(WEAVE_TILE, WEAVE_TILE, false, Image.FORMAT_RGBA8)
	var half := WEAVE_TILE / 2
	for y in WEAVE_TILE:
		for x in WEAVE_TILE:
			var horizontal := ((x / half) + (y / half)) % 2 == 0
			var across := float(y % half) if horizontal else float(x % half)
			# Round tow: bright down the middle, dark at the edges.
			var shade := sin(PI * (across + 0.5) / float(half))
			img.set_pixel(x, y, CARBON_DARK.lerp(CARBON_LIGHT, shade * shade))
	_weave = ImageTexture.create_from_image(img)
	return _weave
