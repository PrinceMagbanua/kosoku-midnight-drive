extends CanvasLayer

## Garage screen over the shared 3D preview (MenuShowcase). The right-hand
## ShopPanel is the upgrade shop: one 4-column, vertically scrolling grid of
## icon tiles (UpgradeTileUI.tscn, one per UpgradeRow from
## SAVE/upgrade_catalog.gd), and under it the UpgradeInfo panel - name,
## level, description, NOW >> NEXT effect, cost, BUY and REFUND. Hovering BUY
## lights NEXT green and greys NOW out; hovering REFUND swaps NEXT to the
## level you'd drop back to, in red. REFUND ALL sits in the top bar (click
## twice to confirm). The transmission is always manual - no A/T toggle.
##
## Hovering a tile previews it in the info panel; clicking selects it, and
## the panel falls back to the selection when the mouse leaves the tile - so
## moving down to BUY (across other tiles) never changes what you're buying.
## The first purchase of NITRO / SPEEDBREAKER shows a one-time tip card
## (SaveData.has_seen_tip) explaining its key and how it refills.
##
## The "GARAGE" title, vehicle name, and credits readout live in their own
## borderless GarageHeader overlay on the left (viewport) half now, not the
## ShopPanel - floating directly over the 3D preview like the mockup's page
## chrome, rather than competing with the upgrade list for width on the right.
## Its PrevCarButton/NextCarButton cycle through CarCatalog (Sedan / Sports /
## Hatch / Muscle): the choice is saved (SaveData.set_selected_car) and
## CarProfileApplier re-dresses the preview car and the real car. The
## bottom-left CarStatsBlock shows the selected car's four stat bars and its
## BUY / BOUGHT button; the CUSTOMIZE button above it opens CustomizeScreen
## (parts/wheels/paint) over the same preview.
##
## Not included yet (no backing data/asset in this Godot project): wheel
## color, and the "handling mode" toggle (classic/grip
## was Voxel Driver's own two hand-written steering models - g-rcp2's raycast
## physics has no equivalent to switch between, so there's nothing for that
## toggle to control).

@export var car_path: NodePath = NodePath("../car")
## % unique-name lookup doesn't reach into an instanced sub-scene's internals
## (the preview/OrbitCamera now live in the sibling MenuShowcase scene,
## shared with StartScreen - see menu_showcase.gd) - hence a NodePath.
@export var orbit_camera_path: NodePath = NodePath("../MenuShowcase/Root/PreviewContainer/PreviewViewport/GaragePreview/OrbitCamera")
## The preview's turntable/settle node - the Customize screen parks the car.
@export var settle_path: NodePath = NodePath("../MenuShowcase/Root/PreviewContainer/PreviewViewport/GaragePreview/SettlePhysics")

@onready var orbit_camera: Camera3D = get_node(orbit_camera_path)
@onready var settle: Node = get_node_or_null(settle_path)
@onready var garage_header: Control = %GarageHeader
@onready var customize_button: Button = %CustomizeButton
@onready var customize_screen: CustomizeScreen = %CustomizeScreen
@onready var cash_label: Label = %CashLabel
@onready var upgrade_list: GridContainer = %UpgradeList
@onready var info_icon: TextureRect = %InfoIcon
@onready var info_placeholder: Label = %InfoPlaceholder
@onready var info_name: Label = %InfoName
@onready var info_level: Label = %InfoLevel
@onready var info_desc: Label = %InfoDesc
@onready var info_now: Label = %InfoNow
@onready var info_arrow: Label = %InfoArrow
@onready var info_next: Label = %InfoNext
@onready var refund_all_button: Button = %RefundAllButton
@onready var info_cost: Label = %InfoCost
@onready var info_buy: Button = %InfoBuyButton
@onready var info_refund: Button = %InfoRefundButton
@onready var back_button: Button = %BackButton
@onready var back_button_top: Button = %BackButtonTop
@onready var play_button: Button = %GaragePlayButton
@onready var shop_panel: Control = %ShopPanel
@onready var prev_car_button: Button = %PrevCarButton
@onready var next_car_button: Button = %NextCarButton
@onready var veh_label: Label = %VehLabel
@onready var car_stats_block: CarStatsBlock = %CarStatsBlock

const UPGRADE_TILE_SCENE := preload("res://UI/garage/UpgradeTileUI.tscn")
const UPGRADE_TILE_SCRIPT := preload("res://UI/garage/upgrade_tile_ui.gd")
## NOW / NEXT colours (the labels' font is white; these tint via modulate).
const COLOR_NOW := Color(0.8235, 0.8431, 0.8902, 1)
const COLOR_NEXT := Color(0.9098, 0.6392, 0.2392, 1) # amber accent
const COLOR_NOW_DIM := Color(0.298, 0.3294, 0.4078, 1) # while hovering BUY
const COLOR_NEXT_LIT := Color(0.42, 0.89, 0.54, 1) # green, while hovering BUY
const COLOR_REFUND_LIT := Color(1.0, 0.36, 0.36, 1) # red, while hovering REFUND
const COLOR_MAXED := Color(0.3725, 0.8157, 0.7882, 1) # teal, like MaxedButton
const EFFECT_FADE := 0.12
const REFUND_ALL_CONFIRM_TIME := 3.0 # seconds the second click has to land in
## One-time tip cards on first unlock: upgrade id -> [title, body (%s = the
## key), input action].
const UNLOCK_TIPS := {
	"nitro": ["NITRO UNLOCKED", "Hold %s to boost. Near misses and overtakes refill your bottles.", "nitro"],
	"slowmo": ["SPEEDBREAKER UNLOCKED", "Hold %s to slow time and strafe with A/D. Risky driving refills it.", "slowmo"],
}
const PANEL_ENTER_OFFSET := 340.0 # how far off-screen (to the right, its own anchored side) the panel starts before sliding in
const TRANSITION_TIME := 0.35

## Tiles by upgrade id, built once in _ready.
var _tiles := {}
var _selected_id: String = ""
var _hover_id: String = ""
var _info_id: String = "" # what the info panel shows (BUY/REFUND act on it)
var _tip_card: Control
var _buy_hover := false
var _refund_hover := false
var _effect_tween: Tween
var _refund_all_armed_until := 0.0
## Horizontal slide of the shop panel (0 = in place). Moves its two offsets
## together instead of tweening `position`: setting position on an anchored
## control rewrites its offsets from its CURRENT size, so a slide that ran
## while the panel's minimum size was briefly off (re-shown + refreshed the
## same frame, e.g. back from Customize) baked the wrong size in for good.
var _panel_slide := 0.0:
	set(v):
		_panel_slide = v
		shop_panel.offset_left = _base_offset_left + v
		shop_panel.offset_right = _base_offset_right + v
var _base_offset_left := 0.0
var _base_offset_right := 0.0
var _transitioning := false

func _ready() -> void:
	# Like the pause/crash overlays, this needs to keep responding to its own
	# buttons and animate the preview camera while the world is frozen behind
	# it - this whole subtree inherits ALWAYS (SubViewport/preview included),
	# except PreviewCar which is explicitly PROCESS_MODE_DISABLED regardless.
	process_mode = Node.PROCESS_MODE_ALWAYS
	info_buy.pressed.connect(_on_buy_pressed)
	info_buy.mouse_entered.connect(_on_buy_hover.bind(true))
	info_buy.mouse_exited.connect(_on_buy_hover.bind(false))
	info_refund.pressed.connect(_on_refund_pressed)
	info_refund.mouse_entered.connect(_on_refund_hover.bind(true))
	info_refund.mouse_exited.connect(_on_refund_hover.bind(false))
	refund_all_button.pressed.connect(_on_refund_all_pressed)
	_build_tiles()
	back_button.pressed.connect(_on_back_pressed)
	back_button_top.pressed.connect(_on_back_pressed)
	play_button.pressed.connect(_on_play_pressed)
	prev_car_button.pressed.connect(_cycle_car.bind(-1))
	next_car_button.pressed.connect(_cycle_car.bind(1))
	car_stats_block.car_bought.connect(_refresh)
	customize_button.pressed.connect(_open_customize)
	customize_screen.closed.connect(_on_customize_closed)
	GameState.state_changed.connect(_on_state_changed)
	_base_offset_left = shop_panel.offset_left
	_base_offset_right = shop_panel.offset_right
	_on_state_changed(GameState.current, GameState.current)

func _on_state_changed(new_state: GameState.State, old_state: GameState.State) -> void:
	var showing: bool = new_state == GameState.State.GARAGE
	visible = showing
	if customize_screen.is_open():
		customize_screen.force_close()
		_show_garage_chrome(1.0)
	# car.gd doesn't check GameState (kept as-is, see merge plan) - without
	# this the player car kept driving/reading input in the background while
	# browsing the garage (or, now, sitting at the main menu). SceneTree.paused
	# freezes it the same way the pause/crash overlays already freeze the
	# world behind them. Paused for GARAGE *and* MENU - must match
	# start_screen.gd's own pause predicate EXACTLY, since both screens'
	# state_changed handlers fire on every transition regardless of which
	# screen is actually visible, and whichever runs last would otherwise
	# silently undo the other's decision for the state they disagree on.
	get_tree().paused = showing or new_state == GameState.State.MENU
	if showing:
		# reset_intro() for a "was fully hidden" entry (e.g. from pause) is
		# owned by menu_showcase.gd, shared with StartScreen. Every entry starts
		# with the first upgrade selected.
		_selected_id = SaveData.upgrade_rows[0].id
		_hover_id = ""
		_close_tip_card()
		orbit_camera.set_mode("car")
		_refresh()
		# The nice slide+fade entrance only makes sense coming from the Start
		# screen's own exit tween (continuous glide) - from PAUSE, snap in
		# instantly like before, no start-screen involvement to match up with.
		if old_state == GameState.State.MENU:
			_panel_slide = PANEL_ENTER_OFFSET
			shop_panel.modulate.a = 0.0
			var tw := create_tween()
			tw.tween_property(self, "_panel_slide", 0.0, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
			tw.parallel().tween_property(shop_panel, "modulate:a", 1.0, TRANSITION_TIME)
		else:
			_panel_slide = 0.0
			shop_panel.modulate.a = 1.0
	elif new_state == GameState.State.PLAYING:
		_apply_transmission_to_car()

func _on_back_pressed() -> void:
	# Entered from pause's "end run -> garage" flow: drop straight back into
	# a fresh run instead of the main menu (mirrors resumeToPlayingAfterGarage
	# in hud-crash.js).
	if GameState.resume_to_playing_after_garage:
		GameState.resume_to_playing_after_garage = false
		_apply_transmission_to_car()
		LoadingScreen.enter_drive(func(): GameState.set_state(GameState.State.PLAYING))
		return
	if _transitioning:
		return
	_transitioning = true
	orbit_camera.set_mode("start")
	var tw := create_tween()
	tw.tween_property(self, "_panel_slide", PANEL_ENTER_OFFSET, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(shop_panel, "modulate:a", 0.0, TRANSITION_TIME)
	tw.finished.connect(func():
		_transitioning = false
		GameState.set_state(GameState.State.MENU)
	)

## CUSTOMIZE: the shop panel slides out (same motion as leaving the garage)
## and the header/stats fade, then the Customize screen takes over the same
## preview. Its BACK brings everything back.
func _open_customize() -> void:
	if _transitioning or customize_screen.is_open():
		return
	_transitioning = true
	var tw := create_tween()
	tw.tween_property(self, "_panel_slide", PANEL_ENTER_OFFSET, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.parallel().tween_property(shop_panel, "modulate:a", 0.0, TRANSITION_TIME)
	for c in _garage_chrome():
		tw.parallel().tween_property(c, "modulate:a", 0.0, TRANSITION_TIME)
	tw.finished.connect(func():
		_transitioning = false
		_set_garage_chrome_visible(false)
		customize_screen.open(orbit_camera, settle)
	)

func _on_customize_closed() -> void:
	orbit_camera.set_mode("car")
	_set_garage_chrome_visible(true)
	_refresh()
	_panel_slide = PANEL_ENTER_OFFSET
	var tw := create_tween()
	tw.tween_property(self, "_panel_slide", 0.0, TRANSITION_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.parallel().tween_property(shop_panel, "modulate:a", 1.0, TRANSITION_TIME)
	for c in _garage_chrome():
		tw.parallel().tween_property(c, "modulate:a", 1.0, TRANSITION_TIME)

## The garage's own floating elements over the preview (not the shop panel).
func _garage_chrome() -> Array[Control]:
	var out: Array[Control] = [garage_header, car_stats_block, customize_button]
	return out

func _set_garage_chrome_visible(on: bool) -> void:
	shop_panel.visible = on
	for c in _garage_chrome():
		c.visible = on

func _show_garage_chrome(alpha: float) -> void:
	_set_garage_chrome_visible(true)
	shop_panel.modulate.a = alpha
	_panel_slide = 0.0
	for c in _garage_chrome():
		c.modulate.a = alpha

func _on_play_pressed() -> void:
	GameState.resume_to_playing_after_garage = false
	_apply_transmission_to_car()
	LoadingScreen.enter_drive(func(): GameState.set_state(GameState.State.PLAYING))

func _apply_transmission_to_car() -> void:
	var car: Node = get_node_or_null(car_path)
	if car == null:
		return
	# car.gd's TransmissionType export_enum: 0=Fully Manual. Always manual -
	# the garage's A/T toggle was removed (SaveGame.transmission_mode unused).
	car.TransmissionType = 0

## Steps the selected car by `step` (wraps around). Saving the selection makes
## CarProfileApplier swap the preview and real cars; _refresh() updates the
## label, bars and BUY/BOUGHT button.
func _cycle_car(step: int) -> void:
	var count := CarCatalog.count()
	SaveData.set_selected_car(posmod(SaveData.get_selected_car_index() + step, count))
	_refresh()

func _refresh() -> void:
	var car_index := SaveData.get_selected_car_index()
	veh_label.text = CarCatalog.get_profile(car_index).display_name
	customize_button.visible = not CarCatalog.get_profile(car_index).manifest_id.is_empty() \
		and not customize_screen.is_open()
	car_stats_block.show_car(car_index)
	cash_label.text = "$%d" % SaveData.game.garage.cash
	_refresh_upgrades()

# --- upgrade grid + info panel ----------------------------------------------

func _build_tiles() -> void:
	for child in upgrade_list.get_children():
		child.queue_free()
	_tiles.clear()
	for row in SaveData.upgrade_rows:
		var tile := UPGRADE_TILE_SCENE.instantiate()
		upgrade_list.add_child(tile)
		tile.hovered.connect(_on_tile_hovered)
		tile.unhovered.connect(_on_tile_unhovered)
		tile.clicked.connect(_on_tile_clicked)
		_tiles[row.id] = tile

func _refresh_upgrades() -> void:
	for row in SaveData.upgrade_rows:
		_tiles[row.id].setup(row, SaveData.get_upgrade_tier(row.id), SaveData.can_afford_upgrade(row.id))
	if not _tiles.has(_selected_id):
		_selected_id = SaveData.upgrade_rows[0].id
	for id in _tiles:
		_tiles[id].set_selected(id == _selected_id)
	_show_info(_hover_id if _tiles.has(_hover_id) else _selected_id)
	_refresh_refund_all()

func _on_tile_hovered(id: String) -> void:
	_hover_id = id
	_show_info(id)

func _on_tile_unhovered(id: String) -> void:
	if _hover_id == id:
		_hover_id = ""
		_show_info(_selected_id)

func _on_tile_clicked(id: String) -> void:
	_selected_id = id
	for tid in _tiles:
		_tiles[tid].set_selected(tid == id)
	_show_info(id)

## Fills the info panel for `id`. BUY/REFUND act on whatever it shows, which
## is the selected tile whenever the mouse is off the grid.
func _show_info(id: String) -> void:
	_info_id = id
	var row := SaveData.get_upgrade_row(id)
	if row == null:
		return
	var tier := SaveData.get_upgrade_tier(id)
	var maxed := tier >= row.max_tier
	_set_info_icon(row.icon, id)
	info_name.text = row.display_name
	info_level.text = "LV %d / %d" % [tier, row.max_tier]
	info_desc.text = row.description
	info_refund.disabled = tier <= 0
	info_refund.text = "REFUND $%d" % row.refund_for_tier(tier - 1) if tier > 0 else "REFUND"
	info_cost.visible = not maxed
	if maxed:
		info_buy.text = "MAX"
		info_buy.disabled = true
		info_buy.theme_type_variation = &"MaxedButton"
	else:
		info_cost.text = "$%d" % row.cost_for_tier(tier)
		info_buy.text = "BUY"
		info_buy.disabled = not SaveData.can_afford_upgrade(id)
		info_buy.theme_type_variation = &"BuyButton"
	_update_effect(true)

## NOW >> NEXT line, text and tint. Idle: NOW light, NEXT amber (maxed: the
## effect, then MAX in teal). Mouse on an enabled BUY: NOW greys out, NEXT
## lights green. Mouse on an enabled REFUND: NOW greys out and NEXT shows the
## level you'd drop back to, in red.
func _update_effect(instant := false) -> void:
	var row := SaveData.get_upgrade_row(_info_id)
	if row == null:
		return
	var tier := SaveData.get_upgrade_tier(_info_id)
	var maxed := tier >= row.max_tier
	var refunding := _refund_hover and not info_refund.disabled
	var buying := _buy_hover and not info_buy.disabled and not maxed
	var now_c := COLOR_NOW
	var next_c := COLOR_NEXT
	if refunding:
		info_now.text = "NOW  %s" % row.effect_text(tier)
		info_next.text = "NEXT  %s" % row.effect_text(tier - 1)
		now_c = COLOR_NOW_DIM
		next_c = COLOR_REFUND_LIT
	elif maxed:
		info_now.text = row.effect_text(tier)
		info_next.text = "MAX"
		next_c = COLOR_MAXED
	else:
		info_now.text = "NOW  %s" % row.effect_text(tier)
		info_next.text = "NEXT  %s" % row.effect_text(tier + 1)
		if buying:
			now_c = COLOR_NOW_DIM
			next_c = COLOR_NEXT_LIT
	if _effect_tween:
		_effect_tween.kill()
	if instant:
		info_now.modulate = now_c
		info_arrow.modulate = now_c
		info_next.modulate = next_c
		return
	_effect_tween = create_tween().set_parallel()
	_effect_tween.tween_property(info_now, "modulate", now_c, EFFECT_FADE)
	_effect_tween.tween_property(info_arrow, "modulate", now_c, EFFECT_FADE)
	_effect_tween.tween_property(info_next, "modulate", next_c, EFFECT_FADE)

func _on_buy_hover(on: bool) -> void:
	_buy_hover = on
	_update_effect()

func _on_refund_hover(on: bool) -> void:
	_refund_hover = on
	_update_effect()

func _set_info_icon(icon: Texture2D, id: String) -> void:
	info_icon.texture = icon
	info_icon.visible = icon != null
	info_placeholder.visible = icon == null
	info_placeholder.text = UPGRADE_TILE_SCRIPT.PLACEHOLDER.get(id, id.left(3).to_upper())

func _on_buy_pressed() -> void:
	var id := _info_id
	var was := SaveData.get_upgrade_tier(id)
	if not SaveData.buy_upgrade(id):
		return
	_selected_id = id
	_refresh()
	if was == 0 and UNLOCK_TIPS.has(id) and not SaveData.has_seen_tip(id):
		SaveData.mark_tip_seen(id)
		_show_tip_card(id)

func _on_refund_pressed() -> void:
	if SaveData.sell_upgrade(_info_id):
		_selected_id = _info_id
		_refresh()

## REFUND ALL (top bar): the first click arms it and shows what you'd get
## back; a second click within REFUND_ALL_CONFIRM_TIME sells everything.
func _on_refund_all_pressed() -> void:
	if _now() > _refund_all_armed_until:
		_refund_all_armed_until = _now() + REFUND_ALL_CONFIRM_TIME
		_refresh_refund_all()
		get_tree().create_timer(REFUND_ALL_CONFIRM_TIME + 0.05).timeout.connect(_refresh_refund_all)
		return
	_refund_all_armed_until = 0.0
	SaveData.refund_all()
	_refresh()

func _refresh_refund_all() -> void:
	var total := SaveData.refund_all_total()
	if total <= 0:
		_refund_all_armed_until = 0.0
	refund_all_button.disabled = total <= 0
	if _now() <= _refund_all_armed_until:
		refund_all_button.text = "CONFIRM  +$%d" % total
	else:
		refund_all_button.text = "REFUND ALL"
	refund_all_button.tooltip_text = "Sell every upgrade level for %d%% back" % roundi(UpgradeCatalog.REFUND_FRACTION * 100.0)

static func _now() -> float:
	return Time.get_ticks_msec() / 1000.0

# --- unlock tip card ---------------------------------------------------------

## A one-time card over the shop panel: the upgrade's icon, "X UNLOCKED", how
## to use it (with the action's current key) and a GOT IT button.
func _show_tip_card(id: String) -> void:
	_close_tip_card()
	var tip: Array = UNLOCK_TIPS[id]
	var row := SaveData.get_upgrade_row(id)

	var dim := ColorRect.new()
	dim.color = Color(0.051, 0.0667, 0.098, 0.7)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	shop_panel.add_child(dim) # a MarginContainer child, so it covers the panel
	_tip_card = dim

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.add_child(center)
	var card := PanelContainer.new()
	card.theme_type_variation = &"UpgradeTileSelected"
	card.custom_minimum_size = Vector2(340, 0)
	center.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 12)
	card.add_child(box)

	var icon_rect := TextureRect.new()
	icon_rect.texture = row.icon
	icon_rect.custom_minimum_size = Vector2(0, 64)
	icon_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	icon_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	icon_rect.visible = row.icon != null
	box.add_child(icon_rect)
	var title := Label.new()
	title.theme_type_variation = &"UpgradeNameLabel"
	title.text = tip[0]
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var body := Label.new()
	body.theme_type_variation = &"UpgradeInfoDesc"
	body.text = tip[1] % _action_key(tip[2])
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(body)
	var ok := Button.new()
	ok.theme_type_variation = &"BuyButton"
	ok.text = "GOT IT"
	ok.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	ok.custom_minimum_size = Vector2(120, 0)
	ok.pressed.connect(_close_tip_card)
	box.add_child(ok)

	dim.modulate.a = 0.0
	create_tween().tween_property(dim, "modulate:a", 1.0, 0.2)

func _close_tip_card() -> void:
	if _tip_card:
		_tip_card.queue_free()
		_tip_card = null

## Display name of the first key bound to `action` ("SHIFT", "CTRL"...).
static func _action_key(action: String) -> String:
	for ev in InputMap.action_get_events(action):
		var key := ev as InputEventKey
		if key:
			var code := key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
			return OS.get_keycode_string(code).to_upper()
	return action.to_upper()
