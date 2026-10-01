class_name CarStatsBlock
extends Control

## Bottom-left garage section: the selected car's four stats as thin glowing
## bars (base value + a second colour for what purchased upgrades add), and on
## its right the BUY / BOUGHT button. Fully transparent - no panel - like the
## other floating elements over the 3D preview.

signal car_bought

@onready var _accel: StatBar = %AccelBar
@onready var _top: StatBar = %TopBar
@onready var _handling: StatBar = %HandlingBar
@onready var _braking: StatBar = %BrakingBar
@onready var _buy_button: Button = %BuyCarButton

var _profile: CarProfile

func _ready() -> void:
	_buy_button.pressed.connect(_on_buy_pressed)

## Shows the car at `index` in CarCatalog.
func show_car(index: int) -> void:
	_profile = CarCatalog.get_profile(index)
	var base := CarStats.base(_profile)
	var eff := CarStats.display(_profile)
	_set_bar(_accel, base.acceleration, eff.acceleration)
	_set_bar(_top, base.top_speed, eff.top_speed)
	_set_bar(_handling, base.handling, eff.handling)
	_set_bar(_braking, base.braking, eff.braking)
	_refresh_buy_button()

func _set_bar(bar: StatBar, base_stat: float, effective_stat: float) -> void:
	bar.base_value = base_stat / CarStats.STAT_MAX
	bar.bonus_value = maxf(effective_stat - base_stat, 0.0) / CarStats.STAT_MAX

func _refresh_buy_button() -> void:
	if SaveData.owns_car(_profile.id):
		_buy_button.text = "BOUGHT"
		_buy_button.disabled = true
	else:
		_buy_button.text = "$%d" % _profile.price
		_buy_button.disabled = SaveData.game.garage.cash < _profile.price

func _on_buy_pressed() -> void:
	if _profile and SaveData.buy_car(_profile.id):
		_refresh_buy_button()
		car_bought.emit()
