extends Node

## Drop this into a scene next to a player-car instance (world.tscn's `car`,
## GaragePreview.tscn's `PreviewCar`) and it dresses that car as the currently
## selected CarProfile. It applies in _enter_tree - i.e. BEFORE the car's own
## _ready() and its hull-bound scripts run - so the car boots already fitted
## and nothing has to be rebuilt. It also re-applies live whenever the
## selection changes (garage car switching); for the frozen garage preview it
## then asks the settle node to let the new suspension settle again.

@export var car_path: NodePath = NodePath("../car")
## Optional: the cockpit camera (takes the profile's cockpit_offset eye nudge).
@export var cockpit_path: NodePath = NodePath("../cam_cockpit")
## Optional: garage_preview_settle.gd, so a live swap re-settles the suspension.
@export var settle_path: NodePath = NodePath()
## Testing aid: set to a CarCatalog index (0 Sedan, 1 Sports, 2 Hatch,
## 3 Muscle) on THIS node to force that car regardless of the saved
## selection. -1 = follow the saved selection (leave it at -1 normally).
@export var force_index: int = -1

func _enter_tree() -> void:
	_apply()

func _ready() -> void:
	SaveData.selected_car_changed.connect(_on_selection_changed)
	SaveData.upgrades_changed.connect(_on_upgrades_changed)
	SaveData.loadout_changed.connect(_on_loadout_changed)

## Customize screen edits (parts/wheels/paint) - re-dress in place.
func _on_loadout_changed(car_id: String) -> void:
	var profile := CarCatalog.get_profile(_selected_index())
	var car := get_node_or_null(car_path) as Node3D
	if car and profile.id == car_id:
		CarConfigurator.refresh_loadout(car, profile)

## Stat upgrades change the car's physics (CarStats) - re-tune in place.
func _on_upgrades_changed() -> void:
	var car := get_node_or_null(car_path) as Node3D
	if car:
		CarConfigurator.retune(car, CarCatalog.get_profile(_selected_index()))

func _selected_index() -> int:
	return force_index if force_index >= 0 else SaveData.get_selected_car_index()

func _on_selection_changed(_index: int) -> void:
	_apply()
	if not settle_path.is_empty():
		var settle: Node = get_node_or_null(settle_path)
		if settle and settle.has_method("resettle"):
			settle.resettle()

func _apply() -> void:
	var profile := CarCatalog.get_profile(_selected_index())
	var car := get_node_or_null(car_path) as Node3D
	if car:
		CarConfigurator.apply(car, profile)
	if not cockpit_path.is_empty():
		var cockpit: Node = get_node_or_null(cockpit_path)
		if cockpit and cockpit.has_method("apply_profile"):
			cockpit.apply_profile(profile)
