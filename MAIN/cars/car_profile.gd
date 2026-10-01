class_name CarProfile
extends Resource

## One selectable car: which hull model it uses and the four player-facing
## stats (1-10) shown in the garage. The real physics config behind those
## stats is derived from them in one place (see CarConfigurator) - the player
## only ever sees these four numbers.

@export var id: String = ""
@export var display_name: String = ""
## For the old single-GLB cars: the hull. For modular cars: the car's
## `<Car>_Base.glb` - CarConfigurator measures the wheels/body from it.
@export var hull_scene: PackedScene
## Modular (customizable) cars: the car's key in cars_glb_manifest.json
## (e.g. "Sports_01"). Empty = an old single-GLB car.
@export var manifest_id: String = ""
## Paint texture file (see CarManifest.all_paints()) used until the player
## picks one. Empty = the manifest's first palette atlas.
@export var default_paint: String = ""
## Not used yet - every car counts as bought. Kept for when cars are for sale.
@export var price: int = 0

@export_range(1, 10) var acceleration: int = 5
@export_range(1, 10) var top_speed: int = 5
@export_range(1, 10) var handling: int = 5
@export_range(1, 10) var braking: int = 5

## Nudges the cockpit camera (car space) from the driver eye point that
## ModularCarBuilder derives from the car's steering wheel - for lining the
## view up per car if the auto-placed seat position looks off.
@export var cockpit_offset: Vector3 = Vector3.ZERO
## Manual vertical trim for the hull if the auto-fitted ride height looks off.
@export var ground_trim: float = 0.0

## Driver-feel values for this car (throttle/brake/handbrake/clutch response,
## steering sensitivity/assistance). Defaults to the base car's own values -
## every field is listed with its default already filled in, and the
## inspector's revert arrow resets a changed field back to that default. See
## CarFeelConfig for the full field list.
@export var feel: CarFeelConfig = CarFeelConfig.new()

@export_group("Stability")
## How far this car's centre of mass sits below the base car's (car units).
## The anti-rollover knob: a narrow, grippy hull trips over its outside tyres
## mid-slide unless its weight sits lower. 0 = same height as the base car.
@export_range(0.0, 1.0, 0.01) var com_drop: float = 0.0
## Multiplies tyre stiffness (how sharply the tyres bite back mid-slide).
## CarConfigurator's tyre fit picks an aspect ratio purely to match the hull's
## wheel radius, and wheel.gd derives stiffness from that ratio - so small
## wheels come out stiff by accident. 1 = as fitted.
@export_range(0.3, 2.0, 0.01) var tyre_stiffness: float = 1.0
