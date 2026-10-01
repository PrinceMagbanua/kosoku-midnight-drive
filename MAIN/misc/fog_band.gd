extends Node

## Keeps the night fog as a low, ground-hugging haze band instead of a fog
## that covers everything. Godot's height fog is thickest BELOW `fog_height`
## and fades to nothing above it (it depends on a surface's world height, not
## its distance), so the sky and the tops of tall buildings stay clear. This
## follows the player car's altitude each frame - the road climbs and
## descends, so a fixed world-height band would leave the car above or below
## it on hills.
##
## Lives as a child of the WorldEnvironment (NightEnvironment.tscn) and edits
## whatever Environment that node currently uses, so it also works with the
## override world.tscn carries. Distance fog is off (fog_density 0) in those
## environments; sky_affect stays 0 so fog never paints the sky itself.
##
## Units are world units (about 3.27 per metre). Tuning:
##  - band_height: how far above the car the haze reaches (bigger = taller band)
##  - haze_density: haze strength; roughly the fog amount at car level is
##    1 - exp(-band_height * haze_density) (defaults: about 38%).

@export var band_height: float = 200.0
@export var haze_density: float = 0.001

var _car: Node3D # the player car, looked up again only if it goes away

func _process(_delta: float) -> void:
	var world_env := get_parent() as WorldEnvironment
	if world_env == null or world_env.environment == null:
		return
	if not is_instance_valid(_car):
		_car = get_tree().get_first_node_in_group("player_car") as Node3D
	var base_y: float = _car.global_position.y if _car else 0.0
	var env := world_env.environment
	env.fog_height = base_y + band_height
	env.fog_height_density = haze_density
