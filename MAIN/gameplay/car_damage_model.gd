class_name CarDamageModel
extends RefCounted

## Player car damage as armor + chassis (see the part-damage plan). Body
## panels are armor zones around a chassis HP pool:
## - FRONT: front bumper, then bonnet (two layers, outermost first)
## - LEFT / RIGHT: the doors (one per side, or front + rear on 4-door cars -
##   the contact's position along the car picks which)
## - REAR: rear bumper
## While a zone still has armor, hits and scrapes there only wear the armor;
## the chassis (the run's real HP) only takes damage once that zone is exposed.
## Pure logic, no nodes - CrashSystem feeds it classified hits/scrapes and
## CarPartDetacher turns lost pieces into visuals.
##
## Hit severity is `frac` = closing speed / CrashSystem.REFERENCE_MAX_SPEED.

enum Zone { FRONT, LEFT, RIGHT, REAR }

## Front/rear hits by severity: below TAP_FRAC it only dents the outer layer;
## up to HARD_FRAC it breaks the outermost layer; from HARD_FRAC up it rips
## through the layers (both front ones at base armor).
const TAP_FRAC := 0.12 # ~22 km/h closing
const HARD_FRAC := 0.45
## A tap at TAP_FRAC takes this much of a base-armor piece (so ~3 taps break it).
const TAP_DENT := 0.35
## Light hit damage to the outermost layer, from just above a tap to just
## under a hard hit - a max-armor piece (2.05) survives all of them, and only
## just the gentlest hard hit.
const LIGHT_DAMAGE_MIN := 1.0
const LIGHT_DAMAGE_MAX := 1.75
## Hard hit damage at HARD_FRAC, rising with severity; carries through layers.
const HARD_DAMAGE := 2.0
const HARD_DAMAGE_MAX := 4.0
## Side hits (doors) scale continuously: closing speed of SIDE_RIP_FRAC rips a
## base door off in one go; a same-speed sideswipe only dents it.
const SIDE_RIP_FRAC := 0.35
const SIDE_DAMAGE_MAX := 2.5
## Hit on an exposed zone: CHASSIS_HARD_HIT of max chassis at HARD_FRAC,
## scaled by severity and capped at CHASSIS_HIT_CAP (so 3 hard head-ons kill:
## the first strips the armor, the next two take 60% each).
const CHASSIS_HARD_HIT := 0.6
const CHASSIS_HIT_CAP := 0.75
## Scraping (wall slide / grinding a car): armor lost per second at
## REFERENCE_MAX_SPEED of slide - a full-speed wall ride rips a door in ~1.5 s.
const SCRAPE_RATE := 0.67
## Scraping an exposed zone: fraction of max chassis per second at full slide.
const EXPOSED_SCRAPE_RATE := 0.15

## Engine health states by chassis fraction (smoke/knock/flames - phase 3).
enum EngineState { HEALTHY, SMOKING, KNOCKING, BURNING }
const SMOKE_BELOW := 0.5
const KNOCK_BELOW := 0.25
const BURN_BELOW := 0.1

## A piece lost its last HP. `hit_side` is "L"/"R" - the side of the car the
## hit landed on (which headlight breaks, which way it flies).
signal piece_lost(piece_id: String, zone: Zone, hit_side: String)
signal piece_damaged(piece_id: String, hp_frac: float)
signal chassis_changed(hp: float, max_hp: float)
signal restored

## piece id -> {zone, hp, max_hp}. Lost pieces stay in with hp 0.
var pieces := {}
## Zone -> piece ids, outermost first (FRONT) / front-to-back (doors).
var zone_pieces := {}
var chassis_hp := 300.0
var chassis_max := 300.0

## `four_doors` = front + rear door per side (Sedan). Call at run start.
## `armor_bonus_hp` = the "armor" upgrade's extra HP per piece (base 1.0).
func setup(max_chassis: float, armor_bonus_hp: float, four_doors: bool) -> void:
	chassis_max = max_chassis
	var piece_hp := 1.0 + armor_bonus_hp
	zone_pieces = {
		Zone.FRONT: ["front_bumper", "bonnet"],
		Zone.REAR: ["rear_bumper"],
		Zone.LEFT: ["door_lf", "door_lr"] if four_doors else ["door_l"],
		Zone.RIGHT: ["door_rf", "door_rr"] if four_doors else ["door_r"],
	}
	pieces.clear()
	for zone in zone_pieces:
		for id in zone_pieces[zone]:
			pieces[id] = {"zone": zone, "hp": piece_hp, "max_hp": piece_hp}
	restore_all()

## Every piece back to full, chassis refilled (run start).
func restore_all() -> void:
	for id in pieces:
		pieces[id].hp = pieces[id].max_hp
	chassis_hp = chassis_max
	restored.emit()
	chassis_changed.emit(chassis_hp, chassis_max)

func is_alive(id: String) -> bool:
	return pieces.has(id) and pieces[id].hp > 0.0

func chassis_frac() -> float:
	return clampf(chassis_hp / chassis_max, 0.0, 1.0) if chassis_max > 0.0 else 0.0

func engine_state() -> EngineState:
	var f := chassis_frac()
	if f < BURN_BELOW:
		return EngineState.BURNING
	if f < KNOCK_BELOW:
		return EngineState.KNOCKING
	if f < SMOKE_BELOW:
		return EngineState.SMOKING
	return EngineState.HEALTHY

## piece id -> remaining HP fraction 0..1 (0 = lost) - for the HUD silhouette.
func piece_fracs() -> Dictionary:
	var out := {}
	for id in pieces:
		out[id] = clampf(pieces[id].hp / pieces[id].max_hp, 0.0, 1.0)
	return out

## Health of a zone's armor, 0..1 (summed over its pieces) - for the HUD.
func zone_frac(zone: Zone) -> float:
	var hp := 0.0
	var total := 0.0
	for id in zone_pieces.get(zone, []):
		hp += maxf(pieces[id].hp, 0.0)
		total += pieces[id].max_hp
	return hp / total if total > 0.0 else 0.0

## One discrete hit. `along` = contact position along the car, -1 (rear) to
## +1 (front) - picks the door on 4-door cars. Returns
## {"lost": [piece ids], "chassis_damage": float}.
func apply_hit(zone: Zone, along: float, hit_side: String, frac: float) -> Dictionary:
	var out := {"lost": [], "chassis_damage": 0.0}
	if frac <= 0.0:
		return out
	if zone == Zone.LEFT or zone == Zone.RIGHT:
		var door := _door_for(zone, along)
		if is_alive(door):
			_damage_piece(door, minf(frac / SIDE_RIP_FRAC, SIDE_DAMAGE_MAX), hit_side, out)
		else:
			_damage_chassis(_chassis_hit(frac), out)
		return out

	var layers := _alive_layers(zone)
	if layers.is_empty():
		_damage_chassis(_chassis_hit(frac), out)
		return out
	if frac < TAP_FRAC:
		_damage_piece(layers[0], TAP_DENT * frac / TAP_FRAC, hit_side, out)
	elif frac < HARD_FRAC:
		var t := (frac - TAP_FRAC) / (HARD_FRAC - TAP_FRAC)
		_damage_piece(layers[0], lerpf(LIGHT_DAMAGE_MIN, LIGHT_DAMAGE_MAX, t), hit_side, out)
	else:
		# Carries through the layers; whatever's left after the last one is
		# absorbed - armor present at the moment of the hit shields the chassis.
		var dmg := minf(HARD_DAMAGE * frac / HARD_FRAC, HARD_DAMAGE_MAX)
		for id in layers:
			var hp: float = pieces[id].hp
			_damage_piece(id, dmg, hit_side, out)
			dmg -= hp
			if dmg <= 0.0:
				break
	return out

## Continuous scraping for `delta` seconds at `frac` = slide speed /
## REFERENCE_MAX_SPEED. Same return shape as apply_hit().
func apply_scrape(zone: Zone, along: float, hit_side: String, frac: float, delta: float) -> Dictionary:
	var out := {"lost": [], "chassis_damage": 0.0}
	if frac <= 0.0:
		return out
	var target := ""
	if zone == Zone.LEFT or zone == Zone.RIGHT:
		var door := _door_for(zone, along)
		if is_alive(door):
			target = door
	else:
		var layers := _alive_layers(zone)
		if not layers.is_empty():
			target = layers[0]
	if target.is_empty():
		_damage_chassis(chassis_max * EXPOSED_SCRAPE_RATE * frac * delta, out)
	else:
		_damage_piece(target, SCRAPE_RATE * frac * delta, hit_side, out)
	return out

func _door_for(zone: Zone, along: float) -> String:
	var doors: Array = zone_pieces[zone]
	return doors[0] if doors.size() == 1 or along >= 0.0 else doors[1]

func _alive_layers(zone: Zone) -> Array:
	return zone_pieces[zone].filter(func(id): return is_alive(id))

func _chassis_hit(frac: float) -> float:
	return chassis_max * CHASSIS_HARD_HIT * minf(frac / HARD_FRAC, CHASSIS_HIT_CAP / CHASSIS_HARD_HIT)

func _damage_piece(id: String, amount: float, hit_side: String, out: Dictionary) -> void:
	var p: Dictionary = pieces[id]
	p.hp -= amount
	if p.hp <= 0.0:
		p.hp = 0.0
		out.lost.append(id)
		piece_lost.emit(id, p.zone, hit_side)
	piece_damaged.emit(id, p.hp / p.max_hp)

func _damage_chassis(amount: float, out: Dictionary) -> void:
	chassis_hp -= amount
	out.chassis_damage += amount
	chassis_changed.emit(chassis_hp, chassis_max)
