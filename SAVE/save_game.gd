class_name SaveGame
extends Resource

## The whole persisted player-profile bundle, saved/loaded as one .tres via
## SaveData. Kept as separate sub-resources (not flattened) so each mirrors
## its Voxel Driver counterpart 1:1 and can be reset independently later.

@export var garage: GarageState = GarageState.new()
@export var difficulty: DifficultySettings = DifficultySettings.new()
## Unused now - the garage's A/T toggle was removed and the car is always
## manual (garage_screen.gd). Kept so older saves still load.
@export var transmission_mode: String = "manual" ## "auto" | "manual"
@export var handling_mode: String = "classic" ## "classic" | "grip"
@export var high_score: int = 0
