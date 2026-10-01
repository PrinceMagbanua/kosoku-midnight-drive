# Kōsoku – Garage Customizer Brief

Project: `C:\My Projects\Godot Voxel Driver` (Godot 4.7)
Goal: Replace the 3 existing garage cars with 4 new customizable cars (Sedan_01, Sports_01, Hatch_01, Muscle_01) and add a Customize screen.

**Work order: Step 1 first, report back, then implement. Do not delete asset files without asking.**

---

## Step 1 – Investigate first (report before changing anything)

1. Find the Garage screen scene + scripts, and where the 3 current cars are defined (scene list, resource, dictionary, JSON, etc.).
2. Find and explain the existing logic for:
   - **Windows / glass** (material, transparency, tint, night reflection?)
   - **Wheels** (VehicleWheel3D? spinning visuals? node names expected?)
   - **Headlights and rear lights** (SpotLight3D/OmniLight3D, emissive meshes, marker nodes, brake light logic)
   - How the garage shows **stats** and how the selected car is passed to gameplay
   - Any save system for the selected car
3. List which of these the new cars must plug into, and what node names / markers the old cars used.
4. Summarize the current garage UI theme (fonts, colors, button style, Theme resource) so the new screen matches.

---

## Step 2 – Assets (already converted, DO NOT rename)

Copy `C:\My Projects\Kosoku_Cars_GLB\` into the project as `res://assets/cars/`:

```
res://assets/cars/
  cars/<Car>/<Car>_Base.glb
  cars/<Car>/parts/<Car>_<Slot>_<NN>.glb
  shared/wheels/Wheel_01..30.glb
  shared/tyres/Tyre_01..07.glb
  cars_glb_manifest.json
  textures/   <- copy from pack: Textures\PolygonStreetRacer_Texture_0[1-4]_[ABC].png
                 and Textures\Vehicles\PolygonStreetRacer_Veh_Tex_*.png
```

### `cars_glb_manifest.json` (source of truth – code must read this, not hardcode)
```json
{
  "cars": {
    "Sports_01": {
      "base": "cars/Sports_01/Sports_01_Base.glb",
      "base_contains": ["Boot_01","Spoiler_01","Door_L","Door_L_Glass", "...","Wheel_fl","Wheel_fr","Wheel_rl","Wheel_rr"],
      "slots": {
        "Bonnet": { "required": true, "stock_in_base": [], "variants": { "01": "cars/Sports_01/parts/Sports_01_Bonnet_01.glb", "...": "..." } },
        "Spoiler": { "required": false, "stock_in_base": ["Spoiler_01"], "variants": { "02": "...", "03": "...", "04": "..." } }
      },
      "presets": { "Preset_01": ["Bonnet_01","Front_Bumper_01","Rear_Bumper_01","Side_Skirts_01", "..."] }
    }
  },
  "wheels": ["shared/wheels/Wheel_01.glb", "..."],
  "tyres":  ["shared/tyres/Tyre_01.glb", "..."],
  "paint": { "palette_atlases": ["PolygonStreetRacer_Texture_01_A.png", "..."], "vinyls": ["PolygonStreetRacer_Veh_Tex_01_Race_Purple.png", "..."] }
}
```
Paths in the manifest are relative to `res://assets/cars/`.

### Node naming inside the GLBs (match these in code)
- Base car root mesh: `SM_Veh_<Car>` e.g. `SM_Veh_Sports_01`
- Base car children: `SM_Veh_<Car>_Wheel_fl|fr|rl|rr`, `_Door_L|R` (Sedan: `_Door_LF|LR|RF|RR`), `_Boot`, `_Engine_01`, `_SteeringW`, `_Seats_*`, `_Undercarriage_01`
- Any node whose name contains `Glass` = window
- Part GLBs: `SM_Veh_<Car>_<Slot>_<NN>` plus sub-pieces, e.g. `..._Rear_Bumper_02_Exhaust`, `..._Fenders_02_Door_L`, `SM_Veh_Muscle_01_Roof_01_Glass`
- Shared: `SM_Veh_Attach_Wheel_NN`, `SM_Veh_Attach_Tyre_NN` (Wheel_30 has extra `_Thruster_1/2` nodes)
- Scale is real-world meters (cars are 4.3–5.7 m long). All parts align to the base car at origin – just add them as children at identity transform.

### Materials
Every mesh surface uses only 2 materials, named **`Car`** and **`Glass`** (no textures embedded).
- Create ONE `StandardMaterial3D` "car_paint" per car instance; apply it to every `Car` surface of base + parts + wheels. Albedo = selected paint texture. Swapping paint = swapping this albedo texture only.
- Apply the existing game's window material (from Step 1) to every `Glass` surface. If none exists, use a dark transparent material.
- Palette atlases (12) and vinyl textures (26) share the same UV layout, so any texture works on any car.
- Skip `Veh_Tex_Pearl_*` and `Stripes_*` for now (Pearl needed a Unity-only shader).

---

## Step 3 – Customization rules

- **Required slots** (`required: true` – Bonnet, Front_Bumper, Rear_Bumper, Muscle Roof): always one variant equipped, no "None" option. Without them the car has holes.
- **Optional slots**: offer "None" + variants.
- `stock_in_base` parts stay visible on the base car (e.g. Sports `Spoiler_01`, all `Undercarriage_01`). Optional variants are added on top.
- **Sedan Fenders_02 / Fenders_04** include `Door_L/Door_R` pieces. When equipped, hide the stock Sedan door(s) they cover (verify visually which: likely `Door_LR/RR`, and their glass).
- **Default loadout** for a car with no saved config = its `Preset_01` parts.
- **Wheels**: stock wheels are `Wheel_fl|fr|rl|rr` in the base GLB. Custom wheel = hide the 4 stock wheel nodes, instance `Wheel_NN` + `Tyre_NN` at each stock wheel node's transform. Right-side wheels need a 180° Y flip. Check against Step 1 wheel logic so gameplay spinning still works. Option "Stock" restores original.
- Keep the old headlight/rearlight/window/wheel behavior working on the new cars (use Step 1 findings; add Marker3D nodes per car if lights need positions).
- Save loadout per car (slot → variant, wheel, tyre, paint) using the existing save system, or `user://garage.cfg` if none.
- Build the car at runtime from the manifest (base + parts). Use `ResourceLoader` / preload to avoid hitches when switching parts.

---

## Step 4 – UI

### Garage screen
- Replace the 3 old cars with the 4 new ones (Sedan_01, Sports_01, Hatch_01, Muscle_01). Keep the old cars' files, just remove them from the garage.
- Add a **"Customize"** button directly **above the car stats panel**, same style as existing garage buttons.

### Customize screen
Follow the current theme (Step 1 summary) with its own twist. Suggested layout:
- Tabs: **Body | Wheels | Paint**
- **Body**: left list of slots for the current car (from manifest); right side shows variants as a horizontal selector (◀ ▶ or cards). Required slots have no "None".
- **Camera focus twist**: selecting a slot smoothly moves the orbit camera to that area (Bonnet/Front_Bumper → front, Rear_Bumper/Spoiler → rear, Side_Skirts/Fenders → side, Roof/Roof_Scoop → top).
- **Wheels**: rim picker (30) + tyre picker (7) + "Stock".
- **Paint**: swatch grid – "Solid" (12 palette atlases) and "Livery" (26 vinyls); show texture thumbnails.
- Drag to orbit, scroll to zoom. Buttons: **Randomize**, **Reset to Preset**, **Back** (auto-saves).

---

## Notes
- Car sizes (W × L × H m): Sedan 2.30 × 5.38 × 1.64, Sports 2.08 × 4.85 × 1.43, Hatch 2.28 × 4.36 × 1.68, Muscle 2.19 × 5.68 × 1.43.
- Wheel_30 (thrusters) could be a special unlock later.
