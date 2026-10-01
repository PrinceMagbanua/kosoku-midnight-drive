@tool
extends Node3D

## Root of a car's interior scene (MAIN/cars/interiors/<car>_Interior.tscn).
## Put interior lights (and anything else that should live in the cabin) in
## here - ModularCarBuilder adds this scene to the car's hull, and the cockpit
## camera shows it only while driving from the cockpit.
##
## Space: world units around the hull origin, +Z = forward, +X = left (the
## driver's side) - exactly what the editor preview shows, at in-game scale,
## so what you light here is what you get in-game.
##
## Editor preview: opening the scene builds the car (car_id) as a temporary
## "_Preview" child. It has no owner, so it's never saved, and it's skipped at
## runtime. The dash screen, steering wheel and left mirror all run in the
## preview; the "Editor Preview" values below drive them (this node stands in
## for the car they read from). The mirror reflects from the DriverCamera -
## drop a few temporary objects behind the car to see it working.
##
## DriverCamera (optional child Camera3D): the cockpit view. Select it and
## tick the viewport's "Preview" to see exactly what the driver sees; its
## position, rotation, fov and near are used in-game (ModularCarBuilder swaps
## it for a marker at runtime so it never takes over as the game camera).

const PREVIEW := "_Preview"
const KPH_PER_UNIT_SPEED := 1.10130592
const KM_PER_MILE := 1.609

@export_enum("Sedan_01", "Sports_01", "Sports_02", "Hatch_01", "Muscle_01") var car_id: String = "Sedan_01":
	set(v):
		car_id = v
		_queue_preview()
@export_enum("clear", "light_smoke", "smoke", "limo", "blue", "green", "bronze", "mirror") var preview_tint: String = "light_smoke":
	set(v):
		preview_tint = v
		_queue_preview()
## Preview the glass as the driver sees it from inside (see-through tint,
## windscreen sticker hidden) - what DriverCamera's Preview shows in-game.
## Untick to see the outside look.
@export var preview_cockpit_glass := true:
	set(v):
		preview_cockpit_glass = v
		_queue_preview()
## Tick to rebuild the preview (e.g. after re-exporting the car's GLB).
@export var rebuild_preview := false:
	set(_v):
		_queue_preview()

## Left mirror aim, like the adjuster on a real car: yaw > 0 swings the view
## outward (more of the next lane), pitch > 0 tilts it down (more road).
## fov_boost > 1 widens the view like a slightly convex wing mirror. Live in
## the editor preview and in-game (side_mirror.gd reads them).
@export_group("Left Mirror")
@export_range(-30.0, 30.0, 0.5, "suffix:°") var mirror_l_yaw := 0.0
@export_range(-30.0, 30.0, 0.5, "suffix:°") var mirror_l_pitch := 0.0
@export_range(0.5, 3.0, 0.05) var mirror_l_fov_boost := 1.35
## Extra clipping past the mirror glass (world units). The reflection already
## starts at the glass's far corner; raise this if bits of the mirror housing
## or door still show at the mirror's edge, lower it (even below 0) if things
## right next to the mirror get cut off.
@export_range(-0.5, 1.0, 0.01, "suffix:u") var mirror_l_clip := 0.05

@export_group("Editor Preview")
@export_range(-1.0, 1.0, 0.01) var steer := 0.0
@export var rpm := 4200.0
@export var RPMLimit := 7000.0
@export_range(-1, 6) var gear := 3
@export var preview_mph := 88.0
var TransmissionType := 0
var linear_velocity: Vector3:
	get:
		return Vector3(0.0, 0.0, preview_mph * KM_PER_MILE / KPH_PER_UNIT_SPEED)

func _ready() -> void:
	if Engine.is_editor_hint():
		_build_preview()

func _queue_preview() -> void:
	if Engine.is_editor_hint() and is_inside_tree():
		_build_preview.call_deferred()

func _build_preview() -> void:
	var old := get_node_or_null(PREVIEW)
	if old:
		remove_child(old)
		old.queue_free()
	if not CarManifest.has_car(car_id):
		return
	var loadout := CarManifest.preset_loadout(car_id, CarManifest.DEFAULT_PRESET, _default_paint())
	loadout.tint = preview_tint
	var hull := ModularCarBuilder.build(car_id, loadout, null, false)
	hull.name = PREVIEW
	hull.scale = Vector3.ONE * CarConfigurator.HULL_SCALE
	ModularCarBuilder.set_cockpit_view(hull, preview_cockpit_glass)
	add_child(hull) # no owner: never saved into the scene
	move_child(hull, 0)

func _default_paint() -> String:
	for p in CarCatalog.get_profiles():
		if p.manifest_id == car_id:
			return p.default_paint
	return ""
