# Porting Voxel Driver (three.js) to Godot 4

> **This is the project's own running plan/changelog, kept in-repo so it
> survives session clears.** It documents the merge of two source projects
> into this one (`C:\My Projects\Godot Voxel Driver`):
> - `C:\My Projects\Voxel Driver` — the original three.js game. Source of
>   truth for world/road generation, traffic AI, scoring/collision,
>   biomes/particles, audio design, and the cockpit yaw-lag camera - ported
>   algorithm-by-algorithm into GDScript throughout this doc, not copy-pasted
>   (JS and GDScript share no code).
> - `C:\My Projects\g-rcp2\g4-rcp2` (VitaVehicle) — the donor Godot 4 project
>   for the vehicle controller (`car.gd`/`wheel.gd`). Kept as-is; never
>   touched by anything in this doc (see "Merge priority" below).
>
> Update this file (not just chat) whenever a session lands real work or
> hits an open question worth carrying forward - the bottom of the file
> should always have an accurate "next session" starting point.

## Context
User asked how hard it would be to move Voxel Driver — a no-build, single-scene
three.js highway-weaving game — over to Godot, using the separate `g-rcp2`
(g4-rcp2 / VitaVehicle) Godot 4 project as a reference/source for vehicle physics.
Confirmed direction: port **Voxel Driver → Godot**, not the reverse. This is a
feasibility assessment, not an approved implementation task — no code should be
written until the user decides to proceed.

Findings below come from two read-only surveys: one of `g-rcp2/g4-rcp2` (Godot
raycast car physics project), one of `Voxel Driver`'s `js/` systems.

## What exists today

**Voxel Driver** (`C:\My Projects\Voxel Driver`) — vanilla three.js r128, zero
build step, runs from `file://`. ~9,843 lines of logic across `js/*.js`:
- `core.js` (4126 lines) — world/road generation (5 hand-authored "chapter"
  types stitched straight, no turns), buildings, guardrails, bridges, sky/fog/
  weather, camera setup, and a hand-rolled `EffectComposer` post chain
  (UnrealBloomPass + 3 custom inline GLSL passes: grain/vignette, radial speed
  blur, procedural windshield rain).
- `main.js` (1409 lines) — the physics/scoring tick: gear-boundary speed model
  (not RPM/torque), steering, drift/skid pools, near-miss/swerve scoring,
  camera update, render+minimap, rAF loop.
- `traffic.js` (241 lines) — pooled traffic cars, lane-gap spawn logic, seeded
  PRNG, lane changes (AGENTS.md flags two past regressions here — fragile).
- `hud-crash.js` (630 lines) — collision handling, crash/pileup escalation,
  minimap, HUD popups, restart.
- `audio.js` (557 lines) — Web Audio graph: 3-layer engine crossfade + pitch
  bend, one-shots, horn, skid loop.
- `input.js` (746 lines) — keyboard, horn/"make way" effect, volume, debug panel.
- `voxel-assets.js`/`voxel-assets-data.js` — OBJ+base64 textures embedded in
  JS (parsed once via `OBJLoader`), plus a base64 GLB cockpit interior.
- Cockpit camera has a **deliberate yaw-lag** behavior (documented project
  memory) — position/roll/pitch stay locked to the chassis, yaw lags and
  re-syncs with explicit ±π wraparound handling. Easy to accidentally break
  when re-implementing the camera in a new engine.

Assets are embedded as base64/OBJ text *only* because the game must run from
`file://` with no server (three.js loaders and `fetch` both break under
`file://`). The real source files (`assets/buildings`, `assets/cars`,
`assets/interior.glb`, `assets/sfx`, `assets/music`) exist on disk separately.
Godot has no such restriction, so these raw assets can be imported directly as
normal `.glb`/`.wav`/`.obj` resources — the embedding is a non-issue for
migration, just re-source from `assets/`, not from the generated `.js` files.

**g-rcp2 / VitaVehicle** (`C:\My Projects\g-rcp2\g4-rcp2`) — Godot 4.0 project,
raycast vehicle sim. Core controller is `MAIN/car.gd` (1132 lines,
`RigidBody3D`, transmission/drivetrain/aero/ABS/ESP) + `MAIN/wheel.gd` (616
lines, `RayCast3D`-based suspension/tyre slip/grip/heat model) — genuinely
self-contained modulo an autoload (`VitaVehicleSimulation`), an Input Map
convention, and NodePath wiring to optional camera/sound/tachometer nodes. No
traffic/AI exists in that project at all — it's a solo proving-ground sim.

## Assessment (the actual answer)

This is a **full rewrite, not a port** — three.js/JS and Godot/GDScript share
no code, and Voxel Driver's architecture (global-scope classic `<script>`
files, immediate-mode rAF loop, manual mesh building) doesn't map onto Godot's
node/scene/signal model. Nothing transfers mechanically except art assets and
algorithms-as-reference.

Rough effort by system, reusing g-rcp2 where it helps:
- **Vehicle physics** — *easiest part, ironically.* g-rcp2's `car.gd`+`wheel.gd`
  can likely be dropped in close to as-is as the vehicle controller, replacing
  Voxel Driver's simpler gear-boundary model. Moderate rewiring (Input Map,
  autoload, NodePath refs), not a rewrite.
- **World/road generation** — full rewrite in GDScript. The chapter-stitching
  logic is engine-agnostic algorithmically (just math generating a mesh), so
  the *logic* translates directly even though the code doesn't; road ribbon +
  guardrail InstancedMesh have direct Godot equivalents (`MeshInstance3D` +
  `MultiMeshInstance3D`).
- **Voxel building/car/tree assets** — reimport, not reconvert. Use the raw
  files in `assets/`, not the embedded `.js` data.
- **Post-processing (bloom, grain/vignette, speed blur, rain overlay)** —
  rewrite as Godot `.gdshader` compositor effects. Logic is simple/self-
  contained per the survey; this is real but bounded work.
- **Traffic AI, collision/crash/scoring/HUD, audio graph, input** — full
  rewrites in GDScript, translating the same algorithms (lane-gap spawn logic,
  near-miss scoring, 3-layer engine crossfade, horn/nudge) into Godot's
  node/signal idioms. `traffic.js`'s two documented past regressions mean this
  logic is more delicate than its line count suggests — port carefully, don't
  just transliterate quickly.
- **Cockpit yaw-lag camera** — small in code size but easy to get subtly wrong;
  needs deliberate attention, not just a mechanical translation.

**Bottom line:** medium-to-large effort — call it a multi-week rewrite for one
person, not a weekend port, but not a from-scratch design exercise either,
since every system already has a working reference implementation to translate
algorithm-by-algorithm, and the hardest subsystem (vehicle physics) is
largely reusable from g-rcp2 rather than needing to be invented. The realistic
path is incremental: get g-rcp2's car controller running solo in a new Godot
project first (small, well-scoped, reuses the most code), then layer in road
generation, then traffic, then audio/HUD/post-processing last.

## Merge priority (per user direction)
This is not a straight "port Voxel Driver into Godot" — it's a merge of two
existing projects, with an explicit winner per system:

**Godot (g-rcp2) wins — keep as-is, this is the whole point of using it:**
- Entire vehicle controller: `car.gd` + `wheel.gd` — engine, transmission,
  drivetrain, aero, ABS/ESP, raycast suspension/tyre slip.
- All movement feel: acceleration, drifting, yaw/roll behavior.
- Braking model specifically — g-rcp2 has both handbrake *and* normal brake
  as distinct systems (per survey: `car.gd` handles both); Voxel Driver's
  `main.js` gear-boundary model and its drift/skid *physics* (not the visual
  smoke) are superseded entirely.
- Input mapping and sound tied to the controller (engine crossfade/pitch,
  tyre sounds) — g-rcp2 already has its own engine/mechanical/tyre sound
  scripts; Voxel Driver's `audio.js` engine-sound logic is not needed, though
  Voxel Driver's WAV assets could still be swapped in as g-rcp2's sample
  source if preferred later.

**Voxel Driver wins — reimplement in GDScript, this is what Godot lacks:**
- Point/scoring system: near-miss/swerve chaining logic (`main.js`,
  `hud-crash.js`).
- Road/map generation: chapter-stitching, buildings, guardrails, bridges
  (`core.js`) — g-rcp2 only has 3 small fixed test tracks, no procedural road.
- Traffic AI: pooled spawn/lane-gap/lane-change logic (`traffic.js`) — g-rcp2
  has none at all.
- Collision/crash/pileup escalation, minimap, HUD (`hud-crash.js`).

**Voxel Driver contributes as bolt-on visual/effect layers only (not physics):**
- Nitro effect (visual/feel boost, not touching g-rcp2's drivetrain math
  unless/until a boost mechanic is explicitly designed against it later).
- Smoke particle effects (visual only — the underlying skid/slip values now
  come from g-rcp2's `wheel.gd`, not `main.js`).
- Cockpit interior view — the modeled interior GLB + the deliberate yaw-lag
  camera behavior (position/roll/pitch locked to chassis, yaw lags and
  re-syncs with ±π wraparound). This needs to read yaw/roll off g-rcp2's
  `RigidBody3D` car instead of Voxel Driver's gear-boundary state — same
  camera *logic*, new data source.
- Lighting (headlights/taillights/effects lighting).

**Explicitly deferred, not part of this pass:** reconciling which project's
variables/tunables win once upgrade systems exist (e.g. an upgrade that
should affect both a g-rcp2 drivetrain stat and a Voxel Driver-derived score
multiplier). Flagged for a follow-up planning pass once upgrades are designed,
not solved now.

## Recommended build order
1. Start from a copy of the g-rcp2 Godot project (not Voxel Driver) as the
   base — the controller is the hard-won asset, everything else is rewritten
   around it.
2. Get the car driveable solo first (already ~there in g-rcp2) — verify feel
   (drift, yaw/roll, handbrake vs. brake) is preserved before adding anything.
3. Layer in cockpit interior + yaw-lag camera, plus the full menu/UI
   surface (start, garage, HUD, pause, crash) — detailed as its own section
   below since this turned out to be substantial. Do this as ordered
   sub-steps (3a-3f below), each independently playable/verifiable.
4. **MVP DONE, chapters/curves deferred.** Port road/map generation
   (GDScript rewrite of `core.js` chapter logic) so there's a road to drive
   on. Research pass found the real scope: 8 chapter types (plain/exit/
   bridge/double-exit/bridge-and-exit/toll/tunnel/sweeper - not the 5 the
   original docs said), with curves+banking+grade on sweeper/tunnel chapters,
   exit gantries, bridges, toll widening, buildings keyed off road-edge
   distance, all baked into one resident 60000-unit mesh windowed via
   `setDrawRange` - that residency approach doesn't fit Godot, so this port
   uses a chunked generate-ahead/free-behind system instead (the idiomatic
   Godot equivalent of the same goal). **Shipped as MVP**:
   `MAIN/road/road_generator.gd` - straight, flat 4-lane highway only (no
   chapters/curves/exits/bridges/tolls/tunnels/buildings/biome tinting yet,
   all explicitly deferred to a follow-up pass), chunked at 112 units,
   generates 600 units ahead / frees 150 units behind the car, with lane
   dashes and low guardrail fencing via `MultiMeshInstance3D`, and real
   collision (`StaticBody3D` + `MAIN/ground_surface_variables.gd`, same
   script the old fixed test track used) so wheel raycasts get real ground.
   Replaced the old "test scene" fixed test-track instance in `world.tscn`.
   **Third bug fixed - no physical guardrails**: the fence built earlier was
   `MultiMeshInstance3D` only (visual, zero collision), so the car could
   drive off the shoulder into empty space and fall through the world.
   Added real `CollisionShape3D` walls per chunk - first attempt placed them
   at `FENCE_HALF_WIDTH` (matching the decorative fence posts) which sits
   just outside the ground plane's actual edge (`SHOULDER_HALF_WIDTH`),
   leaving a ~1-unit gap to fall through; fixed by placing the wall flush
   with the ground edge instead. Verified headless: continuously shoving the
   car sideways for 5s, it stops solidly at a stable position and never
   falls (`car_y` stays constant).
   Also bumped acceleration slightly per request - `car.gd`'s `OffsetTorque`
   (110 -> 128) via an override on the `car` instance in `base car.tscn`,
   not by editing `car.gd` itself. Picked over `TurboAmount` because that
   only applies when `TurboEnabled` is true, which would add turbo-lag
   behavior, not just more accel.
   Along the way, also wired real distance tracking: `RunRewards` (autoload)
   now tracks live run distance off the car's Z position and
   `bank_run_rewards()` genuinely updates `SaveData.game.garage.furthest_dist`
   (verified via headless test) - the start screen's "BEST: -" readout will
   now show real numbers once a run ends.
   **Bug fixed along the way**: the car's spawn transform in `world.tscn` had
   to move from `y=0` to `y=2` - at `y=0` the wheel raycast suspension spawned
   already compressed into the new flat road, launching the car violently on
   the first physics tick. Raising the spawn height lets it settle under
   gravity instead.
   **Second bug fixed - unit scale mismatch**: ported the road-width constants
   directly from Voxel Driver's three.js source (~1 unit = 1 metre) without
   accounting for g-rcp2's own documented world scale (README: "1 metre =
   3.268828" engine units) - result: the car's own wheel track (4.4 units)
   was *wider* than the un-scaled lane width (4.035 units), so it visibly
   straddled two lanes. Fixed by multiplying every length constant by a
   `UNIT_SCALE = 3.268828` conversion factor. `road_generator.gd` is now also
   `@tool`-annotated: opening `world.tscn` in the editor builds a small
   static preview (a few chunks around the origin, never saved into the
   scene) so a scale mistake like this is visible without pressing Play next
   time.
5. **MVP DONE.** Port traffic AI (GDScript rewrite of `traffic.js`) — treat
   carefully, this file has two documented past regressions in the original.
   Research pass pulled the exact algorithm + regression history from
   AGENTS.md before writing anything. Shipped: `MAIN/road/road_metrics.gd`
   (new shared `RoadMetrics` class, factored out of `road_generator.gd` - lane
   math now lives in exactly one place, used by both `road_generator.gd` and
   the new traffic system, specifically because the original has its own
   documented regression from that formula getting duplicated with a
   mismatched scale), `MAIN/traffic/traffic_manager.gd` (centralized
   per-frame AI loop, same architecture as `main.js`'s traffic update - a
   fixed pool of 35 cars, staggered gap-lane band system, lane-change AI
   with signal/interpolated lane-change/yaw wobble, following/soft-collision
   speed matching, spawn/recycle with both regression fixes preserved and
   labeled at the exact lines that matter), `MAIN/traffic/traffic_car.gd` +
   `TrafficCar.tscn` (pooled car data holder + placeholder colored-box
   visual, sized/weighted per Voxel Driver's 5 traffic "kind" categories).
   Verified via a headless torture-test: simulated ~36,000 units of
   continuous fast driving (forcing constant recycling) and confirmed no
   NaN and no runaway-distance regression B symptom - every car stayed
   within the algorithm's own guaranteed bound.
   **Deliberately NOT ported yet**: bump-spring hit reaction, pileup/wrecked
   states, dodge/near-miss scoring, difficulty-driven aggressive-NPC/blocker
   behavior, real car hull models (placeholder colored boxes only), blinker
   visual toggle - all need systems that don't exist yet (ram/collision and
   scoring are step 6; difficulty upgrades don't affect gameplay yet since
   nothing reads them).
6. **MVP DONE.** Port scoring/collision escalation logic into the crash/HUD
   systems built in step 3 (`hud-crash.js`'s collision/damage math, scoring
   bits of `main.js`). Research pass pulled exact formulas/constants before
   writing anything (HP model, crash-trigger thresholds, near-miss geometry,
   combo decay, cash conversion). Shipped:
   - `MAIN/gameplay/crash_system.gd` — real HP/damage (speed-based, matches
     `HP_HIT_SCALE=100` formula), collision + near-miss detection via the
     *same pure numeric proximity check* the original uses (no physics
     collision shapes needed on traffic cars - lateral gap vs. hit/near
     bands, longitudinal window), insurance crash-saves (consumes an
     `insurance` upgrade tier, full HP refill + invuln window), and an
     actual crash trigger (HP depleted, or one impact over 80% of a
     reference max speed) - **first time a crash can happen organically**,
     not just via the pause screen's manual "END RUN". Crash spin is a
     one-time torque impulse (real physics) rather than Voxel Driver's
     scripted rotation tween, since this car is a real RigidBody3D.
   - `RunRewards` (autoload) expanded: live `score`/`combo_multiplier`
     with decay, near-miss scoring, `bank_run_rewards()` now does the real
     `score * CASH_CONVERSION_RATE(0.035)` conversion and updates
     `SaveGame.high_score`.
   - `CrashOverlay` now banks exactly once per crash (centralized there,
     removed the now-redundant bank call from pause's "END RUN" path to
     avoid double-banking) and shows real score/best-score alongside cash.
   - New `UI/hud/LiveHud.tscn` — the score/combo/cash HUD step 3c explicitly
     deferred (no data existed yet). Speed/RPM/gear still intentionally left
     to the existing `debugger.tscn` tachometer, not duplicated.
   Verified via a headless scenario test: near-miss scored correctly with
   dedup, a modest collision damaged HP without crashing and broke the
   combo, a high-speed collision immediately triggered `CRASHING` ->
   `CRASHED` after the spin duration, tree paused, and banking produced
   real cash + a high-score update.
   **Deliberately NOT ported** (need systems that don't exist yet, or cut
   for time - not silently dropped): swerve/snake lane-change chains,
   tailgating score trickle, dodge-on-lane-change-merge scoring, sustained-
   top-speed bonus, hazard dodges (no hazards exist), biome/weather score
   multipliers (no biomes/weather exist), pileup escalation, scrape-vs-full-
   hit distinction, screen flash/shake feedback, and player input isn't
   force-disabled during the crash spin (car.gd still reads input for that
   ~1.7s window - a minor fidelity gap, not worth hacking around car.gd's
   input handling for).
7. Add nitro visual effect, smoke particles, lighting last — pure polish
   layered on a working, correctly-feeling car.

## Step 3 detail: cockpit camera/interior + full UI surface

### Survey findings this is based on
**Godot project current state** (`C:\My Projects\Godot Voxel Driver`):
- Main scene `world.tscn`: `world` (Node3D) with `cam_chase` (Marker3D+
  `MAIN/misc/camera.gd`, chase/orbit cam, NOT parented to the car — a sibling
  that looks up `car` via NodePath each frame), `car` (instance of
  `base car.tscn`), plus loose `watermark`/`author` Control nodes directly
  under the Node3D root — **no CanvasLayer exists anywhere in the project**.
- `base car.tscn` (RigidBody3D root, script `car.gd`): has no `CAMERA_CENTRE`
  marker and no interior/cockpit mesh — `camera.gd` already checks
  `has_node("CAMERA_CENTRE")` and falls back to car origin, so adding that
  marker is additive/safe.
- Autoloads: `VitaVehicleSimulation` (`MAIN/vitavehicle.gd`) is a **stateless
  math helper library** (torque curves, wheel helpers) — not a state store,
  don't hook UI into it. Real runtime stats (`rpm`, `gear`, `throttle`,
  `gforce`, `linear_velocity`, ABS/ESP/TCS flags, all tuning `@export` vars)
  live as plain public vars directly on the `car` instance (`MAIN/car.gd`).
- `MISC/debugger.tscn` + `MISC/misc scripts/debug.gd` already implement a
  **fully working runtime HUD** (pedal bars, tachometer w/ RPM+speed+gear
  labels, ABS/TCS/ESP indicators, G-force widget) reading every stat straight
  off the car instance — this is the concrete template for the new HUD's
  stat-reading code, don't rederive it.
- `MISC/tachometre/tacho.gd` (Control, needle rotation from public
  `currentrpm`/`currentpsi` vars) and `MISC/vertical progress bar/bar.gd`
  (ColorRect, scale-based fill) are genuine reusable Control-node widgets.
- No pause action, no crash-detection signal, no save-data autoload exist yet.

**Voxel Driver UI/state being translated** (`C:\My Projects\Voxel Driver`):
- START screen: title + best-biome readout + PLAY ENDLESS / GARAGE buttons.
  No difficulty picker here — difficulty is purchased inside the garage.
- GARAGE: **one 3D preview reused for two panel modes** (car select+upgrades
  vs. map/difficulty upgrades), not two separate scenes — a slow-orbiting
  camera eases between two `{radius,height}` targets per mode with a
  zoom-in "intro" on open. Car select (3 cars, each with a tuning-constants
  override), a flat `UPGRADE_ROWS` registry (id/group/cost-curve/maxTier)
  driving a generic buy/sell list split into `group:'garage'` (car stats:
  accel/braking/handling/armor/ram/insurance/nitro/top speed/lights) vs.
  `group:'difficulty'` (traffic/rain/night/curves knobs), a wheel-color
  swatch row, and transmission (A/T·M/T) + handling (classic·grip) toggles
  that persist independently.
- HUD: circular speedo+RPM gauges w/ nitro/HP accent arcs, score/combo/cash
  strip, rotating minimap, slide-in near-miss/coin/biome popups, a
  settings/lighting panel. All toggled as one group by driving-vs-not state.
- PAUSE: resume / garage (with an "end run?" confirm that banks rewards and
  can drop straight back into a fresh run) / end run.
- CRASH: recap (score/cash/biome, high-score banners), banks rewards, click
  or `R` → menu, or GARAGE button direct.
- State is **several independent flat objects**, each with its own
  localStorage key (`garageState`, `difficultySettings`,
  `transmissionSettings`, `handlingSettings`, `highScore`), not one big store.
- Cockpit yaw-lag (exact algorithm, `main.js`/`core.js`): every frame in
  cockpit view, camera position+roll+pitch are copied rigidly from the car
  body; only yaw is smoothed — exponential smoothing toward the car's real
  yaw (`cockpit_yaw_smooth += wrapf(car_yaw - cockpit_yaw_smooth, -PI, PI) *
  min(1, LAG_RATE*dt)`), then the *residual gap* is clamped to a max lag
  (`MAX_YAW_LAG = 15°`) so a fast spin never lets the view trail too far.
  The interior mesh (parented to the camera) gets the *negated* residual gap
  applied as its own local Y-rotation each frame, so its world-space yaw
  still tracks the chassis exactly even though its parent (the camera) is
  lagging — this is what keeps the dash/wheel visually glued to the car.
  Order matters: yaw lag first, then any whiplash/vibration effects
  composed on top.

### Architecture decisions for this project
- **Introduce a `CanvasLayer`-rooted UI tree** instead of following the
  existing loose-Control pattern (`watermark`/`author`) — one `UI`
  CanvasLayer in `world.tscn` containing instanced child scenes:
  `StartScreen.tscn`, `HUD.tscn`, `GarageScreen.tscn`, `PauseOverlay.tscn`,
  `CrashOverlay.tscn`. Each is a real `.tscn` with its own root Control,
  built visually in the editor (buttons, labels, panels wired via the
  Inspector/signals) — not constructed in code — matching the "use Godot's
  actual features" direction.
- **`GameState` autoload** (new, small): an enum (`MENU, GARAGE, PLAYING,
  CRASHING, CRASHED, PAUSED`) plus a `state_changed` signal. Screen scenes
  each connect to this signal and show/hide themselves — mirrors Voxel
  Driver's single-state-machine-drives-all-overlays pattern, but via Godot
  signals instead of a shared JS global.
- **`SaveData` autoload** (new): holds `garage_state`, `difficulty_settings`,
  `transmission_mode`, `handling_mode`, `high_score` as typed fields (a
  `Resource` subclass, not a bare Dictionary, so the Inspector can show/edit
  it and it's easy to extend later), with `load()`/`save()` via `ConfigFile`
  to `user://`. An `UPGRADE_ROWS`-equivalent (array of a small `UpgradeRow`
  Resource: id/group/cost curve/max tier/description) drives a generic
  buy/sell list scene, matching the existing JS registry pattern instead of
  hardcoding each row.
- **Garage 3D preview via `SubViewport`**, not scene-switching or camera
  juggling in the main world: a `SubViewport` (own small scene — light, floor,
  a preview car instance, an orbiting `Camera3D` eased between car/map view
  configs) rendered into a `TextureRect`/`SubViewportContainer` inside
  `GarageScreen.tscn`. This is the idiomatic Godot way to get an isolated
  "extra 3D scene" for a menu preview without hiding/showing the live world,
  and is a genuine use of a Godot feature the project doesn't touch yet.
- **Cockpit camera**: add a `CAMERA_CENTRE` Marker3D and an `Interior` node
  (instanced `interior.glb`, imported from Voxel Driver's `assets/`, not the
  embedded JS data) to `base car.tscn`, both parented so they move rigidly
  with the chassis. Add a `Camera3D` child (`cockpit_camera.gd`, new script)
  implementing the yaw-lag algorithm above with `wrapf()`/`clamp()`. Keep
  `camera.gd`'s chase logic untouched; a small `CameraRig` script (or a mode
  var read by both) toggles which `Camera3D.current` is active on a new
  `toggle_cockpit_cam` input action, added to the Input Map alongside the
  existing `gas`/`brake`/`handbrake`/etc. actions.
- **Crash detection**: no collision/damage signal exists on `car.gd` yet —
  add impulse-threshold detection (reference: Voxel Driver's
  `registerCollision()`/HP-depletion model in `hud-crash.js`) that emits a
  `crashed` signal consumed by `GameState` to drive the crash overlay.

### Build order for step 3 (sub-steps)
- **3a.** `GameState` + `SaveData` autoloads, empty-but-wired (no UI yet) —
  get persistence and the state machine right before building screens on it.
- **3b.** Cockpit camera + interior (`CAMERA_CENTRE`, `Interior` node,
  `cockpit_camera.gd`, toggle input action) — verify yaw-lag feel matches the
  three.js original before moving on, this is the trickiest math to get
  subtly right.
- **3c.** ~~Build a HUD~~ **Not needed for speed/RPM/gear** — tried building a
  separate player-facing gauge (`UI/HUD.tscn`) reading the same stats
  `debug.gd` does, but `MISC/debugger.tscn`'s existing tachometer widget
  already looks good on-screen as-is (circular speed/RPM/gear gauge, visible
  in the default debug view) — user confirmed and had it removed rather than
  ship a redundant/visually-clashing duplicate. **For steps 4-6: reuse/adapt
  `MISC/debugger.tscn` + `tacho.gd` for the real player HUD instead of
  building one from scratch** — only score/combo/cash/minimap actually need
  new UI (no equivalent exists anywhere in the Godot project), once traffic/
  road/scoring exist to feed them real data.
- **3d.** `StartScreen.tscn` — simplest screen, good state-machine wiring
  smoke test.
- **3e. DONE.** `GarageScreen.tscn` + `SubViewport` turntable preview
  (`GaragePreview.tscn`, frozen `PreviewCar` instance, `garage_orbit_camera.gd`
  easing between car/map view configs), CAR SPECS vs. MAP UPGRADES panel
  toggle, generic buy/sell upgrade list (`UpgradeRowUI.tscn` instanced per
  `SaveData.upgrade_rows` entry), transmission toggle wired to the real
  `car.TransmissionType`. **Deliberately skipped** (no backing data/asset
  exists in this Godot project yet): car select (only one car model exists
  here so far), wheel color, and the classic/grip "handling mode" toggle
  (that was Voxel Driver's own two hand-written steering models - g-rcp2's
  raycast physics has no equivalent for it to switch between).
- **3f. DONE.** `PauseOverlay.tscn` + `CrashOverlay.tscn` + new `RunRewards`
  autoload stub (`bank_run_rewards()` - a no-op until step 6 has real
  score/distance data to bank). Pause/crash freeze gameplay via Godot's own
  `SceneTree.paused` (screens set `process_mode = ALWAYS` so their own
  buttons keep responding) rather than a manual per-frame skip flag.
  `GameState.resume_to_playing_after_garage` verified both ways: crash
  screen's GARAGE button leaves it false (garage BACK -> MENU); pause's
  GARAGE -> confirm -> YES sets it true (garage BACK -> fresh PLAYING run).
  **No automatic crash-trigger from actual collisions yet** - only the
  pause screen's "END RUN" button reaches CRASHED right now; wiring a real
  crash-detection signal off collisions is scoped into step 6 alongside the
  rest of the scoring/collision-escalation logic, not solved here.

## Post-step-6 addition: world dressing + real car models
User flagged this wasn't covered yet - the road/traffic MVPs (steps 4-5)
were functional but visually bare (flat road, no buildings/ground/lights,
placeholder box traffic, g-rcp2's stock player car mesh). This is real
"maps/road" scope per the merge priority (Voxel Driver's world content),
not something to keep deferring indefinitely. Real assets exist for all of
it - copied a curated subset into the Godot project rather than porting the
embedded-in-JS versions:
- `res://assets/buildings/` - 15 of the 47 available building GLBs (variety
  sample, not the full pack, for build-time/scope reasons).
- `res://assets/cars/` - all 8 structured car GLBs (armored/coupe/italia/
  kamaro/passenger/police/taxi/truck) - the exact same pack Voxel Driver's
  `CAR_OPTIONS`/traffic "kind" system used.
- `road_generator.gd` extended: grass+sidewalk ground bands (flat colored
  ribbons, matching core.js's buildRoadside() band structure), building
  placement (fixed-offset + jitter per chunk side rather than the original's
  exact footprint-aware overlap avoidance - not worth the complexity),
  seeded per-chunk-index (not streaming) RNG so a chunk's building layout is
  stable regardless of drive direction, and procedural streetlight props (no
  source model exists for this - simple pole+emissive-head geometry, no
  actual `Light3D`/illumination yet, that's step 7's lighting pass).
- `traffic_car.gd` swapped from placeholder colored boxes to real hulls,
  mapped onto the same 5 "kind" categories (wide->truck, normal->taxi,
  passenger->passenger, armored->armored, police->police) - `half_len`/
  `half_w` for gap/collision math now come from each model's own AABB.
  **Bug caught and fixed during this**: my first AABB-measuring function
  didn't properly compose transforms down the node hierarchy (a flat walk
  that silently drops any transform on an intermediate group node) and
  produced sizes ~30-50x too large; fixed by reusing the same recursive
  transform-composition approach a diagnostic script had already verified
  correct against these exact models. Verified headless after the fix:
  half-lengths back in the expected ~8-10 unit range.
- `base car.tscn`'s player mesh swapped from the stock `carmesh` to
  `coupe.glb` (kept the old mesh node, hidden not deleted, fully
  reversible). Calibrated scale/position from the ACTUAL collision-shape
  convex-hull points (not a guess) - chassis length/width measured at
  ~11.65/~5.51 units, coupe.glb's own real-meter AABB at 5.14m/2.35m, giving
  a consistent ~2.3 scale factor from two independent measurements. Purely
  cosmetic - doesn't touch wheels/collision/physics at all.
Verified headless throughout: player car resting height/position unaffected
by the mesh swap, buildings/streetlights populate per chunk, traffic
half-len/half-w sane after the AABB fix, no parse or runtime errors.

## Post-world-dressing corrections (user feedback)
- **Buildings were wrong.** Voxel Driver's own project root has
  `building-overrides.json` (+ the identical data baked into `voxel-assets.js`
  as `BUILDING_OVERRIDES_DATA`) - a hand-tuned list of which of the 47
  buildings are actually usable (`excluded`) and target *footprint* sizes for
  a handful (`overrides`, not heights - `scale = targetFootprint /
  max(nativeWidth, nativeDepth)`, matching `buildVoxelBuilding()` exactly).
  My first pass had picked 15 buildings mostly overlapping the *excluded*
  list. Fixed: removed those, copied the correct 11 eligible ones, and
  reimplemented placement with real per-building footprint scaling
  (`BUILDING_FOOTPRINT_OVERRIDES` dict + `BUILDING_TARGET_FOOTPRINT_MIN/MAX
  [6,14]` random fallback, native footprint measured from each model's own
  AABB and cached).
- **Night lighting added.** New `MAIN/misc/NightEnvironment.tscn` (dark
  `ProceduralSkyMaterial`, dim cool-toned ambient + a low-energy "moonlight"
  `DirectionalLight3D`) replaces `Morning_env` in `world.tscn` (old one kept
  in the file, just not instanced - reversible). Streetlights
  (`road_generator.gd`) also gained a real `OmniLight3D` each, not just the
  emissive-look prop from the first pass - they actually illuminate now.
- **Cockpit mode now hides the exterior body mesh** - `cockpit_camera.gd`
  gained an `exterior_mesh_path` export, toggled opposite the interior in
  `activate()`/`deactivate()` (you shouldn't see your own car's outside from
  inside the cabin).
- **Player car facing**: explicitly did NOT guess-rotate `VoxelCarMesh`
  further per user request - it's a plain node directly under `car` in
  `base car.tscn` (Scene panel: car > VoxelCarMesh), fully selectable/
  editable with the standard move/rotate/scale gizmos, for manual
  adjustment rather than more blind guessing.
Verified headless: building scale factors vary correctly per the footprint
formula, cockpit visibility toggle (interior/exterior mutually exclusive)
confirmed both directions, night environment loads without error.

## Unified wheel visuals (user feedback)
User noticed two overlapping wheel sets - g-rcp2's own generic wheel cylinder
mesh (car.gd/wheel.tscn's rendering) plus coupe.glb's own baked-in wheel
meshes (came along for free when VoxelCarMesh was added, `wheel_FL/FR/BL/BR`
sub-meshes nested under the body mesh). Confirmed for the user: swapping
which mesh renders on a wheel node has zero effect on physics -
`wheel.gd`'s suspension is driven entirely by its `RayCast3D`, independent
of whatever's parented under it for rendering.
Fix: `MAIN/misc/wheel_hull_mesh.gd` (new) - at `_ready()`, pulls just the
one matching wheel mesh out of a fresh coupe.glb instance and reparents it
under `wheel.tscn`'s existing `animation/camber/wheel` node (so it
automatically inherits all of `wheel.gd`'s steering/camber/spin animation
for free, no new logic needed), then discards the rest of the temp hull.
Hid `car.gd`'s own `Cylinder2` wheel mesh at each corner (`visible=false`,
not deleted) rather than removing it. Mapped by the hull's own naming
(fr->wheel_FR, fl->wheel_FL, rr->wheel_BR, rl->wheel_BL) - exposed as a
plain node (`HullWheel`) per corner for manual nudging if a corner's
scale/position needs adjustment, same "expose it, don't blind-guess it
perfectly" pattern used throughout this car's visual calibration.
Verified headless: all 4 corners correctly extract their named mesh, old
generic wheel confirmed hidden, no owner-consistency warnings after fixing
a `wheel_mesh.owner = null` reparenting detail, car resting height/stability
unaffected.
Also verified (in response to the whole `car` node's transform being
manually rotated 180° in `world.tscn`): pressing gas still moves the car in
+Z, so the existing road/traffic/distance-banking direction convention is
intact.

## Generalized wheel-hull reuse to traffic + real traffic wheel spin
User asked whether the same "use the hull's own embedded wheel meshes"
approach could generalize to every car (including traffic, which had zero
wheel animation at all - a static baked pose) and actually spin.
- `wheel_hull_mesh.gd` (player car): `hull_scene`/`hull_scale` now exported
  instead of hardcoded to coupe.glb, future-proofing for car-select.
  Renamed matching to suffix-based (`wheel_corner_suffix`, e.g. "wheel_FL")
  instead of exact name - **found mid-implementation that every OTHER car in
  the asset pack prefixes its wheel mesh names per model** (coupe.glb: bare
  "wheel_FL"; taxi.glb: "car_taxi_wheel_FL"; truck.glb: "truck_wheel_FL";
  armored.glb: "armored_truck_wheel_FL"; etc.) - an exact-name match only
  ever worked for coupe and would've silently found nothing on any other
  hull. Updated `base car.tscn`'s 4 corner nodes to the renamed property.
- `traffic_car.gd`/`traffic_manager.gd`: each traffic car now extracts its
  own hull's 4 wheel meshes (same suffix matching) and keeps them as live
  references (no reparenting needed here - traffic has no suspension pivot
  system to move them onto, they just stay at their authored position and
  get `rotate_x()`'d each frame in the new `spin_wheels()`, called from
  `traffic_manager.gd`'s per-car update using each car's actual
  speed-after-following, so a braking/tailgating car's wheels visibly slow
  too, not just a flat spin rate).
  **Bug caught and fixed**: first pass measured wheel radius via a
  transform composition that started fresh at the wheel mesh node instead
  of chaining all the way from the hull root - dropped an intermediate
  group node's ~100x corrective scale (same bug class, different cause,
  as the earlier building-AABB fix) and produced a ~115-unit "radius".
  Fixed with a new `_full_chain_aabb()` helper that walks UP from the wheel
  node to the hull root composing every ancestor's transform, not just the
  wheel node's own. Verified headless after the fix: radius back to ~1.16
  units (~0.70m, a plausible real wheel size), all 5 traffic kinds find all
  4 wheels, and `rotation.x` visibly changes frame-to-frame under motion.

## Shadows/headlights/debug-HUD overhaul + StructuredCarParts convention
User feedback batch: harsh shadows, missing headlight lighting, and a big
debug-HUD restructure (g-rcp2's own pre-existing tuning panel).
- **Shadows**: softened `NightEnvironment.tscn`'s moonlight
  (`shadow_opacity=0.6`, `shadow_blur=2.5`, `light_angular_distance=3.5`,
  slightly lower `light_energy`, raised ambient a touch to fill shadows).
  Streetlight `OmniLight3D`s already defaulted to no shadow-casting -
  confirmed, not the harshness source.
- **Headlights**: `MAIN/misc/headlight_lights.gd` finds the real
  `headlight_L`/`headlight_R` meshes in the assigned hull and attaches a
  `SpotLight3D` to each (colored to the pack's own documented headlight
  material). No true IES profile (Godot has no built-in IES import) - a
  tuned plain spotlight instead, noted as a limitation. Player car only -
  NOT added to traffic (35 cars x 2 lights = 70 live lights would be
  expensive on this project's `gl_compatibility` renderer specifically,
  which has much stricter dynamic light limits than Forward+).
- **`MAIN/misc/structured_car_parts.gd`** (new shared utility): the actual
  documented naming convention for this asset pack, pulled from Voxel
  Driver's `js/voxel-assets.js` (`applyStructuredHull()`) at the user's
  request rather than re-derived by guessing - case-insensitive SUBSTRING
  match (not suffix), `rl`/`rr` accepted as synonyms for `bl`/`br` on some
  models (italia.glb), documented headlight/rearlight colors, and a noted
  known asset bug (kamaro.glb's non-glass parts can export
  alphaMode:BLEND by mistake, causing a transparent-cutout look - not hit
  yet since kamaro isn't used anywhere in this port). `traffic_car.gd` and
  `wheel_hull_mesh.gd` both refactored onto this shared utility instead of
  each having their own narrower suffix-only matcher.
- **Debug HUD restructure** (`MISC/debugger.tscn`, g-rcp2's own tuning
  panel): the 5 always-visible top buttons (information/graphics config/
  change scene/swap car/control config) hidden, replaced by a gear-icon
  button (`MenuGear`) opening a dropdown (`MenuList`,
  `debug_main_menu.gd`) with the same 5 items, wired to the exact same
  target dialog methods the old buttons used - no changes needed to
  controls-manipulator/inform/graphics-config/car-swapper/scene-swapper's
  own logic. Added a `CloseButton` (`close_panel_button.gd`, one generic
  script reused across all 5 panels) to each dialog.
- **New opt-in display toggles**: 3 checkboxes added to Graphics Config
  (`show_power_graph`, `show_traction_viz`, `show_gs` - new vars on
  `misc_graphics_settings`/`graphics.gd`, default off), gating visibility of
  the torque/power graph + Torque/Power text, the traction/CoG visualizer
  (`vgs`), and the "Gs:" readout respectively - all now start hidden and
  require ticking on, via `debug.gd`'s `_process`.
- **Logo/watermark removed permanently** (not gated by a toggle, per
  request) - `world.tscn`'s `watermark`/`author` nodes deleted outright.
Verified headless: gear opens the dropdown, an item both opens its dialog
(confirmed via the panel's own pre-existing open animation/delay) and
auto-closes the dropdown, the close button works, the old top buttons stay
hidden, a display checkbox correctly propagates through the settings
autoload to the gated HUD elements, and traffic/player wheel-finding still
works after the StructuredCarParts refactor.

## Wheel bugs round 2: off-center pivots + still-visible body wheels
User reported passenger.glb's wheels looked wrong ("wrong axis or not the
actual wheel") and that coupe.glb still showed two sets of wheels despite
the earlier fix. Diagnosed both (read-only investigation, reported findings,
got explicit confirmation before touching code) before writing anything:
- **passenger.glb wheels**: NOT a wrong rotation axis - traced the full
  transform chain and the axle direction (local X) survives correctly
  through an intermediate Blender group node's baked-in 90°-about-X
  rotation (rotations about the same axis compose cleanly). The real bug:
  passenger/taxi/truck/armored/police's wheel MESH GEOMETRY isn't centered
  on its own node origin (measured center ~(80,138,-32) instead of ~(0,0,0)
  the way coupe.glb's is) - rotating the raw node swung the mesh through a
  wide arc around that off-center origin instead of spinning in place.
  User explicitly asked which fix is more scalable (re-export in Blender vs.
  a generic runtime fix) and confirmed the runtime approach - agreed it's
  the right call since it's computed from each mesh's own measured AABB at
  load time, self-correcting for any hull automatically (coupe: no-op,
  since it's already centered) rather than a per-model hardcoded patch.
  `traffic_car.gd` gained `_make_centered_pivot()`: reparents each wheel
  mesh under a new pivot placed exactly at its measured geometric center
  (net visual position unchanged), and spins the pivot instead of the raw
  mesh node. `wheel_hull_mesh.gd` (player) got the equivalent correction
  for the same reason (future-proofing for italia/kamaro, even though
  coupe itself needed no correction).
- **coupe.glb still showing two wheel sets**: confirmed real bug -
  `wheel_hull_mesh.gd` pulls its wheel mesh from a SEPARATE temporary
  coupe.glb instance (to reparent onto the real suspension node), but the
  ACTUAL visible `VoxelCarMesh` instance has its own built-in wheel_FL/FR/
  BL/BR meshes that were never hidden - so both the real animated wheels
  and 4 static "ghost" wheels frozen in the body's modeled pose were
  rendering at once. Fixed with new `MAIN/misc/hide_embedded_wheels.gd`
  attached directly to VoxelCarMesh, hiding its own embedded wheel meshes
  at `_ready()`.
Verified headless: all 4 embedded body wheels confirmed hidden
(`visible=false`); traffic wheel pivots land at sane world positions with
Y exactly matching the measured wheel radius (center sitting precisely at
ground-contact height) - strong confirmation the pivot math is not just
non-crashing but geometrically correct, not merely "didn't error."

## Floating car body + editor-visible wheels
Car body floated well above the wheels - measured the mismatch: coupe.glb's
own wheel centers sit ~1.67 units below where the real `fr/fl/rr/rl`
suspension nodes are. User's first instinct was to move the wheel nodes to
match the model; flagged that this would change wheelbase/track/ride
height (physics-relevant suspension geometry, not just cosmetics) and risk
altering g-rcp2's tuned driving feel - recommended recalibrating
`VoxelCarMesh`'s own transform instead (zero physics risk, same visual
fix). User agreed and asked to see the wheels rendered live in the editor
(base car.tscn's static 3D view) to calibrate against, since
`wheel_hull_mesh.gd` previously only ran its mesh-extraction at Play time.
Made `wheel_hull_mesh.gd` `@tool` (same pattern as `road_generator.gd`) so
it now runs identically in the editor - opening `base car.tscn` shows the
real wheel meshes in place without pressing Play. Added an idempotency
guard (clears previous children first) since a `@tool` script's `_ready()`
can re-run on editor rescans/saves. Verified headless (instancing
`base car.tscn` standalone, matching exactly what opening it directly
does): all 4 corners extract and position correctly with no game/world
running. User is doing the actual VoxelCarMesh recalibration themselves
now that it's visible - no transform values were applied by me here.

## Ride-height recalibration against real settled physics, not the static editor view
Editor calibration (previous entry) still floated in actual gameplay.
Root cause: `wheel.gd`'s suspension only moves once physics is actually
simulating - the static editor view shows the wheel at its UNLOADED
position, ~1.6 units higher than where it settles once the car's real
weight compresses the suspension during driving. The `@tool` visibility fix
was necessary but not sufficient - it made the wrong reference frame
visible, not the right one.
Measured the REAL target by letting the car settle 5 seconds under actual
physics and reading each wheel's true car-local resting position directly
(not guessed). User confirmed (via AskUserQuestion) they wanted this
applied directly rather than tuning it live themselves. Recomputed
`VoxelCarMesh`'s transform against these real numbers (scale 2.2078,
position (0,-1.8237,-0.1548) - down from the previous editor-calibrated
2.235/(0,-0.346,-0.13)), and updated `wheel_hull_mesh.gd`'s `hull_scale`
default to match (2.2078, was 2.3) so the wheel meshes stay visually
consistent with the body's new scale.
Verified headless: computed where the model's own measured wheel centers
land under the new transform and compared against the real settled
targets - all 4 corners within ~0.01-0.06 units (a well-fitted match, small
residual only from coupe.glb's proportions not perfectly matching
g-rcp2's wheelbase/track ratio, same caveat as before).
**Known tradeoff, not a bug**: the static editor 3D view will now show the
opposite mismatch (looks slightly too low/embedded, since it can't
represent the settled-under-load state) - this is unavoidable without the
game actually running; real gameplay is what's now correctly calibrated.

## Garage preview suspension + headlights recap
- **Headlights**: verified (not re-implemented) - `headlight_lights.gd` was
  already attached to every `VoxelCarMesh` instance including the garage's
  `PreviewCar` (same `base car.tscn`), confirmed headless: 2 `SpotLight3D`s
  found on it. Just not very visually obvious against the garage's own
  bright ambient/directional lighting - nothing was missing.
- **Garage preview floating car**: same root cause class as the main car -
  `PreviewCar` had `process_mode=DISABLED`/`freeze=true` so `wheel.gd`'s
  suspension never simulated at all, permanently stuck at the unloaded
  pose. Added `MAIN/misc/garage_preview_settle.gd`: briefly un-freezes the
  preview car (1.5s) so real physics settles it, then re-freezes it in
  that resting pose - not left running continuously, to avoid CPU cost on
  sound/engine logic nobody's looking at or any risk of it responding to
  player input. Also added real ground collision to `GaragePreview.tscn`'s
  Floor (previously a bare `MeshInstance3D` with nothing to land on).
  Verified headless: settles cleanly, no explosion, no falling through.
  **Known open discrepancy**: the settled wheel position in the garage
  differs numerically from the main game's own settled position (tried the
  ground_surface_variables.gd-missing-script theory, ruled it out - made
  no difference) - some other difference between "resting from a stationary
  start" vs. "falling from height 2" affects the equilibrium, not fully
  root-caused given time spent. Real, stable, physics-computed pose either
  way (verified non-frozen, non-exploding) - should look substantially
  better than the previous fully-frozen unloaded pose even if not exact
  numeric parity with the main car.

## Debug lines default-off (corrected approach)
The "white lines" from a wheel were `forces.gd`'s debug force-vector
visualization, gated by `car.gd`'s `Debug_Mode` (already toggleable via the
existing "F" key input action - `toggle_debug_mode`). First pass over-built
this: decoupled the lines into a new dedicated `misc_graphics_settings`
var + a 4th Graphics Config checkbox. User clarified they'd found the
existing F-key toggle themselves and just wanted the default flipped, not
new UI - reverted the decoupling/checkbox entirely and instead just removed
`base car.tscn`'s `Debug_Mode = true` override, falling back to `car.gd`'s
own coded default (`false`). Verified headless: defaults to false now
(lines/weight-distribution readout hidden), F key still toggles it on
correctly - single, minimal, correctly-scoped fix.

## Headlight position fix, gear icon relocation, FPS rounding, project font
- **Headlights actually invisible**: same bug class as the wheels - the
  `SpotLight3D` was parented at the headlight mesh's raw node origin, not
  its actual measured geometry center, so it likely sat somewhere off in
  space relative to the visible lens (possibly inside the body). Fixed
  `headlight_lights.gd` to offset the light to the mesh's measured AABB
  center, same technique already used for wheels. Verified headless: light
  world positions now land at (±1.6, +0.12 above car origin, +5.3 ahead of
  car origin) - front-of-car, roughly symmetric, plausible headlamp mount
  location, a dramatically different (and correct-looking) result vs.
  before.
- **Gear menu moved to upper-right** (`MenuGear`/`MenuList` anchors in
  `MISC/debugger.tscn`), per request.
- **FPS readout rounded** - `debug.gd`'s fps label now shows
  `int(round(1.0/delta))`, no decimals.
- **Project-wide font matches Voxel Driver**: that project uses `'Courier
  New', monospace` (no bundled webfont file, just a system font pick) - new
  `theme/main_theme.tres` (a `SystemFont` resource: "Courier New" ->
  "Consolas" -> "Courier" -> generic "monospace" fallback chain) set as
  `project.godot`'s `[gui] theme/custom`, cascading to every Control in the
  project by default (existing per-node font overrides, like the tacho
  labels' DroidSans, still take precedence where already set - untouched).
Verified headless: FPS text confirmed rounded (test caught a real idle-
`_process`-vs-`_physics_process` timing gap again, same class of issue hit
earlier - fixed by matching the test's own callback type), gear anchors
confirmed on the right side, project theme's `default_font` confirmed
resolving to the new SystemFont resource.

## Post-step-6 bugfixes
- Gear display regressed to always showing "D" (Automatic) because
  `SaveGame.transmission_mode` defaulted to `"auto"` and `GarageScreen`
  applies it to `car.TransmissionType` every run - silently overriding
  `car.gd`'s own authored default (Manual). Fixed the default to `"manual"`.
- The garage screen didn't pause the world - `car.gd` doesn't check
  `GameState` (kept as-is per the merge plan), so the player car kept
  driving/reading input in the background while browsing the garage.
  `GarageScreen` now sets `SceneTree.paused` on entering/leaving GARAGE, same
  mechanism the pause/crash overlays already use. Verified headless: car
  position frozen exactly while in garage, upgrade purchases still work
  (the UI subtree is `PROCESS_MODE_ALWAYS`), unpauses cleanly on return.

## Step 7: traffic headlights, streetlight cones, speed blur, nitro
User asked to (a) extend the player's headlight treatment to every traffic
car, (b) convert streetlights from point lights to downward-pointing cones,
and (c) add the previously-missing speed-up blur and nitro effects - all
part of the "step 7 polish" the build order deferred until a working,
correctly-feeling car existed.
- **Traffic headlights**: `traffic_car.gd`'s `setup_visual()` now attaches a
  `SpotLight3D` to each hull's `headlight_l`/`headlight_r` mesh, same
  `StructuredCarParts.find_part()` + measured-AABB-center-offset technique
  `headlight_lights.gd` already used for the player car. New shared
  `MAIN/misc/headlight_spec.gd` (`HeadlightSpec` class_name) factors out the
  tuning constants (`LIGHT_ENERGY`/`LIGHT_RANGE`/`LIGHT_SPOT_ANGLE`) so both
  scripts read the same values instead of carrying two copies that could
  drift apart - `headlight_lights.gd` refactored onto it too. This means up
  to 35*2=70 live `SpotLight3D`s under this project's `gl_compatibility`
  renderer (much stricter dynamic-light-per-draw-call limits than
  Forward+) - implemented as explicitly requested, flagged as a real
  performance tradeoff to watch; if it costs too much, dial back
  `TRAFFIC_COUNT` rather than cut lights unevenly per car.
- **Streetlight cones**: `road_generator.gd`'s `_make_streetlight()` swapped
  its `OmniLight3D` (lit in every direction, including uselessly upward into
  the sky/building faces) for a `SpotLight3D` pitched -90° about X (straight
  down), `spot_range=14*UNIT_SCALE`, `spot_angle=45°`, energy raised to 6.0
  to compensate for the cone no longer wasting light off-axis.
- **Speed blur**: new `MAIN/misc/speed_blur.gdshader` (canvas_item shader,
  `hint_screen_texture`, 8-sample radial zoom blur from screen center) since
  Godot 4's newer Compositor/CompositorEffect full-screen post system does
  NOT work under `gl_compatibility` - this project's actual renderer. Driven
  by `MAIN/misc/speed_blur.gd` on a new `SpeedBlur.tscn` (`CanvasLayer`,
  layer=2, under `LiveHud`'s layer=3 so HUD text stays legible on top),
  instanced in `world.tscn` alongside `LiveHud`. Finds the player car via
  the existing `player_car` group (same lookup `RunRewards`/`CrashSystem`
  use) rather than a NodePath. Intensity ramps from 0 at 80 km/h to full at
  220 km/h (`inverse_lerp`, exponentially smoothed to avoid jitter), with an
  extra +0.35 push while nitro is held. Verified headless: intensity rises
  under a forced high `linear_velocity` and decays back toward 0 once
  stopped.
- **Nitro**: new `MAIN/misc/nitro_boost.gd` on a `NitroBoost` node added to
  `base car.tscn`, additive-only (doesn't touch `car.gd`'s own engine math)
  - each physics frame the `nitro` input action is held AND
  `SaveData.get_upgrade_tier("nitro") > 0`, applies an extra
  `apply_central_force()` along the car's own forward axis
  (`global_transform.basis.z`, the same forward convention `wheel.gd`'s own
  drive-force code uses), scaled by upgrade tier. Reuses `fire.tscn` (the
  project's existing backfire particle scene) for the visual burst, but as
  a SEPARATE `NitroFire` instance (bigger amount/velocity/scale) so nitro
  doesn't fight `car.gd`'s own exhaust-backfire logic over the same
  emitter's `emitting` flag. **Key binding note**: the original three.js
  reference used Shift for nitro, but Shift is already bound to `clutch` in
  this project's manual-transmission control scheme - bound nitro to the
  free `nitro` action (N key) instead of overriding it.

## Step 7 follow-up fixes (user feedback after first playtest)
- **Blur was catching the debug HUD too.** The odometer/gear-menu/settings
  button (`MISC/debugger.tscn`, a plain `Control` with no `CanvasLayer` of
  its own, so it renders at the default canvas layer 0) sat BELOW
  `SpeedBlur`'s original `layer = 2`, so its pixels were already on-screen
  by the time the blur rect sampled `SCREEN_TEXTURE` and got baked into the
  blurred result - only `LiveHud` (layer 3) escaped, since it draws after.
  Fixed by dropping `SpeedBlur` to `layer = -10`, so it's the very first
  thing drawn after the 3D scene and before ANY canvas layer (debug HUD at
  0, `LiveHud` at 3, menu screens at 4+) - only the 3D world gets blurred
  now, every UI layer stays sharp on top of it.
- **Traffic headlights swapped from real lights to a cheap glow.** User
  confirmed: keep the player's real `SpotLight3D` headlights, but 70 live
  traffic lights wasn't worth the `gl_compatibility` cost for what's mostly
  a "can I see the lamp is lit" ask, not real per-car road illumination.
  `traffic_car.gd`'s `_attach_headlight()` replaced with
  `_make_headlight_glow()` - no `Light3D` at all, just a
  `StandardMaterial3D` with `emission_enabled=true` (colored via the same
  `StructuredCarParts.HEADLIGHT_COLOR`) as `material_override` on the
  headlight mesh. Zero dynamic-light budget cost, still visibly lit.
  Streetlights were left as real `SpotLight3D`s (a bounded, per-chunk count,
  not per-traffic-car) - user's "and the road lights too" was confirming
  they still wanted to see those, not asking to touch them further.
- **Nitro didn't feel like it was really boosting.** The `apply_central_force()`
  approach was real (verified the RigidBody3D's velocity did increase), but
  it competes against car.gd's own drivetrain/drag forces, which in this
  project are large enough that the added force read as a marginal nudge,
  not a burst. Switched `nitro_boost.gd` to add directly to
  `linear_velocity` each physics frame instead (`accel_per_tier=18.0`
  units/s² along the car's forward axis) - guarantees a fixed, predictable
  speed gain per second of hold regardless of whatever the drivetrain math
  is doing that frame, so it reads as an unmistakable kick.
Verified headless: nitro forward speed gain over ~1s of hold measured at
~17.7 (target ~18, matches `accel_per_tier`); traffic cars confirmed to
carry zero `SpotLight3D`s but all 70 headlight meshes have the emissive
glow material; player car confirmed to still carry its 2 real
`SpotLight3D`s.

## Player headlight beam pitch (user feedback after further playtest)
User reported the player's headlights only seemed to "show up" while the
car was sideways/turning and vanished driving straight down the road.
Traced this rigorously (measured the real glTF transform chain, computed
the light's world-space aim analytically, then verified numerically)
before touching anything:
- Confirmed `headlight_lights.gd`'s existing `light.rotation = Vector3(0,
  PI, 0)` yaw correction was ALREADY correct - verified headless the
  light's world aim comes out `(0,0,1)`, matching the car's real forward
  (front wheel nodes `fr`/`fl` sit at local Z=+3.8, rear `rr`/`rl` at
  Z=-3.1, so +Z is definitively front). Briefly tried removing that
  rotation on a mistaken theory it double-cancelled a flip from
  `traffic_car.gd`'s hull-building convention (`_hull.rotation.y = PI`) -
  that convention only applies to traffic's PROGRAMMATICALLY built hulls;
  the player's `VoxelCarMesh` is a plain scene instance in `base car.tscn`
  with pure uniform scale and NO rotation of its own, so that theory didn't
  apply here. Reverted once the numbers didn't match.
- **Real bug: zero pitch.** The light had no downward tilt at all - a
  perfectly level beam at headlamp height runs parallel to a flat road and
  never intersects the ground close to the car, so it stayed essentially
  invisible driving straight. Turning swept the same level beam across
  nearby buildings/guardrails/sidewalks instead, which DO catch it,
  creating exactly the "only visible while turning" symptom without any
  direction bug at all.
- Fixed by pitching the beam down (`DOWNWARD_TILT_DEG = -8.0`), composed
  via explicit `Basis` multiplication (`Basis(Y, PI) * Basis(X, tilt)` -
  pitch applied first, in the car's own forward-facing frame, before the
  180 yaw correction) rather than a `Vector3` Euler triple, since Euler
  component order is easy to get backwards for a combined yaw+pitch.
Verified headless: final world aim direction measured at `(0, -0.139,
0.99)` - forward and now visibly downward, instead of the previous dead-
level `(0, 0, 1)`.

## Headlight camera-occlusion diagnosis + tyre smoke default
User did their own diagnostic legwork here and it paid off: took a
screenshot from the default chase camera (no visible light on the road)
alongside one taken after manually orbiting the camera to the side with
the `,`/`.` keys (a clean, correctly-shaped headlight cone clearly lighting
the road right in front of the car). That side-by-side proved the light
itself was never broken - position, aim, pitch, energy, all fine. The real
cause: at the previous `-8°` tilt, the near-ground light pool lands close
enough to the car that the default chase camera (low, close, trailing
directly behind) has the car's own hood/roof physically between the lens
and that pool - not hidden when the beam sweeps sideways across something
tall like a wall/building since there's no hood in the way for that shot.
Fixed by halving the tilt to `-4°` (`headlight_lights.gd`'s
`DOWNWARD_TILT_DEG`) - for the same headlamp height, ground-contact
distance scales with `1/tan(tilt)`, so this roughly doubles how far ahead
the pool lands, pushing it out from under the car's own silhouette for the
default chase view. Verified headless: aim direction still forward
(z≈0.998) with roughly half the previous downward steepness (y≈-0.070 vs.
the old -0.139).
Also: `misc_graphics_settings.smoke` (`MISC/autoload/graphics.gd`) defaulted
to `false`, requiring a manual tick in Graphics Config to see tyre smoke at
all - flipped the default to `true` per request. The existing
`graphics config.gd`'s `_ready()` already syncs each checkbox's
`button_pressed` from the matching `misc_graphics_settings` var when the
panel opens, so this took effect with no other changes needed - user's own
follow-up screenshot already confirms the checkbox now opens pre-checked.

## Headlight root cause found: gl_compatibility's per-object light cap
User pushed back on the camera-occlusion theory ("i don't think its the
angle, i don't even know how it works") and asked for a literal visible
outline of the cone instead of inferring it from lighting effects. Added
`_add_debug_cone()` to `headlight_lights.gd` - a plain translucent cyan
mesh built directly in the SpotLight3D's own local space (apex at its
exact origin, extending to `spot_range`, sized by `spot_angle`), so it's
geometrically guaranteed to match the real cone with no separate transform
math to get wrong. Verified headless: local AABB spans exactly
`[-31.24, 31.24]` in X/Y and `0` to `-50` in Z, matching
`range*tan(spot_angle)` and `spot_range` precisely.
This actually solved it. User's screenshots showed the cyan cone clearly
visible from BOTH the default chase view and a rotated one - so position/
aim were never the problem, fully ruling out the earlier occlusion theory
too. But the real light only showed up as a glow near a building, never on
the road, even with the cone plainly overlapping the road surface. That
distinction - works on a small nearby mesh, not on the road - pointed at
something structural about the road specifically, not a per-light bug.
Root cause: Godot's Compatibility (gl_compatibility) renderer caps real-
time lights per mesh instance at `rendering/limits/opengl/max_lights_per_
object`, default **8**. Each road chunk is ONE big mesh spanning
`CHUNK_LENGTH` (~366 units), and `STREETLIGHT_SPACING` (~91.5 units) means
roughly 4 streetlights per side - 8 per chunk - already at the cap before
the player's 2 headlights are even considered, so the renderer drops them
for that mesh. A much smaller, isolated mesh (like a building) has room
left in its own budget, so the same lights show up fine there - exactly
the pattern observed. Fixed with one global setting:
`[rendering] limits/opengl/max_lights_per_object=24` in `project.godot`.
Verified headless: `ProjectSettings.get_setting(...)` confirms 24 is now
in effect project-wide (previously unset, defaulting to 8).

## Brake/tail lights
User asked where the brake lights were - `StructuredCarParts.REARLIGHT_COLOR`
was already documented but nothing used it yet. Added:
- **Player**: new `MAIN/misc/brake_lights.gd` (`HullBrakeLights` node in
  `base car.tscn`, same `hull_path`/`StructuredCarParts.find_part()`
  pattern as headlights) - emissive material on `rearlight_L`/`rearlight_R`,
  no real `Light3D` needed (tail lights don't need to cast illumination,
  just look lit, so this stays cheap). Reactive: dim baseline
  (`DIM_ENERGY=1.2`, a real car's tail lights always show some red) that
  jumps to `BRAKE_ENERGY=7.0` when the car's own `brakepedal` is actually
  above `BRAKE_THRESHOLD=0.1`, read straight off the parent car node each
  frame so it can't drift from the real pedal state.
- **Traffic**: `traffic_car.gd`'s `_make_headlight_glow()` generalized into
  a shared `_make_glow(mesh_node, color, energy)` helper, reused for
  `rearlight_L/R` with `REARLIGHT_COLOR` at a constant dim glow (no
  reactive braking - traffic doesn't track individual per-car braking state
  closely enough yet to react, same "cheap and static" scope as traffic's
  headlight glow).
Verified headless: player brake lights measured at 1.2 energy at rest and
7.0 while `brakepedal=1.0`; all 70 traffic rearlight meshes confirmed
carrying the glow material.

## Fake streetlights, traffic light LOD, debug cone removal, weight-dist toggle
Follow-up batch once the real root cause (gl_compatibility's per-mesh
real-time-light cap) was confirmed - user asked for the actual fix, not
just a workaround, plus a few debug-HUD cleanups:
- **Streetlights are now fake.** `road_generator.gd`'s `_make_streetlight()`
  no longer creates a real `SpotLight3D` at all - just a translucent,
  unshaded downward cone mesh (`_build_fake_light_cone()`, built directly
  with `SurfaceTool`, apex at the lamp head, spread to the ground by a
  fixed half-angle) alongside the existing emissive bulb. This is the
  actual fix for the root cause: ~8 streetlights per chunk were eating the
  ENTIRE per-mesh real-time-light budget on the road mesh before the
  player's headlight was even considered. A painted-on cone looks
  convincing from a driving POV (never viewed from directly underneath)
  and costs nothing from that budget.
- **`max_lights_per_object` raised to 24** (`project.godot`, was left at
  the default 8) - now that streetlights don't compete for it at all, this
  gives real headroom for the player's 2 lights plus several nearby real
  traffic lights (below) on the same road mesh.
- **Traffic gets real (cheap) headlights again, via distance LOD.**
  `traffic_car.gd` gained `set_real_headlights_enabled()` - lazily builds
  two real `SpotLight3D`s (cheaper tier: `HeadlightSpec.TRAFFIC_LIGHT_*`,
  shorter range/lower energy/narrower angle than the player's) on first
  enable, then just toggles `.visible` after, so repeated on/off doesn't
  rebuild nodes. `traffic_manager.gd`'s new `_update_headlight_lod()` runs
  every physics frame (the 35-car pool is small enough that a plain sort
  is fine, no throttling needed): only the closest `MAX_ACTIVE_TRAFFIC_
  LIGHTS=6` cars within `TRAFFIC_LIGHT_LOD_RADIUS` (55 units) of the player
  get promoted to a real light; everything else keeps the existing
  always-on cheap emissive glow. No extra yaw correction needed on the
  traffic light itself (unlike the player) - traffic's hull already gets
  the 180 flip in `setup_visual()`, inherited automatically through the
  transform chain.
- **Debug cone removed** (`headlight_lights.gd`'s `_add_debug_cone()` and
  its call site deleted) - it did its job diagnosing the real cause and
  isn't needed as a permanent visual.
- **Weight distribution now off by default and fully hidden**, not just
  gated by `Debug_Mode`/F-key. Added `misc_graphics_settings.show_weight_
  dist` (default false) + a matching `ShowWeightDist` checkbox in Graphics
  Config (same `check_variables.gd` pattern as the other 3 toggles).
  `debug.gd` now sets the whole `container/weight_dist` Label's `.visible`
  off this new toggle - previously the "[ press F to fetch weight
  distribution ]" placeholder text itself was always shown regardless of
  Debug_Mode, which is what the user actually wanted gone from the
  top-left HUD by default.
Verified headless: `RoadGenerator` subtree now contains zero real
`SpotLight3D`/`OmniLight3D` nodes; player headlights confirmed to carry no
extra debug-cone children; teleporting the player next to a spawned
traffic car and stepping physics confirmed a nonzero (and ≤6) count of
`_real_headlights_on` traffic cars; `weight_dist` Label confirmed hidden
by default.

## Cantilever streetlight poles, gradient cone, brake-light color fix, turn signals
Final polish pass on the lighting work:
- **Streetlight pole shape**: was a plain vertical pole with a lamp on top
  (a pedestrian streetlamp) - user wanted the real highway-pole shape,
  planted beside the road but reaching an arm OVER the lanes so the
  fixture actually hangs above them. `_make_streetlight(side)` (now takes
  `side` so it knows which way to bend) builds pole + a horizontal arm
  (`ARM_REACH_FRAC=0.6` of `ROAD_HALF_WIDTH`) rotated to extend from the
  pole toward the road center, then a short vertical `ARM_DROP` at the
  tip where the lamp head and fake-light cone's apex now sit - reads as
  an "upside-down L". Verified headless (both `side=-1`/`+1`): the arm's
  computed world-space endpoints land at local x=0 (the pole) and
  x=toward_road*arm_length (over the road), confirming the geometry
  actually spans pole-to-road rather than just looking right by luck.
- **Cone gradient**: `_build_fake_light_cone()` now sets per-vertex alpha
  via `SurfaceTool.set_color()` (apex=0.0, base=0.22) with the material's
  `vertex_color_use_as_albedo=true`, instead of one flat alpha for the
  whole mesh - fades in from invisible near the fixture to visible at the
  ground, reading as "light landing on the road" rather than a solid
  funnel hanging in open air. Verified headless: vertex color alpha at the
  apex is 0.0, at the base ring 0.2196.
- **Debug cone removed** was already done; **"HEADLIGHTS: ON" HUD label
  also removed now** (`live_hud.gd`/`LiveHud.tscn` reverted to their
  pre-diagnostic state) - its job (finding the real root cause) is done.
- **Brake lights were going white, not brighter red** - root cause: a high
  enough `emission_energy_multiplier` saturates all 3 color channels past
  1.0 after tonemapping, and a fully-saturated color reads as white
  regardless of its original hue, no matter how red the base emission
  color is. Fixed in `brake_lights.gd` by using a genuinely LIGHTER red
  color for the "braking" state (`BRAKE_COLOR = Color(1.0, 0.42, 0.42)`,
  `REARLIGHT_COLOR` mixed toward white) alongside a much more modest
  energy bump (`BRAKE_ENERGY` 7.0 -> 3.5), instead of relying on a huge
  multiplier alone. Verified headless: braking emission color measured at
  `(1.0, 0.42, 0.42)`, energy 3.5 - clearly red, not blown out.
- **Traffic turn signals**: `traffic_car.gd` gained `update_turn_signal
  (turn_dir, blink_on)`, called every physics frame from
  `traffic_manager.gd`'s existing per-car loop with the car's own already-
  tracked `turn_dir` (nonzero for the ENTIRE signal+lane-change window, an
  existing field, not new state) and a shared blink oscillator
  (`TURN_SIGNAL_PERIOD=0.6s`, one timer for every car so they all pulse in
  sync). Blinks the correct side amber (`TURN_SIGNAL_COLOR`) - sign
  convention: `RoadMetrics.lane_to_frac()` increases toward +X and the car
  faces +Z, so a higher lane (turn_dir > 0) is to the car's right, matching
  real turn-signal side conventions - and reverts to the normal dim red
  otherwise. Verified headless: `turn_dir=0` keeps both sides dim red;
  `turn_dir=1` with the blink phase on lights only the RIGHT side amber
  (left stays dim red); the same car with the blink phase off reverts to
  dim red; `turn_dir=-1` blinks the LEFT side instead.
Verified headless throughout, plus a full `world.tscn` smoke-load with no
script errors after all of the above landed together.

## Plan: real RigidBody3D physics for traffic (player-hit "budging")
**Status: implemented and verified headless.** User chose the full
RigidBody3D option (over a cheaper cosmetic spring-offset alternative) when
asked. Implemented as designed below, with one real correction discovered
only through verification - see "What verification actually caught" at the
end of this section.

### Context
Traffic cars today (`TrafficCar.tscn`) are a plain `Node3D` with NO collision
shape at all - `traffic_manager.gd`'s `_render_car(t)` directly sets
`t.position`/`t.rotation.y` every frame from AI state (`t.dist`, `t.x_frac`,
`t.lane_yaw_offset`), a pure teleport, and `crash_system.gd` detects player-
vs-traffic hits via a numeric proximity check (lateral gap vs. hit bands),
not real physics collision (deliberately, per its own header comment - "no
collision shapes needed on traffic cars"). On a hit today, only the PLAYER's
own velocity gets scripted down (`car.linear_velocity *= severity_mul`) -
the traffic car itself never visibly reacts, it just keeps gliding along its
lane math untouched. User wants a real "budge" - hit a traffic car and it
should physically react with believable momentum, not just sit there while
you slow down. User explicitly chose the full RigidBody3D route over a
cheaper cosmetic spring-offset alternative, accepting the larger scope.

The traffic AI (`traffic_manager.gd`) has TWO documented, previously-
regressed subsystems (`_lane_front` gap-tracking = "Regression A",
recycle/spawn distance = "Regression B", both flagged inline in the code) -
the design below is built to avoid touching either of them, by only ever
handing a car to real physics for a bounded window after a confirmed hit,
then re-acquiring AI control from wherever it physically settled.

### Design: FOLLOWING / KNOCKED hybrid, not always-on physics-driven AI
Rewriting the AI to be continuously force/torque-driven (real physics
steering, lane-changing, gap-keeping for all 35 cars at all times) would be
a from-scratch rewrite of the driving AI itself, not a "make hits react
realistically" feature - out of scope here. Instead, each traffic car gets
a real `RigidBody3D` + `CollisionShape3D` (real shape, real mass, real
collision), but AI control and physics control are mutually exclusive per
car, gated by a small state machine:
- **FOLLOWING** (the normal, ~always-true state): every physics frame, the
  manager computes the AI's desired position/yaw from `dist`/`x_frac`/
  `lane_yaw_offset` exactly as today, then instead of teleporting
  (`t.position = ...`), sets `t.linear_velocity = (desired_pos -
  t.global_position) / delta` and an equivalent `angular_velocity` for yaw.
  This "steers" the real body every frame (matches what the user's chosen
  option described - steering, not teleporting) while keeping 100% of the
  existing lane-following/gap/spawn logic untouched and authoritative.
- **KNOCKED**: entered only when `crash_system.gd`'s EXISTING numeric hit
  check fires (that detection is already correct and tuned - reused as the
  trigger rather than wiring up separate Godot contact signals). On trigger,
  the manager stops overwriting velocity for that car and lets the real
  physics engine fully own it for `KNOCK_DURATION` (~1.8s, tunable) or until
  its velocity settles below a small threshold - real inertia, real
  friction, can realistically bump into world geometry (guardrails) or
  (see collision layers below) other traffic. `_check_recycle` and the
  lane-change AI are skipped for a knocked car (its `dist` isn't a reliable
  position proxy while physics has control).
- **Recovery**: once the knock window ends, re-sync AI state FROM the
  physics result - `t.dist = t.global_position.z`, `t.x_frac` derived from
  `t.global_position.x`, `t.lane = RoadMetrics.x_to_lane(...)` (already
  clamps safely), cancel any interrupted lane change (`turn_dir=0`,
  `changing_lanes=false`), zero `lane_yaw_offset`, then resume FOLLOWING.
  The car just re-enters traffic flow from wherever it ended up - no special
  casing needed since this reuses the exact same fields the AI already
  understands. (`_lane_front` gap-tracking only gets touched at SPAWN time,
  not by ongoing following, so recovery doesn't need to touch it at all.)

### Collision layers (new, everything else currently defaults to layer 1)
No named layers exist yet - player, road/guardrail `StaticBody3D`s all sit
on the Godot default (layer 1, mask 1), unchanged by this plan. New layer
bit 3 (value 4) = "traffic cars":
- Traffic `collision_layer = 4`.
- Normal (FOLLOWING) `collision_mask = 1` - hits the player and static world
  geometry (both already on layer 1), but NOT other traffic (also layer 4,
  not in this mask) - avoids two AI-driven cars physically fighting each
  other's independent lane-following targets during ordinary gap-following.
- While KNOCKED, mask temporarily becomes `1 | 4` - can now also chain into
  other traffic cars, matching what the user's chosen option called out
  ("could realistically chain into cars ahead"). Reverts to `1` on recovery.
- `gravity_scale = 0.0` (traffic has no suspension/ground-contact model,
  unlike the player's wheel.gd raycasts - stays flat by design, not falling
  through the world), plus `axis_lock_linear_y` and X/Z angular locks so a
  hit can't send a car flying or tumbling - matches the arcade feel of
  everything else in this project.

### Per-kind mass
Godot's RigidBody3D `mass` isn't real-world kg here - the player's own
`base car.tscn` RigidBody3D uses `mass = 90.0` as its internal scale, not a
literal 90kg car (documented from earlier calibration work). New traffic
masses picked proportionally against that same 90 baseline so momentum
transfer feels right relative to the player (trucks resist more, sedans
less) - starting point only, meant to be tuned by feel post-implementation:
`passenger:80, normal/taxi:95, wide/truck:160, armored:200, police:95`.

### crash_system.gd changes
- `_check_car(t, car, player_speed)` already computes exactly which `t` was
  hit - thread that reference into `_register_collision` (currently only
  takes `car`/`impact_speed`/`severity_mul`) so it can call a new
  `t.enter_knocked_state(impulse, spin)`, with the impulse direction/
  magnitude derived from the player's own `linear_velocity` and the mass
  difference between the two cars.
- Remove the manual `car.linear_velocity *= severity_mul` line - now that
  real physics collision exists, the physics engine provides that momentum
  response naturally; keeping BOTH would double up the effect (scripted
  slowdown + a real physics impulse on the same hit). Flagged explicitly as
  a feel change to watch/re-tune once playable, not a silent removal.
- Everything else in crash_system.gd (HP/damage math, near-miss scoring,
  invuln window, crash-triggering) stays exactly as-is - this only touches
  the velocity-response line and threads one extra argument through.

### Collision shape sizing
Reuse the AABB measurements `setup_visual()` already computes for gap math
(`half_len`, `half_w`) rather than re-deriving anything - a `BoxShape3D`
sized from those same numbers, so a truck's hull naturally gets a bigger
collider than a sedan's for free.

### Files touched
- `MAIN/traffic/TrafficCar.tscn` - root changes `Node3D` -> `RigidBody3D`
  (mass/gravity_scale/axis locks set here), gains a `CollisionShape3D`.
- `MAIN/traffic/traffic_car.gd` - collision shape sizing in `setup_visual()`
  (reusing existing AABB math), new `ControlMode` enum + state fields,
  `enter_knocked_state()`, a recovery-check helper.
- `MAIN/traffic/traffic_manager.gd` - `_update_car`/`_render_car` branch on
  control mode (velocity-drive vs. hands-off-to-physics), `_check_recycle`
  skipped while knocked.
- `MAIN/gameplay/crash_system.gd` - thread `t` through to
  `_register_collision`, call `enter_knocked_state()`, remove the manual
  velocity-scaling line.

### Verification plan
Headless, same pattern used throughout this session (throwaway
`_verify_*.tscn`/`.gd`, always cleaned up after):
1. Regression check: with no collision ever triggered, confirm a car's
   frame-to-frame position under the new velocity-driven FOLLOWING mode
   still tracks its `dist`/`x_frac`-implied position closely (should match
   the old teleport behavior within a small epsilon, not drift).
2. Directly call `enter_knocked_state()` on a car with a real impulse,
   confirm: control mode flips to KNOCKED, its position over the next few
   physics frames diverges from the pure AI-implied position (proving
   physics, not AI, is driving it), then after `KNOCK_DURATION` confirm it
   flips back to FOLLOWING with `dist`/`x_frac`/`lane` resynced to match
   where it physically settled.
3. Confirm collision masks: two FOLLOWING traffic cars placed overlapping
   do NOT generate a physics contact (mask exclusion working); a KNOCKED
   car's mask does include the traffic layer.
4. Drive the player's real RigidBody3D into a stationary traffic car in a
   full `world.tscn` load, confirm both bodies' velocities actually change
   (real collision response happening), and the hit traffic car reaches
   KNOCKED state via `crash_system.gd`'s own trigger path (not a manually
   called test hook), then recovers cleanly.

### What verification actually caught
Items 1-3 passed exactly as designed on the first try (FOLLOWING drift
measured at 0.0 over 30 physics frames; manual knock test showed
control_mode flipping, the car moving 14 units while knocked purely from
physics, then resyncing dist to within 0.0001 of its real settled
position; overlapping FOLLOWING cars produced no meaningful push-apart).

Item 4 (the real end-to-end path) initially FAILED - the plan's own
premise that "reuse crash_system.gd's existing numeric proximity check as
the trigger" turned out to be broken once traffic actually has real
collision shapes. The old check detected a hit by penetration depth (`dz <
hit_l`), which was a valid signal ONLY because traffic previously had NO
collision shapes, so the player could freely overlap a traffic car before
this change. Now that real collision shapes physically PREVENT
interpenetration, the two bodies simply stop at first contact (dz settles
right at the hit_l boundary, never strictly under it) - so the old
threshold check almost never fires anymore, verified directly: driving the
player at speed 40 into a stationary traffic car changed the player's own
velocity (proving real physics contact happened, 40 -> 37 units/s) while
crash_system's hit check never triggered (hp stayed at 100).

Fixed by switching `crash_system.gd`'s actual HIT detection (not the near-
miss check, which is unaffected - that's inherently about NOT touching) to
real physics contact: `contact_monitor=true`/`max_contacts_reported=8`
added to the player's RigidBody3D (`base car.tscn`), and
`_physics_process` now checks `car.get_colliding_bodies()` for anything
with an `enter_knocked_state` method (duck-typed traffic car check) instead
of a distance threshold. Also switched the surviving near-miss distance
check from `t.dist`/`t.x_frac` (AI-logical position) to `t.global_position`
(the car's REAL position) - they match almost exactly under normal
FOLLOWING (proven by the 0.0 drift result above) but can genuinely diverge
for a moment during an active collision, since real contact resists
`_drive_following`'s pull back toward the AI's target; using the logical
position there would have under-counted near-misses during exactly the
scenario this whole feature is about. Also added a guard in
`_register_collision` (`if t.control_mode == KNOCKED: return`) so
sustained contact across multiple frames doesn't keep restarting the knock
impulse/timer before the car has a chance to actually move away.
Re-verified end-to-end after the fix: real collision now correctly drives
the full path (player rams a stationary traffic car -> `crash_system`'s own
trigger fires -> `enter_knocked_state()` -> hp drops from 100 to 75.5,
control_mode flips to KNOCKED) with no test hook called directly.

Also ran an additional 30-simulated-second sustained-driving torture test
(matching the original traffic-AI torture test from when traffic was first
built) after all of the above landed together: 0 NaN, 0 cars ending up
implausibly far from the player, across all 35 pooled cars - confirms the
spawn/recycle/gap-following system is still fully stable under the new
physics-driven FOLLOWING model.

## WRECKED state, crash flash/sparks, and starting HP
Follow-up on the traffic physics work: user wanted crashed NPCs to actually
stay crashed (not "magically correct itself" back into traffic), read as a
real hazard, and a big hit to have real visual punch (screen flash +
sparks). Also asked for a much bigger starting HP pool with a visible HUD
readout.
- **New `ControlMode.WRECKED`** (`traffic_car.gd`) alongside the existing
  KNOCKED: real physics plays out the impact the same way, but a wrecked
  car never resyncs/resumes AI control - `traffic_manager.gd`'s `_update_car`
  just leaves it alone (skips AI entirely) once wrecked, blinking BOTH
  rear lights together (`set_hazard_lights()` - real hazard lights, not
  just an idea, actually implemented as such) until the player drives far
  enough past it. Recycling for a wrecked car can't reuse the normal
  `_check_recycle` (its `dist` is frozen from the moment of the crash, not
  a valid position anymore) - new `_check_wrecked_despawn()` checks the
  car's REAL `global_position.z` against the player instead, then recycles
  it through the exact same `_place_traffic_car()` path everything else
  uses (which calls `resume_following()` via `_reset_car_state`).
- **Big vs. small hit threshold**: `crash_system.gd`'s `_hit_traffic_car()`
  (renamed from `_knock_traffic_car()`) now branches on impact speed -
  above `TRAFFIC_WRECK_TRIGGER_FRAC` (0.5 of `REFERENCE_MAX_SPEED`) the
  traffic car gets `enter_wrecked_state()` instead of `enter_knocked_state()`,
  plus `_play_big_crash_effects()`; below it, the existing temporary budge-
  and-recover behavior is unchanged. The repeat-trigger guard broadened
  from "skip if already KNOCKED" to "only react physically if still
  FOLLOWING" (covers both KNOCKED and WRECKED with one check) - HP/combo
  still apply every frame of contact regardless (an existing, unchanged
  property - no invuln window on a plain hit, not something newly
  introduced here).
- **Screen flash**: new `MAIN/misc/ImpactFlash.tscn`/`impact_flash.gd` - a
  CanvasLayer at layer 8 (above even CrashOverlay's 7, the highest anything
  else in this project uses) so it genuinely washes out the WHOLE screen
  including HUD for an instant, unlike SpeedBlur which deliberately stays
  below all UI. A plain ColorRect with its alpha driven by `flash()`/decay
  in `_process` - no shader needed (unlike the blur, this doesn't need to
  sample SCREEN_TEXTURE).
- **Sparks**: new `MAIN/misc/ImpactSparks.tscn`/`impact_sparks.gd` - a
  one-shot `CPUParticles3D` burst (unshaded emissive quad material, bright
  yellow-orange), instantiated fresh at the impact point by
  `_play_big_crash_effects()`, frees itself via the `finished` signal
  `CPUParticles3D` emits once a `one_shot` burst completes.
- **Starting HP raised to 300** (`BASE_MAX_HP`, was the ported original's
  100) - "plenty" per request, and because real collision now lands hits
  more reliably than the old penetration-based detection ever did, so a
  bigger buffer matters more.
- **HP now visible in the HUD** - new `HpLabel` in `LiveHud.tscn` (top-
  right, mirroring the score strip), `live_hud.gd` reads `CrashSystem.hp`/
  `max_hp` each frame via a NodePath export (same pattern as the other
  cross-node references in this project), color-coded green/amber/red by
  remaining fraction like the existing combo-multiplier color coding.
Verified headless: starting hp confirmed at 300/300; a car manually wrecked
stayed WRECKED across 3.3s (well past KNOCK_DURATION, proving no auto-
recovery, unlike KNOCKED); hazard lights confirmed actually alternating
colors over time (not just set once); leaving a wrecked car far behind the
player correctly recycled it back to FOLLOWING; the real end-to-end path
(player rammed into a stationary traffic car at high speed) correctly
produced WRECKED via crash_system's own trigger AND spawned a real
ImpactSparks instance in the scene tree, with `flash()` independently
confirmed to raise alpha to 1.0 and decay smoothly afterward.

## Flash vignette + real run reset (Play Endless bug)
Two follow-ups: the crash flash should be a darker white vignette (not a
flat full-screen wash), and starting a new run from the garage after a
crash should actually reset the world instead of continuing from the crash
point.
- **Vignette flash**: `impact_flash.gdshader` (new) - a canvas_item shader,
  transparent in the center and brightening toward the screen edges via
  `smoothstep` on distance from UV center (aspect-corrected for this
  project's 1024x600 default), driven by the same `intensity` uniform
  pattern SpeedBlur already uses. `impact_flash.gd` now sets a shader
  parameter instead of `modulate.a`; color darkened from pure white to
  `(0.78, 0.74, 0.68)`. Verified headless: intensity rises to ~0.92 right
  after `flash()` and decays smoothly afterward.
- **Run reset root cause**: nothing anywhere reset the player car's actual
  position/velocity, the road chunks, or the traffic pool when a fresh run
  started from the garage - `RunRewards` only LOOKED correct on its own
  because it tracks distance relative to wherever the car WAS when PLAYING
  began, not an absolute position, so its own reset (already existed) never
  exposed the bug. New `MAIN/gameplay/run_reset.gd` (`RunReset` node in
  `world.tscn`) uses the exact same trigger condition `RunRewards`/
  `CrashSystem` already use (`new_state == PLAYING and old_state !=
  PAUSED`) to: teleport the car back to its own authored spawn transform
  (captured once at `_ready()`, before any driving happens) and zero its
  velocity, THEN call two new coordinator methods (car position has to
  reset first, since both of these read the car's CURRENT position to
  decide what to rebuild around):
  - `road_generator.gd`'s `reset_chunks()` - frees every existing chunk and
    rebuilds the window immediately around the new position in one pass
    (not left to `_physics_process` to incrementally converge over several
    frames, which would show a visible pop as ~2000 units of chunks
    materialize piecemeal). Chunk content is a pure function of chunk
    index (buildings are seeded per-index), so rebuilding the same indices
    is deterministic.
  - `traffic_manager.gd`'s `reset_traffic()` - re-places the EXISTING
    pooled cars (no new instances) around the new position, mirroring
    `_ready()`'s own first-load logic exactly, including re-seeding `_rng`
    and clearing `_lane_front`/`_gap_lane_segments`. Clearing `_lane_front`
    specifically isn't cosmetic - `_required_center()`'s own logic only
    advances a lane's stale value when it's LESS than the current
    player_dist; after a long run the stale value would be far larger than
    the freshly-reset (~0) player_dist, so without clearing it, new traffic
    would keep spawning at the OLD run's distances - the exact regression
    class this traffic system has documented history with. Also calls
    `resume_following()` on every car, clearing any leftover KNOCKED/
    WRECKED state from the crash that ended the previous run.
Verified headless: simulated a "run" by placing the car at z=20000, then
drove the state machine through CRASHED -> GARAGE -> PLAYING (matching the
real UI flow, not a manual test hook) - car position landed within
millimeters of the authored spawn point with velocity zeroed; 8 chunks
existed near the new spawn and (with a properly separated test threshold
this time) exactly 0 remained near the old z=20000 crash point; 26 of 35
traffic cars landed near the new spawn (the rest legitimately spread
further out within the normal spawn-ahead window) with 0 left behind near
the old crash point.

## Randomized layout, HP-only crash, turn-signal fix
Quick follow-up batch:
- **Random run variety**: user wanted each run's buildings/traffic to
  actually look different, not the same fixed layout every time (a real
  app restart would produce the same fixed layout too, since both were
  keyed off constants - `TRAFFIC_SEED=777`, `hash(chunk_index)` alone).
  `traffic_manager.gd` now draws `_rng.seed = randi()` fresh in both
  `_ready()` and `reset_traffic()` instead of the old fixed `TRAFFIC_SEED`.
  `road_generator.gd` gained `_run_seed` (also `randi()`, set in `_ready()`
  and re-rolled in `reset_chunks()`), XORed into each chunk's building RNG
  (`hash(index) ^ _run_seed`) - keeps a chunk's layout stable WITHIN a run
  (revisiting the same chunk index still looks the same, avoiding the
  "pops differently each pass" bug this exact pattern was designed to
  avoid) while varying it between runs. Verified headless: loading
  `world.tscn` 3 times produced 3 distinct `_run_seed`/traffic-`_rng.seed`
  values each time.
- **Crash now ONLY at HP 0**: `crash_system.gd` no longer also crashes on a
  single hit above `HIT_TRIGGER_FRAC` (removed, was the ported original's
  own rule) - with a 300 HP pool, even a full-speed hit should just cost a
  big chunk of health, not end the run outright. Verified headless (after
  fixing test flakiness from the new random traffic speeds - pinning a
  test car's `speed=0` so it can't randomly outrun the player before
  contact): a hard single hit measurably drops HP without crashing when HP
  stays positive; sustained real contact against a stationary obstacle
  correctly still crashes once HP legitimately reaches 0 (unchanged,
  existing "no invuln on a plain hit" behavior, not a new bug).
- **Traffic turn signal was backwards** - `update_turn_signal()`'s
  left/right mapping empirically confirmed inverted by the user (signaled
  left while turning right). Swapped: `turn_dir > 0` now blinks LEFT,
  `turn_dir < 0` blinks RIGHT. Verified headless both directions light the
  correct side.

## Plan: curves, elevation/banking, biome tinting, and particle effects
**Status: build-order Stages 1-4 DONE and verified (RoadPath generator,
PathTracker, RoadGenerator curved integration, traffic/RunRewards dist
reconciliation). Stages 5-6 (biome tinting, rain/ambient particles) still
to do - see "Progress" below.**

### Progress
- **Stage 1 (RoadPath)**: implemented (`MAIN/road/road_path.gd`). Verified
  headless: full run (4299-4315 points depending on seed) generates in
  ~18ms; zero non-finite values; bank/curvature stay within their clamped
  bounds; road width stays constant across the banked cross-section to
  ~0.006 unit error over hundreds of samples; banking DIRECTION verified
  correct against the original's own documented sign-bug fix (outside/
  right edge measurably higher on a left turn, and vice versa, consistent
  across every sampled sweeper chapter).
- **Stage 2 (PathTracker)**: implemented (`MAIN/road/path_tracker.gd`).
  Verified headless: sub-unit error tracking a simulated car along both the
  centerline and a realistic lane offset through curves.
  ⚠️ Watch item: the incremental nearest-point search assumes the car's
  actual position never jumps far from the previous frame's estimate in a
  single tick - true for normal driving/knockback, but a future feature
  that teleports the player far along the SAME run (not a fresh
  run-reset) could desync it; not a concern for anything currently built.
- **Stage 3 (RoadGenerator curved integration)**: `road_generator.gd`
  rewritten - ribbon/lane-dash/fence/streetlight/building positioning all
  sample `RoadPath.world_pos()`/`road_frame()` now instead of flat
  `Vector3(x,0,z)` math; ground/guardrail collision subdivided to one
  segment per path row (position+yaw from the row's own frame; bank ROLL
  deliberately not applied to the collision shapes themselves - flagged
  simplification, not hidden - the visual mesh still banks correctly).
  `reset_chunks()` now also regenerates a fresh `RoadPath` each run (new
  seed), so curve/elevation/biome layout is genuinely different run to
  run, same as buildings/traffic already were. Verified headless: 2688
  ribbon vertices checked with 0 non-finite; collision shape count exactly
  matches the expected `chunks * rows * 3` formula; measurable heading
  change confirmed within the first ~400 units (inside the forced-first
  sweeper chapter) via a full `world.tscn` load and drive.
- **Stage 4 (traffic/RunRewards dist reconciliation)**: `traffic_manager.gd`
  gained `_road_path()`/`_player_dist()`/`_lateral_offset()` helpers (the
  last inverts `world_pos()`'s banked transform via projection onto the
  frame's right vector) and a `_estimate_dist_and_lateral()` (a throwaway
  `PathTracker` seeded at a car's last known `dist`) for converting a
  KNOCKED/WRECKED car's real settled position back into AI-understandable
  dist/x_frac on recovery/despawn-check. `_drive_following`/`_render_car`
  now sample the curved path. `RunRewards.current_distance` switched from
  raw `car.global_position.z - _start_z` to arc-length via RoadGenerator's
  `PathTracker` (dynamically looked up each call, since RunRewards is an
  autoload with no fixed NodePath into world.tscn's tree).
  **Real bug found and fixed by verification**: traffic cars had
  `axis_lock_linear_y = true` (from the original flat-road-only design, to
  prevent flying/tumbling during a knock) - once the road got real grade,
  this permanently pinned every traffic car's Y position, so drift from
  its AI-desired (now-elevation-following) position grew WITHOUT BOUND
  over a sustained drive (measured 110+ units after 15s in the first test
  run). Removed the Y lock (kept the angular pitch/roll locks - yaw-only
  rotation is still enforced) - drift dropped to a small BOUNDED
  oscillation (max 8 units across the whole 35-car pool) that self-
  corrects, consistent with ordinary lane-change/speed-adjustment lag, not
  a bug. Re-verified with a full 60-second sustained-driving torture test
  through many chapters afterward: 0 NaN across the pool, stable chunk
  window, all distances within expected bounds.

### Post-Stage-4 fixes: staircased collision + inverted banking (user-caught)
User caught two real bugs by eye/screenshot that Stage 3's own verification
missed: (1) collision on graded sections rendered as a literal visible
staircase (per-row flat `BoxShape3D`s just abutting at a vertical step
wherever there's elevation change between rows - the "no bank roll on
collision" simplification I'd flagged was real, but I'd underestimated
that even ignoring bank, the discrete per-row height alone produces a
literal stair-step, confirmed directly in the user's own screenshot of
Godot's built-in Debug -> Visible Collision Shapes view); (2) banking
direction was backwards - a left curve raised the LEFT edge instead of
dipping it (real-world superelevation needs the inside/left edge lower on
a left turn). Root cause of (2), found on re-audit: my own earlier
"verified correct" banking check had mislabeled which lateral sign is
"left" - this project has an established convention from the earlier
traffic turn-signal fix that +lateral/+x_frac is the car's LEFT side, not
right, and my test had assumed the opposite.
- User explicitly asked to research the fix rather than trial-and-error.
  Investigated (and ruled out) a full trimesh (`ConcavePolygonShape3D`)
  per chunk: technically the "mesh collider" equivalent to Unity's, and
  `MeshInstance3D.create_trimesh_collision()` is the direct Godot analog -
  but web research surfaced a confirmed, OPEN, no-workaround Godot bug
  (godotengine/godot#100539) where `RayCast3D` unreliably detects
  `ConcavePolygonShape3D` collision built from a procedural `ArrayMesh` -
  exactly how this road mesh is built, and this project's entire
  suspension (`wheel.gd`) runs on `RayCast3D`. Not worth that risk.
- **Fix implemented**: `_build_collision()` (`road_generator.gd`) now
  builds one `ConvexPolygonShape3D` per row (both ground and guardrail
  walls) from the row's ACTUAL corner points - the same ones
  `_build_ribbon_mesh()` already computes for the visual surface, not an
  approximated rotation - so collision carries real pitch (grade) and roll
  (bank), matching the visual mesh exactly, at the same SEG_LEN-granularity
  fidelity (small kinks between rows, not a perfectly smooth curve, but
  bounded small since RoadPath itself caps how much curvature/grade can
  change per segment - can revisit with finer subdivision later if needed,
  deferred per user's own "test first, subdivide later if needed" call).
  `road_path.gd`'s bank formula negated (`bank = -d_heading * BANK_PER_RATE`)
  to fix the left/right inversion.
Verified headless: banking direction re-checked with CORRECT edge labels
this time across 6 sampled turns (both directions) - inside edge
consistently lower, outside edge consistently higher, every time; 24
collision shapes built per chunk (8 rows * 3) with 0 non-finite points;
critically, 20/20 raycasts against the new `ConvexPolygonShape3D`
collision hit correctly (directly disproving any concern that the
trimesh-specific bug would apply here); full-world smoke test with the
REAL player car driving for 10 seconds showed only 0.018 units of Y drift
(rock-stable on the new collision surface, raycast suspension working
correctly, car.gd/wheel.gd untouched throughout).

### Spawn point, km display, building facing
Three quick fixes alongside the collision work:
- **Spawn point was on a lane boundary, not centered in a lane** - the
  authored spawn x was 0, which is exactly the seam between the two center
  lanes (`RoadMetrics.lane_to_frac`'s own lane centers sit at
  ±0.25/±0.75, never 0) - looked like the car was sitting on an edge/line
  because it literally was. `world.tscn`'s car spawn transform x changed
  to `RoadMetrics.lane_to_x(1)` (-6.59486049). `run_reset.gd`'s
  `_spawn_transform` capture is unaffected (it just reads whatever
  world.tscn authors at `_ready()`), so this fix applies to every future
  run reset too, not just first launch.
- **Live KM display** - new `DistLabel` in `LiveHud.tscn`'s score strip,
  `live_hud.gd` converts `RunRewards.current_distance` (this project's own
  engine units) through `RoadMetrics.UNIT_SCALE` to real metres then km,
  formatted "%.2f KM".
- **Buildings faced away from the road** - user had hit and fixed this
  exact same issue in the original Voxel Driver three.js project before;
  `road_generator.gd`'s `_build_buildings()` rotation was missing a 180
  flip (`inst.rotation.y = f.heading + (PI/2)*side`, now `+ PI` added).
Verified headless: spawn x lands within a fraction of a unit of the exact
lane-1 center (tiny residual from normal suspension settling); KM label
correctly reads 0.00 at run start and 0.05 after 5 seconds of driving at
30 units/s (matches the expected ~45.9m); building rotation confirmed
including the new +PI term.

### Still to do
- **Stage 5**: biome tinting (`BIOME_TABLE` port - road/shoulder/edge-line/
  guardrail color lerp only, per the research's confirmed scope).
- **Stage 6**: rain streaks + ambient biome particles (`MAIN/misc/weather/`,
  custom script-driven systems per the research's recommended approach).

### Context
The road has been flat and straight since it was first built (step 4's MVP),
deliberately deferred - the original three.js game (`js/core.js`) has a real
chapter/curve/elevation/banking/biome system, and the user asked to port it
now, explicitly "fully copy the idea from Voxel Driver." Two research passes
(this session) pulled the exact algorithm and every relevant constant
straight from `core.js`/`main.js` - referenced throughout below by their
exact `core.js:LINE` locations rather than re-derived from scratch.

**Explicitly scoped OUT of this pass** (real scope, not oversights - each is
its own future follow-up):
- Exit gantries, bridges, toll gates/widening, and tunnels - these are
  chapter-type-specific DECORATION systems (real extra geometry: gantry
  signs, overpass structures, toll booth rows, a fully separate tunnel
  tube+ceiling+lighting mesh) layered on top of the curve/grade/bank system,
  not required to get curves/elevation/biomes/particles themselves working.
  Chapters this pass only ever produce two geometric archetypes: `sweeper`
  (curvable+banked) and `plain` (straight, still graded) - matching every
  OTHER original chapter type's actual geometry (per research: `exit`/
  `bridge`/`double-exit`/`bridge-and-exit`/`toll` are ALL geometrically
  straight in the original too, differing only by decorations we're not
  building).
- Fog color / sky color / ambient light changes from biome - research
  explicitly confirmed the original's `BIOME_TABLE` tint does NOT touch
  fog/sky/lighting at all (that's a fully separate day/night/tunnel/weather
  system, `core.js:2877-2918`); only road/shoulder/edge-line/guardrail
  color. Not expanding biome's scope beyond what the original actually does.
- **Vehicle physics/handling/movement - reaffirmed, per explicit user
  instruction, not just an assumption.** `car.gd`/`wheel.gd` (g-rcp2's real
  RigidBody3D controller - engine, drivetrain, raycast suspension, ABS/ESP,
  drifting/yaw feel) stay 100% untouched by this pass, same as every prior
  pass in this project. Nothing in this plan modifies how the player car
  drives - `PathTracker` only READS the car's existing `global_position`
  each frame to estimate progress along the road, exactly like
  `RunRewards`/`crash_system.gd` already read it today; it has no write
  access to the car's motion at all. No movement/handling/physics logic is
  taken from Voxel Driver's three.js source anywhere in this plan - only
  world/road generation (chapters/curves/elevation/biomes) and visual
  effects (particles) are being ported from it, per the project's
  merge-priority split established from the very start of this project
  (Context section, top of this file). Traffic-vs-player collision physics
  (a traffic car reacting when bumped) is ALREADY DONE (the earlier
  "real RigidBody3D physics for traffic" pass) - not part of this plan,
  just confirming it's already live. Cockpit yaw-lag camera tuning is
  explicitly deferred to a later pass, not part of this one either.

### The central technical problem: "distance along the road" for a free car
The original's player movement is a simplified gear-boundary speed model -
`player.dist` is just an accumulated scalar (`dist += speed*dt`), and the
player's actual world position is ALWAYS `worldPos(dist, steeringOffset)` -
i.e. the car is mathematically locked to the track, only free to slide
laterally. This project's player is a REAL RigidBody3D (the whole reason
g-rcp2 was chosen) - genuinely free-roaming 3D physics, can spin, drift
sideways, end up anywhere near the ribbon. Once the road curves, "distance
along the road" stops being interchangeable with `global_position.z` (true
today only because the road is currently straight and dist IS z) - it
becomes a real nearest-point-on-curve problem.

This ripples further than just the road mesh: `traffic_manager.gd`'s entire
lane-following model (`t.dist`/`t.x_frac` -> world position), `crash_system.gd`'s
proximity checks (already reads real `global_position` post the traffic-
physics work - already curve-safe), `RunRewards.current_distance` (currently
`car.global_position.z - _start_z`), and `run_reset.gd`/`road_generator.gd`'s
chunk-window logic (currently keyed on raw Z) all currently assume dist==z.

**Approach**: add a `PathTracker` (new, e.g. `MAIN/road/path_tracker.gd`) that
maintains the player's `dist` as an incrementally-updated nearest-point
estimate - each physics frame, search a small window of the path array
around the PREVIOUS frame's dist estimate (not a full scan) for the closest
point to the player's current world position, matching how curved-track
racers commonly estimate progress for a freely-moving car. This becomes the
new single source of truth for "player's dist" - `RunRewards`,
`TrafficManager`, `RoadGenerator`'s chunk window, and `RunReset` all switch
from reading `car.global_position.z` directly to reading `PathTracker.dist`.

### Data model: RoadPath (new, e.g. `MAIN/road/road_path.gd`)
A precomputed, lightweight point array - mirrors the original's own `path[]`
+ `getFrame()`/`worldPos()` (`core.js:1048-1288`, `1594-1626`), generated
ONCE per run (not per-chunk-on-demand): the original's own self-intersection
retry logic and running state (heading/bank/grade cursor/sweeper direction
alternation/`distSinceSweeper`) are inherently sequential - can't be
regenerated for an arbitrary future chunk without first knowing everything
before it. A full run's worth of points (matching the original's own
`TOTAL_LENGTH=60000` three.js units * `UNIT_SCALE` ≈ 196,000 units, spaced
every `SEG_LEN=14*UNIT_SCALE`) is only ~4,300 points of a few floats each -
trivially cheap to keep resident even though the actual 3D chunk MESHES stay
windowed/freed exactly as today. This is the same separation the original
itself uses (`path` array vs. `buildRoadMesh`'s windowed draw-range), just
adapted to this project's per-chunk `StaticBody3D` streaming instead of
draw-range windowing on one giant mesh.

Ported faithfully from research (constants converted through `UNIT_SCALE`
where they're three.js-native lengths):
- Chapter loop: `sweeper` scheduled by distance (`SWEEPER_INTERVAL`), `plain`
  otherwise (the "type" pool collapses to just these 2 geometric archetypes
  per the scope note above). Chapter length randomized per `lenMin`/`lenMax`
  (using `plain`'s own range, since that's the only remaining non-sweeper
  entry).
- Curvable (sweeper) chapters: smoothstep ease-in/hold/ease-out envelope on
  `dH` per step, layered organic noise (`buildNoiseTrack` equivalent),
  hard-clamped to `CURVE_MAX_DHEADING`. **Banking sign convention** verified
  against the original's own documented past bug (`core.js:1211-1219` -
  "negated... banked every curve backwards") - `bank = dH * BANK_PER_RATE`,
  positive bank raises the outside edge on a left turn. Must re-verify this
  sign against Godot's own coordinate/rotation handedness before assuming
  the three.js sign carries over directly - this is exactly the kind of
  thing worth a headless numeric check before trusting it.
- Grade (elevation): applied to EVERY chapter (sweeper and plain alike,
  deliberately decoupled from curvature per the original's own design
  comment), smoothstep-eased in per chapter from a carried-over grade
  cursor, damped while turning hard (`CURVE_GRADE_TRADEOFF`), soft-capped
  total elevation (`ELEVATION_SOFT_CAP`) to bias back toward 0 over time.
- Self-intersection avoidance + NaN guards: ported faithfully (spatial-hash
  proximity check against earlier committed points, retry with loosened
  curve/length, finite-value validation on every point, forced-straight
  last-resort fallback) - research flagged this exact subsystem as the
  source of a real, still-unconfirmed-root-cause NaN bug in the original,
  so the defensive validation is worth keeping even in a fresh
  implementation, not just the happy path.
- `road_frame(dist) -> {pos, heading, bank, curvature}`: linear interpolation
  between the two bracketing precomputed points (matching `getFrame`, not a
  spline re-evaluation). `world_pos(dist, lateral) -> Vector3`: the banked
  cross-section transform (`worldPos`'s `cos(bank)`/`sin(bank)` split).

### RoadGenerator changes (`MAIN/road/road_generator.gd`)
- Ribbon/mesh building (`_build_ribbon_mesh`, fence, lane dashes, roadside
  bands) resamples `RoadPath.world_pos(dist, lateral)` per row across each
  chunk's span instead of the current flat `Vector3(x, 0, z)` math - same
  banked-transform-per-row technique as the original's `buildRoadMesh`/
  `buildFlatRibbon`. Preserve the researched nuance that wide OUTER bands
  (the far ground strip) should NOT roll with bank on their outer edge
  (only the inner edge shared with the next-in band) - a wide flat band
  banking fully would visibly warp far off the road surface.
- Buildings/streetlights/guardrails: position via `world_pos(dist, lateral)`
  (Y follows the banked height) but rotate ONLY to `heading` - no roll from
  bank on individual props, matching the researched pattern exactly (this
  is the exact bug class this project has hit before with AABB/transform
  composition - easy to get subtly wrong, so following the original's own
  already-debugged convention directly rather than re-deriving it).
- Chunk window (`_sync_chunks_to`) switches from comparing raw
  `car.global_position.z` to `PathTracker.dist`.
- `reset_chunks()` (already exists, from the run-reset work) also
  regenerates a fresh `RoadPath` with a new random seed - this is what
  makes the curve/grade/biome layout genuinely different each run, same
  randomization infrastructure just added for buildings/traffic.

### Biome tinting
Port `BIOME_TABLE` (6 zones, `city/blossom/night/blackout/thaw/snow`, fixed
absolute `BIOME_LEN` distances, tint colors, particle preset names) and
`biome_tint_at(dist)` (smoothstep cross-fade over the boundary transition
distance) directly. Applied as a color lerp onto the ribbon mesh's existing
per-vertex color data (road/shoulder already vertex-colored today) and onto
guardrail/streetlight-pole materials - narrow, exactly matching the
original's own actual scope (confirmed via research, not fog/sky/light).

### Particle effects (rain + ambient biome particles)
Both ported as custom script-driven systems (matching this project's own
established pattern for bespoke particle needs - `trail_sm.gd`'s custom
`ImmediateMesh` tyre trail is the same idiom already in this codebase),
NOT Godot's built-in `CPUParticles3D`/`GPUParticles3D` - research flagged
the original's core technique (a local-space volume recentered to the
player every frame, individual particles streamed backward by SUBTRACTING
the player's actual speed from a local-forward offset, not just letting a
fixed emitter carry them along) as important to replicate faithfully, and
built-in particle systems aren't naturally shaped for that exact behavior.
- **Rain** (`MAIN/misc/weather/rain_streaks.gd`, new): ~260 short line
  segments (Godot: a `MultiMeshInstance3D` of thin stretched quads, or an
  `ImmediateMesh` with `PRIMITIVE_LINES`), volume/recycle/fall-speed
  constants ported directly. Driven by a weather-event state machine
  (`rainT` ramping 0..1, random per-run rolls gated by
  `SaveData`'s existing `rainAmount` difficulty tier - already modeled,
  just never consumed by anything yet) - NOT tied to biome, matching the
  original exactly (can rain in any biome).
- **Ambient biome particles** (`MAIN/misc/weather/ambient_particles.gd`,
  new): one `MultiMeshInstance3D` sized for the largest preset, re-themed
  (color/size/fall-speed/drift/recycle-count) on biome change via
  `visible_instance_count`-style partial use rather than reallocating.
  Always running (never fully off, just re-themed), unlike rain. The 6
  presets (dust/petals/fireflies/ash/mist/snow) ported with their exact
  counts/colors/speeds/drift, including the researched distinction that
  ambient particles re-roll to a RANDOM height on recycle (not a fixed
  top-reset like rain) specifically to avoid reading as "raining from a
  single line."
- Both use the same real-work-saving pattern from research: early-out
  entirely (skip the per-particle loop) while invisible/inactive, matching
  `updateRain`'s own `rainT<=0.001` early return.

### Reconciling traffic/crash/scoring with real dist
- `RunRewards.current_distance`: switch from `car.global_position.z -
  _start_z` to `PathTracker.dist - _start_dist`.
- `TrafficManager`: `_render_car`-equivalent placement
  (`_drive_following`'s `desired_pos`) switches from
  `Vector3(x_frac*ROAD_HALF_WIDTH, y, dist)` to
  `RoadPath.world_pos(dist, x_frac*ROAD_HALF_WIDTH)`, and yaw target
  becomes `road_frame(dist).heading + lane_yaw_offset` instead of the
  current flat `PI + lane_yaw_offset`. Gap-following/spawn-placement math
  itself (`_required_center`, `_lane_clear_at`, `_gap_lane_for_dist`) stays
  entirely `dist`-based (1D arc-length math), genuinely unaffected by
  curvature - this is exactly why the original's own `dist`-based traffic
  model still ports cleanly even onto a curving road.
- `crash_system.gd`: already reads real `global_position` (from the earlier
  traffic-physics fix) - curve-safe already, no change needed there.
- `run_reset.gd`: car's spawn transform reset stays as today (teleport to
  the authored spawn point, which is always dist=0 on the fresh path
  anyway); road/traffic reset calls already route through
  `reset_chunks()`/`reset_traffic()`, which will now also pick up the fresh
  `RoadPath`.

### Files touched
- New: `MAIN/road/road_path.gd` (chapter/curve/bank/grade generator +
  `road_frame`/`world_pos` sampling API), `MAIN/road/path_tracker.gd`
  (nearest-point player-dist estimator), `MAIN/misc/weather/rain_streaks.gd`,
  `MAIN/misc/weather/ambient_particles.gd`.
- Modified: `MAIN/road/road_generator.gd` (ribbon/decoration positioning,
  biome tinting, chunk window keyed on `PathTracker.dist`), `MAIN/traffic/
  traffic_manager.gd` (`_drive_following` curved placement), `MISC/
  autoload/run_rewards.gd` (`current_distance` via `PathTracker`).
- Untouched: `crash_system.gd`, `RoadMetrics` (lane math is still valid 1D
  arc-length math, doesn't change), the traffic AI's gap/lane-change logic.

### Build order (each independently verifiable before the next)
1. `RoadPath` generator + `road_frame`/`world_pos`, headless-verified in
   isolation (no visual changes yet) - generate a path, check curvature/
   bank/grade values are sane and bounded, self-intersection guard actually
   rejects/retries a forced-colliding scenario, no NaN ever escapes.
2. `PathTracker`, headless-verified against a scripted car path (confirm it
   tracks correctly through a curve, doesn't get stuck/lost).
3. `RoadGenerator` ribbon/decoration curving - verify visually AND
   numerically (measured road width stays constant across a curve, banked
   cross-section math matches `world_pos` exactly, buildings/streetlights
   stay yaw-only not rolled).
4. Traffic/RunRewards dist reconciliation - verify traffic still follows
   correctly around a curve (no lane-math regressions - this project has a
   documented history here, re-run the existing torture test afterward).
5. Biome tinting - verify color lerp values at zone boundaries/centers
   numerically.
6. Rain + ambient particles - verify recycle/volume/streaming logic
   headless (particle position stats over time), then visually.

### Verification
Same headless pattern used throughout this session (`_verify_*.tscn`/`.gd`,
always cleaned up after) at each build-order stage above, plus a final
full-world smoke load and an extended sustained-driving torture test
(matching the one already used for the traffic system) to confirm no
regressions in spawn/recycle/gap-following once the road actually curves.

## Verification
Manual play-testing in the Godot editor (F5) after each sub-step in
`C:\My Projects\Godot Voxel Driver` — no browser/headless automation (that
restriction is specific to the three.js `Voxel Driver` project, not
applicable here, but there's likewise no Godot test-automation setup, so
this stays manual). Per sub-step:
- 3a: confirm `SaveData` values persist across a run of the game (edit a
  field, quit, relaunch, check it survived) before building UI on it.
- 3b: drive in cockpit view, do a fast spin/flick and confirm the view lags
  and re-syncs smoothly (no snapping, no unbounded drift) and the interior
  stays visually glued to the dash/wheel — compare feel against the original
  in `Voxel Driver` (`index.html` → cockpit/first-person view) side by side.
- 3c-3f: each screen reachable via its real trigger (start button, pause key,
  a scripted crash) and showing live/correct data from the car instance and
  `SaveData`.

## Audio Config panel + traffic collision-mask jitter fix
Two follow-up requests after the curves/banking/collision work above landed.

### Audio Config panel (done)
User: engine sound too loud, wanted a volume slider defaulting to 30%, then
noted the tyre screech wasn't covered either.
- **New setting** `misc_graphics_settings.engine_volume` (autoload
  `MISC/autoload/graphics.gd`), default `0.3`. `MAIN/misc/engine sound/
  crossfade.gd`'s per-instance `overall_volume` export is now multiplied by
  it (`volume*(overall_volume*misc_graphics_settings.engine_volume)`).
- **New setting** `misc_graphics_settings.tyre_volume`, default `1.0`
  (unchanged loudness - only engine was reported too loud, this was just
  never exposed at all). Multiplied into both output lines of `MAIN/misc/
  tyre sounds/tyres.gd`'s `_physics_process` (the `dirt` sound and the main
  skid/roll/peel blend).
- **New "Audio Config" panel** in the debug gear-menu (`MISC/debugger.tscn`,
  same dialog pattern as Graphics/Control Config - a `Control` with
  background/scroll/container, one `HSlider` per setting using the existing
  reusable `MISC/controls config/slider_variables.gd` `var_name` binder, a
  `CloseButton`), new tiny script `MISC/audio_config/audio_config.gd`
  (mirrors `graphics config.gd`'s sync-children-each-frame pattern). Two
  sliders: "Engine Volume" (30% default) and "Tyre Screech Volume" (100%
  default). Wired into `MenuList` alongside the other 5 dialogs.
Verified headless: slider inits to 0.3, dragging it writes through to the
autoload, and the real `crossfade.gd` node's actual output `volume_db`
measurably increases when the setting is raised (not just that the number
changed).
**Not yet covered by any slider**: mechanical/backfire sounds
(`MAIN/misc/mechanical sounds/other_sounds.gd`) - never asked about, likely
fine as-is, flagged here only so it's not forgotten if raised later.

### Traffic vibration on curved/banked road - FIXED (root cause + fix confirmed by user)
User reported traffic NPCs violently vibrating specifically on curved/tilted
road sections, suspected "have it follow the road, not the colliders."
That suspicion was exactly right:
- **Root cause**: traffic cars are real `RigidBody3D`s (from the earlier
  "traffic physics" work) that are purely AI/velocity-steered while
  `FOLLOWING` (gravity_scale=0, no suspension model - `_drive_following()`
  in `traffic_manager.gd` sets `linear_velocity`/`angular_velocity` toward
  the AI's `dist`/`x_frac`-implied position every physics frame). Their
  `NORMAL_MASK` was `1` - the default layer - which the road's ground/
  guardrail `StaticBody3D` collision (`road_generator.gd`'s per-row
  `ConvexPolygonShape3D`, built for the earlier staircase-collision fix)
  ALSO defaults to. So every FOLLOWING traffic car was physically colliding
  with the road surface every frame. On curved/banked sections the per-row
  convex geometry has small kinks between rows (linear interpolation, not a
  smooth curve) - real physics kept nudging the car out of penetration
  against those kinks while the AI simultaneously steered it back onto the
  smooth interpolated path. That fight was the vibration.
- **Fix**: gave the player car a second, dedicated collision-layer bit
  (`base car.tscn`'s `car` node: `collision_layer = 3`, i.e. `1|2` - keeps
  its existing layer-1 membership, used by literally nothing else so this
  is purely additive) and pointed traffic's `NORMAL_MASK` at ONLY that new
  bit (`MAIN/traffic/traffic_car.gd`: `const PLAYER_LAYER := 1 << 1`,
  `const NORMAL_MASK := PLAYER_LAYER`). `KNOCKED_MASK` unchanged in effect
  (`1 | PLAYER_LAYER | TRAFFIC_COLLISION_LAYER` - still collides with world
  geometry once real physics genuinely takes over on a hit). `TrafficCar.tscn`'s
  authored default `collision_mask` updated from `1` to `2` to match.
  **User confirmed in-game: position jitter is gone, traffic is smooth
  again.**

### NEW, still-open issue: traffic NPC visual "angle" looks wrong (NOT yet root-caused)
Immediately after confirming the jitter fix, user sent screenshots (Debug ->
Visible Collision Shapes on) and said the NPCs' *angle* still looks off -
their own words: "it might be a bit deep in the actual movement of the npcs
themselves and it was fighting whatever fix we did earlier that caused the
jitter." In the screenshot, traffic cars' wireframe collision boxes appear
visually skewed/diagonal relative to their own car body mesh, on a curved/
banked section at night (also visible on the player's own car in frame,
though that one is `car.gd`'s pre-existing hull collision, unrelated to
anything touched this session - not the focus).

**Investigation was cut off mid-analysis, no conclusion reached, nothing
changed yet.** What's confirmed/ruled out so far vs. what's still open:
- The traffic collision box (`MAIN/traffic/traffic_car.gd`'s `_setup_collision()`,
  a plain `BoxShape3D` under a `CollisionShape3D` with NO explicit rotation
  of its own) is a direct child of the `RigidBody3D` traffic car itself, as
  is the visual hull mesh (`_hull`, also a child, with its own fixed local
  `rotation.y = PI` flip applied once in `setup_visual()`). Structurally
  both inherit the SAME parent `global_transform` - a symmetric box's look
  is unaffected by a 180° yaw flip, so on paper box and hull should always
  render in visual agreement; I was not able to find a code path that
  rotates one independently of the other before being interrupted.
- The real per-frame orientation control is `traffic_manager.gd`'s
  `_drive_following()` -> `t.angular_velocity = _angular_velocity_toward(t,
  _desired_basis(f, t.lane_yaw_offset), delta)` - this computes yaw (road
  heading + lane_yaw_offset) AND roll (road bank) together via a quaternion
  delta, and hands it to the physics engine as an angular velocity (NOT a
  direct teleport - only spawn/recycle in `_render_car()` sets `t.basis`
  directly). `_angular_velocity_toward()` has NO clamp on the resulting
  angular speed (`delta_q.get_axis() * (angle / delta)`) - unlike
  `_drive_following`'s linear velocity counterpart, there's no cap here, so
  in principle a large orientation error in one frame (e.g. right after
  `resume_following()` clears state post-KNOCKED/WRECKED, or a sudden bank
  change between rows) could produce a very large one-frame angular
  velocity request - NOT yet confirmed as the actual cause, just the most
  suspicious candidate found before the investigation was interrupted.
- Also not yet checked: whether the physics engine's actual per-substep
  integration of that angular velocity can meaningfully lag behind the
  AI's instantaneously-recomputed target basis every frame (unlike linear
  position, which visibly converged fine per earlier verification),
  producing a persistent small visible rotational offset rather than a
  one-frame spike - this is the other live hypothesis and hasn't been
  distinguished from the clamp theory yet.
- User's own instinct ("fighting whatever fix we did earlier") suggests
  they suspect this is a second symptom of the SAME collision-mask
  conflict rather than something new - worth checking directly (e.g. does
  the angle glitch correlate with rows/segments, or with proximity to other
  traffic/guardrails) before assuming it's a fresh bug in the angular math.

### Traffic NPC angle bug - ROOT CAUSED AND FIXED (corrected diagnosis)
First pass (below, kept for the record) diagnosed and fixed a REAL but
secondary bug (a quaternion double-cover spike). User then corrected the
diagnosis after seeing it: the actual complaint was that the traffic car's
**roll axis doesn't line up with the road's current roll** - a persistent
geometric mismatch, not an occasional spike. That pointed at a bug in what
`_desired_basis()` was TARGETING, not in how well physics tracked that
target - which the first diagnostic couldn't have caught, since it only
ever compared the real physics basis against `_desired_basis()`'s own
output (comparing the target against itself proves nothing about whether
the target is geometrically correct).

**Real root cause**: `_desired_basis()` built `Basis(Vector3.UP, heading +
PI + lane_yaw_offset)` THEN rolled by `bank` around THAT basis's own local Z
axis (`b.rotated(b.z, bank)`). The `+PI` (needed for this pack's hull-facing
convention, already verified correct on flat roads) means that local Z axis
points at the road's BACKWARD direction, not forward. Rotating around the
backward axis by `+bank` is the same as rotating by `-bank` around the true
forward axis - so the car's roll was inverted relative to
`RoadPath.world_pos()`'s own banked cross-section (the thing the visual mesh
and ground collision actually follow), landing exactly 2x the bank angle
away from the true road-surface tilt on every banked section, all the time -
not a spike, a systematic wrong-direction roll, precisely matching what the
user described.

**Verified via 3 standalone headless numeric checks (no scene load needed,
pure math) before touching game code**, per the project's own established
"research/verify before changing anything" pattern:
1. Confirmed `Basis(x,y,z)`'s constructor semantics (columns, as assumed)
   and that `Basis.rotated(axis, angle)` treats `axis` as a world-space
   vector (`base.rotated(base.z, angle)` leaves `base.z` itself unchanged,
   as expected for rotating something around itself).
2. Compared the OLD formula's resulting UP vector against the TRUE
   road-surface up vector (derived independently, directly from
   `world_pos()`'s own `right0*cos(bank)+up0*sin(bank)` /
   `-right0*sin(bank)+up0*cos(bank)` cross-section rotation, not from
   `_desired_basis()` at all) across several heading/bank combinations:
   old formula's up vector was off by exactly 2x the bank angle every time
   (e.g. 20.626 deg misaligned on a -10.313 deg bank, 16.0 deg on an 8 deg
   bank) - confirming the sign-inverted-roll theory numerically, not just
   by derivation.
3. Confirmed a candidate fix (below) matches the OLD formula EXACTLY at
   bank=0 (the already-verified, already-shipped flat-road/turn-signal
   behavor stays byte-for-byte unaffected - only the bank=0 case was ever
   exercised by prior verification work) and lands at 0.000 deg
   misalignment (vs. the true road-surface up) at every nonzero bank tested.

**Fix** (`_desired_basis()`, `traffic_manager.gd`): build the banked ROAD
frame first, from the raw heading/bank alone - `right_b`/`up_b` computed
with the EXACT SAME rotation `world_pos()` itself uses, so this rolls in
lockstep with the visual mesh/ground collision by construction - then apply
the `PI + lane_yaw_offset` yaw as a separate rotation about that banked
frame's own local Y axis (`banked_basis * Basis(UP, PI+lane_yaw_offset)`,
post-multiply = "yaw happens in the already-banked frame", so it can't
disturb the roll alignment established by the first step).

**End-to-end verification** in the real `world.tscn` (not just standalone
math): a headless diagnostic sampled every FOLLOWING traffic car's REAL
physics up-vector against the independently-derived true road-surface up
vector (deliberately NOT against `_desired_basis()`, to avoid the same
"comparing a thing against itself" mistake as the first pass) across 900
physics frames (~15 simulated seconds) through the curved/banked first
sweeper chapter - 30,485 banked-section samples, mean misalignment 0.0531
deg, max 0.2515 deg (down from a systematic ~2x-bank-angle error before the
fix - e.g. it would have read ~20+ deg on the same section).

### (Superseded) first-pass fix: quaternion double-cover guard - kept, still correct
Before the diagnosis above, a headless diagnostic comparing
`t.global_transform.basis` against `_desired_basis()`'s own output (an
insufficient comparison for THIS bug, but a legitimate check for a
DIFFERENT one) caught a real, separate issue: `_angular_velocity_toward()`'s
`get_rotation_quaternion()` calls can independently return either `q` or
`-q` for the current vs. desired basis (both represent the identical
rotation) - when they land on opposite hemispheres, `desired_q *
current_q.inverse()` comes out as the "long way around" (angle near 2*PI
instead of near the true small tracking error), and its axis extraction
becomes numerically unstable, producing an occasional huge one-frame
angular-velocity spike. Fixed with a standard hemisphere guard (`if
current_q.dot(desired_q) < 0.0: desired_q = -desired_q` before
differencing) - this fix is real, still in place, and unrelated to the
roll-axis bug above (both needed fixing; neither fix subsumes the other).

## Ground collision switched to trimesh (re-tested, no longer avoided)
User asked to just try the trimesh collider again, since the Godot bug it
was avoided for (godotengine/godot#100539) is from 2024 and might be fixed
by now. Checked properly rather than guessing:
- `gh issue view 100539` - still OPEN upstream (last updated Jan 2025), no
  fix landed. One comment: switching the whole project to the Jolt physics
  backend fixes it for that reporter - Jolt became available as a built-in
  alternative in 4.4, but this project explicitly configures
  `physics/3d/physics_engine="GodotPhysics3D"` (`project.godot`) and stays
  on it - swapping backends project-wide is a much bigger, riskier change
  (would affect car.gd/wheel.gd's whole tuned solver behavior) than
  justified for a road-smoothness cosmetic question, so that workaround
  doesn't apply here.
- Instead of trusting the tracker alone, ran a direct headless test against
  THIS project's actual engine build (4.7.2) and actual configured backend
  (GodotPhysics3D): built a ribbon mesh with the exact same
  SurfaceTool/PRIMITIVE_TRIANGLES technique `_build_ribbon_mesh` uses (a
  real curved+banked ~6000-unit stretch from `RoadPath`), gave it trimesh
  collision via `create_trimesh_shape()`, then fired 1300 raycasts straight
  down across it (row seams AND row midpoints, 5 lateral positions each,
  matching exactly where #100539 would be expected to bite). Result: **0
  missed raycasts**. A ~9% "wrong height" rate at row midpoints (up to 0.31
  units off) looked concerning until a control test - the identical
  technique on a trivially FLAT/planar quad - came back at 0 error in an
  isolated process (no shared physics-space contamination between test
  runs, confirmed by rerunning in fully separate `godot -s` invocations).
  That proves the "wrong height" readings weren't a RayCast3D/trimesh
  reliability bug at all - just the ordinary approximation error of
  triangulating a non-planar (curved+banked) quad along a single diagonal,
  the exact same faceting this whole smoothness conversation is about,
  equally present in the OLD per-row convex shapes (not something trimesh
  introduced).
- **Switched** (`road_generator.gd`'s `_build_collision`): ground collision
  is now ONE `ConcavePolygonShape3D` per chunk (built from the same
  per-row corner points as before, just as one trimesh instead of `rows`
  separate `ConvexPolygonShape3D`s) instead of a flat-bottomed convex slab
  per row - removed the now-dead `GROUND_THICKNESS` constant (a trimesh
  surface has no meaningful thickness, and doesn't need one for a
  downward-only wheel raycast). Guardrail walls are UNCHANGED - still
  separate per-row `ConvexPolygonShape3D` boxes (simple vertical stoppers,
  no curvature-smoothness need, not worth folding into the ground trimesh).
  This does NOT by itself fix the bumpy feel (the trimesh still uses the
  exact same per-`SEG_LEN`-row corner points and diagonal-split
  triangulation as before - same facet size), but it does remove the
  earlier hard architectural block on ever combining trimesh with finer/
  smooth-interpolated geometry later (see the still-open smoothness section
  below), since a single trimesh scales far better to many more, smaller
  triangles than one discrete convex shape per micro-segment would.
- **Re-verified end-to-end in the real `world.tscn`** (not just the
  standalone geometry test): teleported the player car to a real
  curved/banked dist (~2600, bank ~-10 deg) a few units above the surface
  and let REAL physics settle it for 7 simulated seconds (not a forced
  velocity override - tried that first and it fought wheel.gd's own force
  integration, producing meaningless garbage; teleport-then-settle is the
  correct/established pattern this project has used throughout). Result:
  late-window (last simulated second) Y spread of 0.187 units, max
  single-frame Y jump 0.095 - small, bounded, consistent with prior
  settling tolerances elsewhere in this project. Repeated exactly at a
  CHUNK_LENGTH boundary (where two independently-built chunk trimeshes
  meet) specifically to catch any seam mismatch: late-window spread dropped
  to 0.003 units, same small max jump - no seam gap or overlap.
- **Not yet re-tested**: the earlier "20/20 raycasts hit correctly"
  convex-shape verification and the "0.018 units of Y drift over 10s of
  real driving" full-world smoke test from the original staircase-collision
  fix were about the PREVIOUS (convex) shape - worth a similar full real-
  driving (not just teleport-and-settle) pass next time this area is
  touched, though the teleport-and-settle results above are consistent with
  no regression.

## Road smoothness: subdivided/smoother mesh (still not started - separate from the trimesh switch above)
User feedback after the angle fix: the road itself still feels "a bit
bumpy" even with the real-corner-point `ConvexPolygonShape3D` collision fix
from the earlier "staircased collision" pass - asked about switching to a
smoother, more subdivided mesh instead.
**Not yet investigated or implemented this session** - real next-session
work. Starting context for whoever picks this up: `road_generator.gd`
currently builds exactly one mesh/collision row per `RoadPath.SEG_LEN`
(45.8 units, `CHUNK_LENGTH` divided into `rows = CHUNK_LENGTH/SEG_LEN = 8`
rows per chunk) - both the VISUAL ribbon (`_build_ribbon_mesh`, flat-shaded
triangles between consecutive path rows) and the COLLISION
(`_build_collision`, one `ConvexPolygonShape3D` per row) sample `RoadPath`
at that same fixed spacing, so any curvature/bank/grade change between two
adjacent path points is a straight-line (faceted) interpolation, not a
smooth curve - this is the literal source of the "bumpy" feel, distinct from
(and on top of) the earlier staircase bug (which was about the collision
being flat-yaw boxes that didn't follow bank/grade AT ALL, already fixed).
Two independent angles worth investigating before picking one:
- **CORRECTION to this section's original write-up**: "just call
  `road_frame()`/`world_pos()` more times per chunk without changing
  `RoadPath` itself" (originally proposed here as the cheap option) is
  actually a NO-OP, not a cheap partial win - caught and explained to the
  user before implementing anything. `road_frame(dist)` LINEARLY
  interpolates between two already-stored `RoadPath` points; sampling more
  points strictly BETWEEN the same two stored points just lands more
  samples on the exact same straight chord (same flat facet, cut into more
  redundant coplanar triangles) - zero smoothness gained, for real added
  triangle/collision-shape cost. There are only two approaches that
  actually change the geometry's fidelity:
  - **(a) Increase `RoadPath`'s own resolution** - shrink `SEG_LEN` (and
    proportionally scale the per-step curvature/bank/grade-rate constants
    so the real curve shape is unchanged, just represented with more,
    shorter straight segments approximating it more closely). Genuinely
    smoother, but more stored path points and more collision triangles
    (linear cost increase), and touches tuning constants throughout
    `road_path.gd`.
  - **(b) Change the RECONSTRUCTION between existing stored points** from a
    straight-line lerp to a curved one (e.g. a constant-curvature circular
    arc per segment, using the curvature already tracked/derivable from
    consecutive headings) - no extra stored data, `road_frame()`/
    `world_pos()` get a bit more math per call, but no extra triangle/
    collision-shape count needed. This is the more efficient AND more
    correct fix - it targets the actual cause (linear interpolation of a
    curve) rather than averaging over the symptom.
  (b) is the recommended direction. Both are now viable to combine with the
  trimesh ground collision (see the section above) - a single
  `ConcavePolygonShape3D` per chunk scales far better to more/smaller
  triangles than the old one-`ConvexPolygonShape3D`-per-row approach would
  have, which was part of the motivation for re-testing and switching to
  trimesh now rather than later.
Whichever approach is picked, must re-verify (same pattern as every prior
road-collision change in this project): banking direction still correct,
road width constant across a curve, no staircase regression, and the
player's raycast suspension still settles smoothly (rock-stable Y, no
jitter) - this project has hit subtle regressions in exactly this area
multiple times before (the original staircase bug, the traffic vibration/
collision-mask bug, and the traffic roll-axis bug), so re-verify
numerically, not just by eye.

## Road smoothness: Hermite-spline road_frame() + subdivided sampling - DONE
Implemented option (b) from the section above (curved reconstruction between
existing `RoadPath` points, not just denser sampling of a straight lerp).

**`road_path.gd` changes**:
- New `grades` `PackedFloat32Array` (parallel to `xs`/`ys`/`zs`/`headings`/
  `banks`) - the EXACT per-step vertical slope (`grade*grade_scale`, the
  same value already used to accumulate `y` during generation, not the raw
  pre-curve-tradeoff `grade`) at each stored point. Threaded through
  `_build_chapter()`'s point dict and `_generate()`'s commit loop; initial
  point gets `0.0` like the other arrays. Added to the existing finite-value
  guard alongside x/z/y/heading/bank.
- `road_frame(dist)` rewritten from a straight lerp to a **cubic Hermite
  spline** between the two bracketing points, using each point's own
  recorded heading+grade as its EXACT analytic tangent direction (scaled by
  `SEG_LEN`) - `Vector3(sin(heading), grade, cos(heading)) * SEG_LEN`. This
  still passes through both endpoint positions EXACTLY (so every existing
  row/chunk boundary stays perfectly continuous, unchanged from before) but
  now also matches the recorded tangent DIRECTION at each endpoint, giving
  C1 (tangent) continuity instead of the old sharp per-point polyline kink.
  `heading` in the returned frame is now the CURVE's own tangent direction
  at `t` (from the Hermite derivative, `atan2(tangent.x, tangent.z)`) -
  deliberately NOT a separate lerp of the stored heading values, because
  `world_pos()`'s banked cross-section rotates by this `heading` - if it
  didn't match the actual curve tangent exactly, the banked surface would
  twist away from the true direction of travel, the same bug CLASS as the
  traffic roll-axis fix earlier in this session (rolling around the wrong
  axis), just for the road surface itself. `bank` interpolation kept as a
  simple angle lerp (`lerp_angle`) - roll doesn't need position-continuity
  the way heading/position do.
- Correctly identified and avoided a real trap before implementing: the
  ORIGINAL "finer subdivision" idea in the section above was flagged
  (correctly, this session) as a no-op under the OLD straight-lerp
  `road_frame()` - re-sampling a straight chord more times just re-samples
  the same line. That's still true, but ONLY for callers that themselves
  keep sampling at the OLD row granularity - see below.

**`road_generator.gd` changes**: the Hermite spline only matters if
something actually SAMPLES strictly between two stored `RoadPath` points.
Lane dashes/fences already do (their spacing is finer than `SEG_LEN`), so
they benefit for free. The actual drivable surface mesh/collision did NOT -
`_build_ribbon_mesh`/`_build_collision` only ever sampled at row boundaries
(`d0`/`d1`, exactly at stored points), so they would have kept chording
straight across each row even with a genuinely curved `road_frame()`
underneath. New `ROW_SUBDIVISIONS := 4` constant - both builders now sample
`rows * ROW_SUBDIVISIONS` sub-segments (step `SEG_LEN/ROW_SUBDIVISIONS`)
instead of `rows`, so the built ribbon mesh and ground trimesh actually
trace the curve instead of chording across it. This is exactly why the
earlier trimesh switch (single `ConcavePolygonShape3D` per chunk) was worth
doing now rather than later - it scales far better to 4x the triangle count
than one discrete convex shape per micro-segment would have. Guardrail
walls stay at the original row granularity (simple vertical stoppers, no
curvature-smoothness need).

**Verified numerically** (all headless, all throwaway scripts deleted
after use):
1. 20,000-point fine sweep of the whole generated path: 0 non-finite
   values, max bank 10.313 deg (sane, matches `BANK_MAX`).
2. Road width stays constant across curves/banks: max error 0.0126 units
   against a 26.379-unit half-width (negligible) - confirms `world_pos()`'s
   cos(bank)-scaled cross-section still holds under the new position
   formula.
3. Banking direction re-checked against the established convention
   (`+lateral` = car's LEFT, established during the earlier traffic
   roll-axis fix) across 589 sampled turns: 586 correct; the 3 apparent
   mismatches all had `bank_deg=0.0000` exactly (a chapter-boundary
   finite-difference threshold artifact in the TEST's own turn detector,
   not a real directional error - there's no direction to get wrong when
   there's no bank).
4. Confirmed the curve is genuinely smooth now, not just re-sampled: 9
   samples strictly inside a single stored-point-to-stored-point row all
   produced DISTINCT headings (the old lerp would hold heading perfectly
   flat until the exact row boundary, only jumping there).
5. Re-ran the traffic roll-alignment diagnostic from the earlier bug fix
   (real physics up-vector vs. the true road-surface up, independently
   derived) end-to-end in `world.tscn` post-change: 30,485 samples, mean
   0.063 deg / max 0.388 deg misalignment - consistent with the
   pre-existing fix, confirming the curve-tangent-derived heading didn't
   reintroduce the roll-axis bug.
6. Re-ran the player suspension teleport-and-settle stability check (same
   pattern as the trimesh verification) at both a mid-chunk banked dist and
   exactly at a chunk boundary: late-window (last simulated second) Y
   spread of 0.070 and 0.011 units respectively (TIGHTER than the
   pre-Hermite trimesh-only results of 0.187/0.003 - consistent with an
   actually smoother surface, not just no-worse), max single-frame jump
   ~0.10 in both cases (unchanged, small, expected settling noise).
7. Full `world.tscn` smoke test including triggering a real fresh-run reset
   (`GameState` MENU->PLAYING, exercising `reset_chunks()`/`RoadPath`
   regeneration with the new `grades` array) - reached completion with no
   script errors from `road_path.gd`/`road_generator.gd`/
   `traffic_manager.gd` (only pre-existing, unrelated headless-mode noise:
   a null-node warning from `trail_sm.gd`'s tyre marks and standard
   headless-exit resource-leak messages, both present before this change
   too).

## Weight-distribution debug lines still showing in real gameplay - found the real remaining override
User reported the force-vector debug lines (`forces.gd`'s compress/longi/
lateral meshes - what looks like "weight distribution" lines coming off the
wheels) were STILL visible, despite the earlier "Debug lines default-off"
fix already reverting `base car.tscn`'s own `Debug_Mode` override back to
`car.gd`'s coded default (`false`). That earlier fix was real but
incomplete - `world.tscn` (the actual scene the game runs, not `base car
.tscn` in isolation) has its OWN separate scene-level override on the
`car` node instance: `Debug_Mode = true`, re-enabling the exact same thing
for real gameplay. Removed that line - `car` now falls back to `car.gd`'s
own default (`false`), same fix pattern as before, just at the scene that
actually matters for play. Verified headless: loading `world.tscn` now
shows `car.Debug_Mode == false` by default, and manually setting it back to
`true` (same mechanism the existing F-key toggle uses) still works - the
toggle itself is untouched, only the wrong default was removed.

### Next session: suggested starting prompt
> The traffic NPC roll-axis bug, the trimesh ground-collision switch, and
> the road-smoothness (Hermite spline + subdivided sampling) work are all
> DONE and numerically verified this session - see "Traffic NPC angle bug -
> ROOT CAUSED AND FIXED (corrected diagnosis)", "Ground collision switched
> to trimesh", and "Road smoothness: Hermite-spline road_frame() +
> subdivided sampling - DONE" in this file. All verification so far has
> been headless (numeric checks: no NaN, constant road width, correct
> banking direction, traffic roll alignment, suspension settling stability,
> full-scene smoke test with a fresh-run reset) - **nobody has actually
> played this in the Godot editor yet to confirm the road LOOKS and FEELS
> smoother**, which was the original, subjective complaint. Good next step:
> open the project in the editor (or ask the user to play-test) and confirm
> the bumpy feeling is actually resolved; if it still feels bumpy, the
> `ROW_SUBDIVISIONS` constant (`road_generator.gd`, currently 4) is the
> first knob to try raising, and if that's not enough, RoadPath.SEG_LEN
> itself (approach (a) from the smoothness section) is the remaining lever.
> No other open work is queued right now - check with the user for the next
> priority (the recommended build order's remaining items are biome tinting
> and rain/ambient particles - "Stage 5"/"Stage 6" under "Plan: curves,
> elevation/banking, biome tinting, and particle effects" - still not
> started).
> Project is at `C:\My Projects\Godot Voxel Driver` (note: this machine's
> primary working directory may default elsewhere - use the full path).

## Garage customizer: 4 modular Synty cars + Customize screen (implemented 2026-09-27, NOT yet play-tested)
Brief: `KOSOKU_GARAGE_CUSTOMIZER_BRIEF.md`. Garage now lists Sedan_01 /
Sports_01 / Hatch_01 / Muscle_01 (`MAIN/cars/profiles/*_01.tres`); the old
coupe/italia/kamaro `.tres` + GLBs stay on disk, unlisted. The coupe is still
CarConfigurator's physics/geometry reference (`base car.tscn` is built on it).
- Assets: `res://assets/cars/Kosoku_Cars_GLB/` (manifest root, kept where the
  user already put it). 39 paint textures copied into `textures/` with
  VRAM-compressed/mipmapped/2048-capped `.import` settings, plus 256x128
  `textures/thumbs/` (top half of each atlas = the body paint area).
- `CarManifest` (manifest reader, loadout shape + sanitize, presets mapped via
  `conversion_report.json`), `ModularCarBuilder` (base + parts at identity,
  one per-car paint material shared with the wheels, `car_glass.tres` = copy
  of the coupe's opaque mirror `glass.001`, generated lamp lenses).
- Lights: the pack has no light meshes. Lens triangles are found by the two
  atlas swatches every lamp uses (head uv ~(0.005,0.876), tail ~(0.013,0.876))
  and copied into `headlight_L/R` / `rearlight_L/R` nodes, so the unchanged
  `headlight_lights.gd` / `brake_lights.gd` light them like the old hulls.
- Conversion bugs fixed in code (`ModularCarBuilder.PIECE_OFFSETS`): Sedan
  Fenders_02/04 `_Door_L/R` pieces and several spoilers (Sedan 01/02, Sports
  02-04, Hatch 02-04, Muscle 04 + Spoiler_02_Boot) were exported in their
  hinged parent's local space (lost door/boot pivot). Offsets estimated by
  matching edges in software renders - verify in the editor. The Sedan door
  pieces are arch flares ON the rear doors, so stock doors are NOT hidden.
- Wheels: `wheel_hull_mesh.gd` optionally shows Wheel_NN+Tyre_NN scaled to the
  stock wheel radius; shared rims face -X so the LEFT (+X) side is flipped.
- Save: `GarageState.car_loadouts`, `SaveData.get_loadout/set_loadout/
  loadout_changed`; old saves get the new car ids added to `owned_cars`.
- UI: CUSTOMIZE button above CarStatsBlock; `UI/garage/CustomizeScreen.tscn`
  (sub-mode of GARAGE, no new GameState). Camera orbits around editor-placed
  `Viewpoints/cust_*` markers in GaragePreview.tscn; turntable parks the car.
- Manifest JSON added to every export preset's include_filter.
