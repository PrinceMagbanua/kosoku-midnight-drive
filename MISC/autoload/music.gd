extends Node

## Autoload. Background music - plays TRACKS back to back (random first
## track, then in order, looping the list), running through menus, pause and
## the crash popup alike (PROCESS_MODE_ALWAYS). Volume is BASE_VOLUME times
## the Audio Config panel's music_volume and master_volume, re-read every
## frame so the sliders apply live - same per-sound approach as the other
## volumes (see graphics.gd's master_volume note - no real audio buses yet).
## Tracks are imported with loop off so `finished` fires to advance.

const TRACKS: Array[String] = [
	"res://assets/music/Pedal Down - Tokyo Rush - Treblo.ogg",
	"res://assets/music/Pedal Down - Night Circuit - Treblo.ogg",
	"res://assets/music/Iron Street Pursuit - Neon Drift Circuit - Treblo.ogg",
]
const BASE_VOLUME := 0.2

var _player: AudioStreamPlayer
var _index := 0

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_player = AudioStreamPlayer.new()
	add_child(_player)
	_player.finished.connect(_next)
	_index = randi() % TRACKS.size()
	_play()

func _process(_delta: float) -> void:
	_apply_volume()

func _play() -> void:
	var stream := load(TRACKS[_index]) as AudioStream
	if stream == null:
		push_warning("Music: couldn't load %s" % TRACKS[_index])
		return
	_player.stream = stream
	_apply_volume()
	_player.play()

func _next() -> void:
	_index = (_index + 1) % TRACKS.size()
	_play()

func _apply_volume() -> void:
	var v: float = BASE_VOLUME * misc_graphics_settings.music_volume * misc_graphics_settings.master_volume
	_player.volume_db = linear_to_db(maxf(v, 0.0001))
