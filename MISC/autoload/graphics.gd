extends Node

## Audio Config volumes persist across launches in their own small file
## (not SaveData's savegame.tres - these are machine/user prefs, not
## progress). Keys double as the var names below; values are the defaults
## used on first launch and by the panel's Reset button.
const AUDIO_SETTINGS_PATH := "user://audio_settings.cfg"
const AUDIO_DEFAULTS := {
	"master_volume": 0.5,
	"music_volume": 1.0,
	"engine_volume": 0.3,
	"tyre_volume": 1.0,
	"sfx_volume": 1.0,
}

var reflections :bool = false
var shadows :bool = false
var smoke :bool = true
var fxaa :bool = false
var fs :bool = false

var skytype :int = 0

## Debug HUD display toggles (Graphics Config panel) - all default off,
## user has to tick them on to show. Read by debug.gd each frame to gate
## visibility of the torque/power graph, traction/CoG visualizer, and the
## "Gs:" readout.
var show_power_graph :bool = false
var show_traction_viz :bool = false
var show_gs :bool = false
var show_weight_dist :bool = false

## Master engine volume (Audio Config panel), 0..1 - multiplies into
## crossfade.gd's own per-instance overall_volume. Default lowered to 0.3
## per request (the engine sound was too loud at the old 1.0 default).
var engine_volume :float = AUDIO_DEFAULTS["engine_volume"]

## Master tyre/screech volume (Audio Config panel), 0..1 - multiplies into
## tyres.gd's skid/roll/dirt sound output. Left at the original 1.0 level -
## only the engine was reported as too loud - but exposed as its own
## control since it wasn't covered by engine_volume at all.
var tyre_volume :float = AUDIO_DEFAULTS["tyre_volume"]

## One-shot gameplay SFX volume (Audio Config panel), 0..1 - covers the
## nitro/overtake/scrape/crash/change-view sounds (nitro_boost.gd,
## camera_mode_switch.gd, crash_system.gd), kept as its own bucket separate
## from engine_volume/tyre_volume since those are continuous mechanical
## sounds, not one-shot cues.
var sfx_volume :float = AUDIO_DEFAULTS["sfx_volume"]

## Overall volume (Audio Config panel), 0..1 - multiplies into ALL of the
## above (engine/tyre/sfx), same way a hardware "master" knob would. This
## project has no real AudioServer bus routing yet (every sound script reads
## its own misc_graphics_settings.*_volume directly and computes its own
## volume_db), so this is applied the same way - each sound multiplies its
## own category volume by this one, not a true bus. Defaults to 50%.
var master_volume :float = AUDIO_DEFAULTS["master_volume"]

## Music volume (Audio Config panel), 0..1 - multiplies into the Music
## autoload's (MISC/autoload/music.gd) own 20% base level.
var music_volume :float = AUDIO_DEFAULTS["music_volume"]

## Bloom/glow intensity (Graphics Config panel), 0..1 - a multiplier on the
## glow authored in each Environment in the editor, applied live by
## bloom_setting_applier.gd (one shared script on each WorldEnvironment, not
## two copies). 1 = exactly the editor look; 0 disables glow entirely
## (cheapest, matches "off").
var bloom_intensity :float = 0.2

## Roadside trees (Graphics Config panel) - read by road_generator.gd /
## roadside_trees.gd. show_trees and tree_shadows apply live to every
## existing tree batch; tree_density (0..1 multiplier) only affects chunks
## built after it changes. Shadows default off - the moonlight is so dim they
## barely read, and each shadow caster is drawn again into the shadow map.
var show_trees :bool = true
var tree_shadows :bool = false
var tree_density :float = 1.0

## Distant mountain/city silhouette bands (MAIN/misc/skyline.gd).
var show_skyline :bool = true

## Borderlands-style ink outlines on cars (MAIN/misc/car_outline/
## car_outlines.gd). Both apply live. car_outline_width is a 0..1 slider,
## mapped to pixels by car_outlines.gd's MAX_PX.
var car_outlines :bool = true
var car_outline_width :float = 0.3

## Live side mirror in cockpit view (MAIN/cars/side_mirror.gd) - a second
## render of the scene while driving from the cockpit, so it's switchable.
var side_mirror :bool = true

## HUD sways with the car's G-forces and jolts on crashes (UI/hud/hud_sway.gd).
var hud_sway :bool = true


var fs2 :bool = false

## Loaded in _init, not _ready: autoload _ready can run after the main
## scene's panels have already read (and written back) the defaults.
func _init():
	load_audio_settings()

func load_audio_settings():
	var cfg := ConfigFile.new()
	if cfg.load(AUDIO_SETTINGS_PATH) != OK:
		return
	for key in AUDIO_DEFAULTS:
		set(key, clampf(float(cfg.get_value("audio", key, AUDIO_DEFAULTS[key])), 0.0, 1.0))

func save_audio_settings():
	var cfg := ConfigFile.new()
	for key in AUDIO_DEFAULTS:
		cfg.set_value("audio", key, get(key))
	cfg.save(AUDIO_SETTINGS_PATH)

func _process(delta):
#	get_viewport().fxaa = fxaa
	
	if fxaa:
		get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	else:
		get_viewport().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	
	if not fs2 == fs:
		fs2 = fs
		fs_toggle()

func fs_toggle():
	if not fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		DisplayServer.window_set_size(Vector2i(ProjectSettings.get("display/window/size/viewport_width"),ProjectSettings.get("display/window/size/viewport_height")))
		
		DisplayServer.window_set_position(DisplayServer.screen_get_size()/2 - Vector2i(ProjectSettings.get("display/window/size/viewport_width"),ProjectSettings.get("display/window/size/viewport_height"))/2)
#		DisplayServer.window_borderless = false
#		OS.window_size = Vector2(ProjectSettings.get("display/window/size/width"),ProjectSettings.get("display/window/size/height"))
#		OS.window_position = OS.get_screen_size()/2 -Vector2(ProjectSettings.get("display/window/size/width"),ProjectSettings.get("display/window/size/height"))/2
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		
#		OS.window_borderless = true
#		OS.window_size = OS.get_screen_size()
#		OS.window_size.y += 1
#		OS.window_position = Vector2(0,0)
