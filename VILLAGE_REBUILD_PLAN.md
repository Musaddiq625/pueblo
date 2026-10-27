# Village Rebuild Plan — El Pueblo de los Muertos

Status: **planned** (assets staged, verification protocol defined)
Baseline: `8795ef0` — see `STARDEW_RESEARCH.md` for the diagnosis this plan answers.

This plan replaces the procedurally painted stage with a real tilemap village,
fixes the sprite-geometry and dialogue-lifecycle bugs, and gives spirits real
activities (browse / tend / vigil / gossip / stroll) instead of waypoint hops.

---

## 0. Verified assets (already staged)

| Pack | Path | License | Contents we use |
|---|---|---|---|
| Ninja Adventure (Pixel-Boy & AAA) | `assets/sprites/village/ninja_adventure/` | CC0 ([itch page](https://pixel-boy.itch.io/ninja-adventure-asset-pack)) | `tileset_floor.png` terrain autotiles, `tileset_animated.png` water/fire, `tileset_village_abandoned.png` trees/props, `tileset_wall_simple.png`, `crate.png`, `pot.png`, `grass.png` |
| Kenney Tiny Town | `assets/sprites/village/tiny_town/Tiles/` (132 × 16px) | CC0 (`License.txt` staged) | grass/dirt/cobble autotiles, autumn trees, mushrooms, house kit (terracotta+slate roofs, walls, doors, windows), fences, market stall/cart, well, crypt arches, lantern posts, tools, bones, barrels, signs, jars |

License records: `assets/sprites/village/LICENSES.md`.

**Tile grid:** all tiles are 16×16 source px, rendered at 2× → **logical tile = 32 px**.
World becomes **44 × 26 tiles = 1408 × 832 px** (≈ current 1400×820).
Spirits render ~56 px tall ≈ 1.75 tiles — Stardew-proportioned.

**Palette direction (dusk/moonlit):** base ground = dark dirt/grass, streets =
stone autotile, plaza = light cobble, buildings = terracotta + plaster,
marigold orange accents (stall awnings, flower rows, lantern glow). At bake
time, ground tiles get a slight cool-dark grade (multiply ~0.85 × bluish) so the
village reads as *night*, while props/awnings stay warm — this contrast is what
makes Stardew's night scenes work. Tunable via one constant.

---

## 1. Root-cause fixes the plan must land

| # | Bug | Root cause | Fix phase |
|---|---|---|---|
| B1 | Spirits shrink while walking | idle cells 32×32, run cells 64×64 with ~2× padding; both drawn at 56 px | P1 |
| B2 | Dialogue invisible/dropped | `_bubble()` returns early when `c.walking`; speech not coordinated with movement | P4 |
| B3 | `shop(flower_stall)` never resolves | `d.target` looked up as agent id; falls back to stroll | P4 |
| B4 | Spirits talk mid-stride | `pairStart` doesn't cancel walks or require proximity | P4 |
| B5 | Background reads as placeholder | procedural strokes/discs, no authored tile layer | P2+P3 |
| B6 | "Shops" not visited | ambient browse targets POI center, glows only; no slots/dwell | P4 |
| B7 | Trees/edges floating | props not anchored into a bounded tilemap | P3 |
| B8 | Position jump on tap | resolved earlier via engine-side interpolation — keep regression test | P7 |

---

## 2. Phase breakdown

### P0 — Asset staging ✅ DONE (this commit)
- [x] Copy verified tilesets/props into `assets/sprites/village/`
- [x] `LICENSES.md` with source + license per pack
- [x] `pubspec.yaml`: register `assets/sprites/village/` dirs
- [ ] Build `assets/sprites/village/tile_index.dart` — semantic names → Tiny Town
  tile numbers + NA tileset source rects (from the numbered contact sheet:
  `/tmp/tt_grid.png` — index = row×12+col)

### P1 — Sprite contract (fixes B1; independent of the map work)
**Goal:** every character (6 spirits + player) has identical visible height and a
shared foot baseline across idle/run, with zero per-frame jitter.

1. Add dev dep `image: ^4.x` and tool `tool/repack_chars.dart`:
   - For each `*_idle/_run/_walk/_death` sheet: compute per-frame alpha bbox →
     **union bbox per animation** → crop every frame to that union rect →
     place onto a new fixed cell `CW×CH` (per character, foot-anchored:
     baseline at `CH-2`), same `CW×CH` for *all* anims of that character.
   - Emit `assets/sprites/chars_norm/<name>_<anim>.png` + generated
     `lib/game/chars_norm_manifest.g.dart` (`cellW, cellH, frames, stepTime, footY`).
   - Union-rect cropping (not per-frame bbox) preserves walk-cycle bob — the
     offset differences between frames are intentional animation.
2. `sprites_manifest.dart` reads generated defs; `SpiritComponent` uses fixed
   `size`/`anchor` for all sheets — shrink bug impossible by construction.
3. Player `knight_*` gets the same treatment.
4. Keep original PNGs untouched (regenerate anytime with `dart run tool/repack_chars.dart`).

**Accept:** unit test asserts all chars' union-bbox heights within ±2 px and
equal foot baseline; burst montage shows constant height walking↔idle.

### P2 — Tilemap engine (replaces `GroundComponent`)
1. `lib/game/tilemap.dart` — pure Dart:
   - `VillageMap` from **ASCII-art rows** in `world_map.dart` (readable, diffable,
     unit-testable — no external editor dependency):
     ```
     w w w w w w w w b b w w w ...   (river + bridge)
     d d d d s s s s s s d d d ...
     ```
     Symbols → terrain kind + prop id + walkable flag.
   - `autotile(neighbors) → tileIndex` — 47-blob/Wang bitmask over
     `tileset_floor.png` (dirt/stone/water) and Tiny Town grass/dirt/cobble
     transitions; deterministic, table-tested.
   - Emits: `ground` tile grid, `props` list (tile index + cell + layer +
     footY), `walkable` bitmask, `slots` (stand positions + facing per POI),
     `colliders` (rect list for tap/hit-test).
2. `TilemapPainter` — bakes ground+decal layers into ONE `Image` at load
   (~2.3k drawImage ops once, cached) → single low-priority component. No
   per-frame tile drawing.
3. Prop pieces (tree canopies, roofs, awnings, crypt arches) become
   `SpriteComponent`s with `priority = footY`-based ordering, sharing the
   actor y-sort (see P5).

**Accept:** map parse test + walkability test (all slots reachable, all spawns
walkable, no prop on a street tile); burst shows coherent ground/paths.

### P3 — Village layout (the actual town design)
Zones on the 44×26 grid (concrete ASCII map lands in `world_map.dart`):

```
N:  river + marigold bridge (player entrance, existing spawn)
NE: cemetery lane — crypt arch, grave rows, bone piles, fence
E:  market row — flower stall tent, curiosity shop hut, lantern posts
SE: the Old Ceiba (big tree over the path) + candle cluster
S:  ofrenda wall — 3 tiers, photo frames, candle rows, marigold ring
SW: plaza south benches + cart
W:  cantina "La Catrina Feliz" (terracotta house + sign) + alchemy table
NW: gravedigger's hut + tool props
C:  plaza — fountain (well base + animated water), cobble disc, papel picado
```

- All POIs keep their ids; each gets 1–3 **activity slots** (tile + facing,
  e.g. in front of counters, beside graves, around the fountain rim).
- Every zone walkable-connected; props only on non-street tiles.
- Custom pixel props drawn where packs lack them (small task, simple shapes):
  marigold flower rows, photo frames, papel picado flags (already drawn).

**Accept:** every POI visual reads as the named thing at a glance; spirits have
free slots to stand at.

### P4 — Activities & movement ownership (fixes B3, B4, B6)
`lib/sim/engine.dart` refactor — one movement/activity owner:

```dart
enum AgentActivity { idle, stroll, browse, tend, vigil, gossip, sit, engaged }
class ActivitySlot { poiId, tx, ty, faceDx, faceDy, occupiedBy? }
```

1. **A\* grid pathfinding** replaces the 14-node waypoint graph (`_routeTo`
   keeps its signature internally; waypoint graph deleted). Smooth via
   line-of-walkability shortcutting.
2. **Slots:** each POI exposes `slots`; visiting = reserve free slot → A* →
   face POI → dwell timer → release. No free slot → choose another activity.
3. **Schedules (data-driven, per persona in `personas.json`):** 3 night blocks:
   ```json
   "routine": [
     {"until": 200, "prefer": ["tend:flower_stall","gossip"]},
     {"until": 450, "prefer": ["browse","vigil:ofrenda"]},
     {"until": 600, "prefer": ["vigil:grave_37","stroll"]}
   ]
   ```
   LLM decisions rank *within* the current block's allowed activities; ambient
   brain fills gaps — the Generative Agents "deterministic scaffolding +
   model steering" split, scaled to a village.
4. **`shop(poiId)` resolution fix** (B3): targets resolved as POI → browse
   activity at a counter slot; emits `browsed` memory event. (Player purchases
   remain the existing `shop_sheet` UI — spirits browse, they don't spend.)
5. **Convo hold** (B4): `pairStart` requires both idle-ish **and** ≤ 3 tiles
   apart; cancels walks, pulls partners to adjacent facing tiles, holds until
   the exchange ends, then releases.
6. `inspect`/`anomaly` decisions route to slot + dwell + memory (unchanged
   semantics, now visible).

**Accept:** burst montage shows spirits standing *at* stalls/fountain/graves;
`state` shows `activity` per spirit; sim test asserts `shop()` produces a route
to a slot, slot exclusivity, dwell→release.

### P5 — Dialogue lifecycle (fixes B2)
1. Speech only when `activity ∈ {browse, tend, vigil, gossip, idle, engaged}` —
   `say()` during walk gets **queued** and delivered at next stop (no silent
   drops; the early-return becomes a hold).
2. **Town log** — new HUD widget (bottom-left, translucent): last ~4 exchanges
   `"Sefa → Luz: …"` so dialogue is inspectable even when bubbles are missed;
   also gives judges a readable "the agents are thinking" signal.
3. Bubbles: max 2 on screen, 4–6 s display, positioned over head; speaker name
   in persona color.
4. Prompt enrichment: pass current activity + location + partner to LLM prompts
   (and mock pools keyed per POI type) so lines reference the world.

**Accept:** driver trace records delivered lines for every `say`/`convoTurn`
event; visually, stopped pairs show turn-taking bubbles + log entries.

### P6 — Rendering polish
1. **Y-sort audit + fix** — unify spirits, props, player on one priority rule
   (`priority = footY` ordering; verify sign) so south-of-object actors render
   in front, north-of-canopy behind.
2. Petal-drift particle emitter (cheap, ~30 sprites) + ofrenda candle flicker
   (`fire_01.png` anim) + fountain water (`tileset_animated` frames).
3. Fade mechanic upgrade: on `faded`, play `sk_*_death.png` anim once →
   translucent ghost state (sheets already exist, currently unused).
4. Camera: initial zoom ~1.4–1.6, keep clamp; smooth center on new-night reset.
5. Labels/bubbles keep current fixes (counter-flip, persona colors).

**Accept:** walking behind the ceiba puts the sprite under the canopy, in front
of the trunk; petals drift; dawn sequence shows death→ghost on the faded.

### P7 — Test & verification harness
1. Unit tests (targeted only, per repo rules):
   - `test/sprite_contract_test.dart` — bbox/baseline uniformity (B1 regression)
   - `test/village_map_test.dart` — parse, autotile determinism, walkability,
     slot reachability
   - `test/activity_test.dart` — shop resolution (B3), slot exclusivity, convo
     proximity/hold (B4), speech queue (B2)
2. `docs/VISUAL_VERIFICATION.md` — the live protocol:
   `DRIVER=true` run → `state`/`tap_spirit`/`shot`/`zoom`/`center` via
   `ext.pueblo.cmd`, plus `SHOT=10 SHOTN=24 SHOTEACH=500` burst → ffmpeg
   montage. Includes the expected-output checklist per milestone.
3. `main.dart`: `--dart-define=PERSIST=true` keeps the DB (today `freshDb`
   always deletes — blocks continuity/memory testing).

### P8 — Cleanup
- Delete `GroundComponent` procedural painting + `waypointPos/waypoints` graph
  (superseded by grid+slots); keep `poiDefs` (semantic layer).
- Retire `assets/sprites/town/floors.png` usage (file stays, unused).
- `world_def.dart` shrinks to: map dims, spawn, POI→slot bindings.

---

## 3. Commit plan (feature-wise)

| Commit | Phase |
|---|---|
| `assets: stage CC0 village tilesets + license records` | P0 (done) |
| `docs: village rebuild plan` | this file |
| `fix: normalize character sprite cells — same size idle and running` | P1 |
| `feat: ASCII-authored tilemap with Wang autotiling` | P2 |
| `feat: village layout — plaza, market row, cemetery, ofrenda` | P3 |
| `feat: activity slots, schedules, A* routing; fix shop target resolution` | P4 |
| `feat: speech hold + town log; fix convo engagement` | P5 |
| `feat: depth sorting, petals, candle glow, fade animation` | P6 |
| `test: sprite contract, map walkability, activity lifecycle` | P7 |

---

## 4. Milestone acceptance (what "done" looks like)

- **M1 (P1):** burst montage — all 7 characters identical height idle vs
  running; no foot slide.
- **M2 (P2+P3):** screenshot reads as a *village* without explanation:
  recognizable streets, houses, stalls, cemetery, ofrenda, bridge over water.
- **M3 (P4):** 10 s montage — ≥2 spirits standing at stalls/fountain, one
  pair facing each other talking, nobody overlapping a counter/tree.
- **M4 (P5):** every `say`/`convo` event in a 30 s trace has a delivered
  bubble or log line; zero drops.
- **M5 (P6):** tree canopy occludes a north-passing spirit; petals drift;
  dawn shows remembered/faded with death anim.
- **M6 (P7):** tests green; `VISUAL_VERIFICATION.md` reproducible by the user.

---

## 5. Risks & mitigations

| Risk | Mitigation |
|---|---|
| Two packs' palettes clash | Bake-time grade toward dusk; contact-sheet eyeball check in P3 before full layout |
| Autotile bitmask bugs → ugly seams | Table-driven unit test with synthetic neighborhoods; visual check on a small test map first |
| 132 loose tile PNGs unwieldy | `tile_index.dart` semantic names; only ~30 indices actually used |
| A\* on 44×26 trivially fine, but slot facing could look robotic | Dwell-time jitter + occasional idle-frame emotes |
| Full NA pack (89 MB, more chars/props) needs itch login — can't auto-fetch | Not blocking: environment already covered; user can drop it in later for 4-dir villager/monster sheets if wanted |
| `image` pkg as dev dep | Dev-only tool dep; runtime stays `flame`-only |

## 6. Deferred (explicit non-goals)
4-direction spirit sprites (our skeleton family is side-view; acceptable —
RPG tradition), interiors, day cycle, farming, >6 residents, multiplayer,
Stardew content volume.
