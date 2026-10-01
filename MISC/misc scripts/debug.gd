extends Control

var changed_graph_size = Vector2(0,0)
@export var car :NodePath = NodePath("../car")

# Child nodes, fetched once instead of on every use. Most of this overlay is
# hidden in debugger.tscn (LiveHud replaced it) - the readouts below are only
# formatted and written while their node is actually showing.
@onready var _vgs = $vgs
@onready var _power_graph = $power_graph
@onready var _graph_rpm = $power_graph/rpm
@onready var _graph_redline = $power_graph/redline
@onready var _tq = $tq
@onready var _hp = $hp
@onready var _g = $g
@onready var _container = $container
@onready var _fps = $container/fps
@onready var _weight_dist = $container/weight_dist
@onready var _sw = $sw
@onready var _sw_desired = $sw_desired
@onready var _fix_engine = $"fix engine"
@onready var _throttle = $throttle
@onready var _brake = $brake
@onready var _handbrake = $handbrake
@onready var _clutch = $clutch
@onready var _tacho = $tacho
@onready var _tacho_speedk = $tacho/speedk
@onready var _tacho_speedm = $tacho/speedm
@onready var _tacho_rpm = $tacho/rpm
@onready var _tacho_gear = $tacho/gear
@onready var _tacho_abs = $tacho/abs
@onready var _tacho_tcs = $tacho/tcs
@onready var _tacho_esp = $tacho/esp

# The node `car` points at, looked up again only when the path changes (the car
# swapper rewrites it) or the node goes away. Untyped so car.gd's vars resolve.
var _car_node
var _car_path_seen := NodePath()

func _car():
	if car != _car_path_seen or not is_instance_valid(_car_node):
		_car_path_seen = car
		_car_node = get_node_or_null(car) if not str(car) == "" else null
	return _car_node

func _ready():
	var c = _car()
	if c:
		_vgs.clear()
		for d in c.get_children():
			if "TyreSettings" in d:
				_vgs.append_wheel(d.position,d.TyreSettings,d)

		for i in _power_graph.get_script().get_script_property_list():
			if not i["name"] == "peakhp" and not i["name"] == "tr" and not i["name"] == "tr" and not i["name"] == "hp" and not i["name"] == "skip" and not i["name"] == "scale":
				if i["name"] in c:
					_power_graph.set(i["name"], c.get(i["name"]))


func _process(delta):
	VitaVehicleSimulation.misc_smoke = misc_graphics_settings.smoke

	_power_graph.visible = misc_graphics_settings.show_power_graph
	_tq.visible = misc_graphics_settings.show_power_graph
	_hp.visible = misc_graphics_settings.show_power_graph
	_vgs.visible = misc_graphics_settings.show_traction_viz
	_g.visible = misc_graphics_settings.show_gs
	_weight_dist.visible = misc_graphics_settings.show_weight_dist

	var c = _car()

	if delta>0:
		if _container.is_visible_in_tree():
			_fps.text = "fps: %d  draws: %d  tris: %dk" % [
				int(round(1.0/delta)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
				int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000.0),
			]
		if c:
			if _sw.is_visible_in_tree():
				_sw.rotation_degrees = c.steer*380.0
			if _sw_desired.is_visible_in_tree():
				_sw_desired.rotation_degrees = c.steer2*380.0
			if misc_graphics_settings.show_weight_dist and _weight_dist.is_visible_in_tree():
				if c.Debug_Mode:
					_weight_dist.text = "weight distribution: F%f/R%f" % [c.weight_dist[0]*100,c.weight_dist[1]*100]
				else:
					_weight_dist.text = "[ press F to\nfetch weight distribution ]"

	if not changed_graph_size == _power_graph.size:
		changed_graph_size = _power_graph.size
		_power_graph._ready()


	if c:

		_fix_engine.visible = c.rpm<c.DeadRPM

		if _throttle.is_visible_in_tree():
			_throttle.bar_scale = c.gaspedal
			_brake.bar_scale = c.brakepedal
			_handbrake.bar_scale = c.handbrakepull
			_clutch.bar_scale = c.clutchpedalreal

		if _hp.is_visible_in_tree():
			var hpunit = "hp"
			if _power_graph.Power_Unit == 1:
				hpunit = "bhp"
			elif _power_graph.Power_Unit == 2:
				hpunit = "ps"
			elif _power_graph.Power_Unit == 3:
				hpunit = "kW"
			_hp.text = "Power: %s%s @ %s RPM" % [str( int(_power_graph.peakhp[0]*10.0)/10.0 ), hpunit ,str( int(_power_graph.peakhp[1]*10.0)/10.0 )]

			var tqunit = "ft⋅lb"
			if _power_graph.Torque_Unit == 1:
				tqunit = "nm"
			elif _power_graph.Torque_Unit == 2:
				tqunit = "kg/m"
			_tq.text = "Torque: %s%s @ %s RPM" % [str( int(_power_graph.peaktq[0]*10.0)/10.0 ), tqunit ,str( int(_power_graph.peaktq[1]*10.0)/10.0 )]

		if _power_graph.is_visible_in_tree():
			_graph_rpm.position.x = (c.rpm/_power_graph.Generation_Range)*_power_graph.size.x -1.0
			_graph_redline.position.x = (c.RPMLimit/_power_graph.Generation_Range)*_power_graph.size.x -1.0

		if _g.is_visible_in_tree():
			_g.text = "Gs:\nx%s,\ny%s,\nz%s" % [str(int(c.gforce.x*100.0)/100.0),str(int(c.gforce.y*100.0)/100.0),str(int(c.gforce.z*100.0)/100.0)]

		if _tacho.is_visible_in_tree():
			_tacho_speedk.text = "KM/PH: " +str(int(c.linear_velocity.length()*1.10130592))
			_tacho_speedm.text = "MPH: " +str(int((c.linear_velocity.length()*1.10130592)/1.609 ) )

			_tacho.currentpsi = c.turbopsi*(c.TurboAmount)
			_tacho.currentrpm = c.rpm
			_tacho_rpm.text = str(int(c.rpm))

			if c.rpm<0:
				_tacho_rpm.self_modulate = Color(1,0,0)
			else:
				_tacho_rpm.self_modulate = Color(1,1,1)

			if c.gear == 0:
				_tacho_gear.text = "N"
			elif c.gear == -1:
				_tacho_gear.text = "R"
			else:
				if c.TransmissionType == 1 or c.TransmissionType == 2:
					_tacho_gear.text = "D"
				else:
					_tacho_gear.text = str(c.gear)

func _physics_process(delta):
	var c = _car()
	if c:
		if _vgs.is_visible_in_tree():
			_vgs.gforce -= (_vgs.gforce - Vector2(c.gforce.x,c.gforce.z))*0.5

		if _tacho.is_visible_in_tree():
			_tacho_abs.visible = c.abspump>0 and c.brakepedal>0.1
			_tacho_tcs.visible = c.tcsflash
			_tacho_esp.visible = c.espflash



func engine_restart():
	var c = _car()
	if c:
		c.rpm = c.IdleRPM


func toggle_forces():
	Input.action_press("toggle_debug_mode")
