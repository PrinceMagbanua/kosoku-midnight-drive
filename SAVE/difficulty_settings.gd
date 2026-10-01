class_name DifficultySettings
extends Resource

## Mirrors Voxel Driver's `difficultySettings` (core.js) - the old "MAP
## UPGRADES" panel. No longer sold (nothing in gameplay read it); kept only so
## old saves still load - SaveData refunds and zeroes it on migration.

@export var heavy_traffic: int = 0
@export var rain_amount: int = 0
@export var aggressive_npcs: int = 0
@export var night: bool = false
@export var blockers: int = 0
@export var highway_curves: int = 0
@export var more_hazards: int = 0
@export var blackout_chance: float = 0.0
