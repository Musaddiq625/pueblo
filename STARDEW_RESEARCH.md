# Stardew-Inspired Village: Research and Adaptation Proposal

Research date: 2026-10-28. Baseline: commit `4521952`.
This is a proposal, not an implemented feature list.

## 1. Verdict

Keep Flutter, Flame, the pure-Dart simulation, local inference, original
personas, and the memory/forgotten-spirit theme. Replace the placeholder
world presentation and competing movement rules with a coherent tilemap,
an explicit activity lifecycle, and a stable sprite contract.

The achievable target is one small, polished, autonomous village inspired
by Stardew's readability, not its content volume or copyrighted artwork.
No engine migration is necessary to attempt this.

## 2. Evidence From This Project

### Idle/walk shrinking: confirmed from source image pixels

The manifest correctly describes the outer sheets: idle is four 32x32 cells;
run is six 64x64 cells. The problem is drawing both source canvases into the
same 56x56 destination rectangle (`SpiritComponent`, also `PlayerComponent`).
The run art has much more transparent padding, not twice as much character.

Measured every declared frame's nonzero-alpha bounds with a Python-standard-
library PNG decoder; projected visible height is alpha height * 56 / cell size.
These are world-space render heights before camera/device scaling:

| Character | Idle visible height | Run visible height |
| --- | --- | --- |
| sk_base | 47.25-52.50 | 26.25-28.00 |
| sk_warrior | 49.00-52.50 | 26.25-28.00 |
| sk_rogue | 52.50-56.00 | 28.00-29.75 |
| sk_mage | 50.75-56.00 | 27.13-28.00 |
| knight | 47.25-50.75 | 25.38-27.13 |

Visual artifact: `/tmp/pueblo-research-visuals/sheet_labeled.png`.
It compares frame zero at equal destination-canvas sizes without normalizing
the visible art. The artifact is temporary; the measurements above are saved.

Fix principle: one source-pixel scale and semantic foot anchor across actions.
Represent source canvas, pivot, and trim offsets explicitly, or repack into
common untrimmed cells. Do not independently fit every frame to its alpha bounds:
that introduces breathing, lateral jitter, and moving pivots.

### Dialogue: confirmed suppression; runtime frequency not measured here

`PuebloGame._bubble` discards nonempty speech when `c.walking` is true. That
can suppress real utterances instead of coordinating a stop before delivery.
Pair-start stops renderer walking, so this is not proof that every conversation
is hidden. A fresh event trace is needed to explain a particular silent run.

Other code-level concerns:

- Simulation and renderer independently advance paths with different arrival
  tolerances; they are not one authoritative movement state.
- Pair-start sets `walking=false` but does not explicitly reset the animation
  to idle or clear the renderer's queued path.
- Bubbles are children of flipped/depth-sorted sprites; child priority is not
  a global foreground layer.
- Non-emote bubbles last 3.6 real seconds and have a three-line display limit.
- Ollama request failures return null silently. A missing model/server must be
  distinguished from rejected actions, no conversations, and hidden bubbles.

Do not promise that switching from mock to Qwen fixes these presentation bugs.

### Shopping: confirmed action-contract mismatch

`_scheduleDecision` offers `shop(<poi id>)`. `_execute` handles `shop` beside
`offerSecret`, looks up `agents[d.target]`, and falls back to strolling when the
target is a stall ID. Ambient `_browse` glows a POI and records a visit; it does
not perform an NPC purchase. Player purchases are a separate implemented system.

Fix the shop target contract before claiming that autonomous commerce works.
Start with visible browsing; implement stock/payment/inventory semantics before
describing it as buying.

### Background and depth: structural, not another color tweak

- `GroundComponent` paints soil, line-based streets, discs, and decorations.
  It retains a `floors` image but does not use it to render the terrain.
- Street positions/edges duplicate the graph in `world_def.dart`.
- Town assets contain one `floors.png`; the object set contains a tree sheet,
  alchemy table, fire, bonfire, and smoke, not a complete town-building set.
- Many POIs remain shrine-marker placeholders. Curiosity shop is a table,
  not a shop exterior.
- Characters/POIs use negative foot-Y priorities. Flame draws higher priority
  later, so this reverses conventional south-in-front top-down depth ordering.

This explains why a few added awnings do not produce the reference screenshots.

### Persistence safety found during capture preparation

Normal bootstrap currently passes `freshDb: true`, and `SimStore.open` calls
`deleteDatabase(path)` when fresh. Existing app database files are present.
No new app was launched during this research to avoid destroying prior data.
Use a separate disposable test database before future automated capture.

## 3. What Stardew Actually Provides

### A layered, authored map

The community modding documentation describes 16x16 source tiles and layers
for terrain, blocking geometry, removable paths/features, depth-sensitive
foreground, and always-front elements. Tile properties carry passability and
interactions. This is a data-authored world, not a navigation graph painted
as the finished scenery. [S2]

Adapt the principle, not Stardew's layer names or assets verbatim:
terrain -> paths/water edges -> grounded props/buildings -> foot-Y actors and
occluders -> canopy/roof foreground -> lighting -> screen-space UI.

### Schedules rather than indiscriminate random motion

The official site describes individual daily schedules. The modding reference
documents schedule selection by date, season, rain, friendship and other
conditions. Schedule points include time, location, tile, facing, and optional
arrival animation/dialogue. [S1, S3]

Do not equate autonomy with nonstop walking. Resting, working, browsing, and
talking are meaningful autonomous activities. Random local wandering is a
fallback, not every villager's entire life.

### Directional animation and contextual dialogue

NPC-authoring documentation describes standard 16x32 character frames and
directional movement sequences. Dialogue selection can depend on location,
time-related context, and relationship conditions. [S4, S5]

Our existing side-facing idle/run sheets cannot acquire authentic front/back
poses just by changing code. A proper four-direction upgrade requires suitable
artwork. Preserve a stable foot anchor regardless of sprite dimensions.

### Art direction is authored work

In an interview Barone describes repeatedly redoing artwork while developing
his skills over several years. This is not evidence that our project requires
years, but it is a warning not to promise equivalent polish from a new package
or another procedural ground patch. [S6]

## 4. Related References and What To Borrow

- Littlewood: a useful compact-town visual/scope reference; its creator
  describes townsfolk, buildings, and requests. Borrow legibility, not its
  town-construction and crafting content. [S7]
- Tiny Life: developer docs expose action queues, personality-modified passive
  priorities, need-solving actions, and coordinated social actions. Useful
  implementation precedent for purposeful autonomy. [S8]
- Solarus: an open-source Zelda-like engine with separate random, path,
  target, and pathfinding movement APIs and directional animation sets.
  Study the separation; do not port the project to Solarus. [S9]
- RPG Maker: official docs distinguish fixed, random, approach, and custom
  movement, plus speed/frequency. The official NPC-route tutorial explicitly
  suspends companion wandering during player conversation. These are event-
  system references, not claims about the internals of commercial Pokemon. [S10]
- Smallville / Generative Agents: memory, reflection, and planning support
  believable activity and social interaction. Its research architecture is
  relevant to our theme; its 25-agent setup is not a device-budget promise
  for the MacBook or Pixel. [S11]

## 5. Proposed Architecture Within Our Scope

### Map and art contract

Use Tiled plus `flame_tiled`, keeping Flame. The official bridge supports TMX
maps and layered rendering. Object properties must be translated into our
simulation's collision/navigation/interaction data; importing a map does not
automatically implement all those systems. [S12, S13]

Proposed starting scale: 16px source tiles rendered at 2x = 32 world units.
A 44x26-tile village would be 1408x832 world units, close to current map bounds.
These dimensions are a design proposal, not measured performance requirements.

Use nearest-neighbor sampling. Prefer stable integer pixel scales in the
default gameplay view; retain pinch/pan, accepting that intermediate zoom
scales are not perfectly pixel-uniform. Keep simulation coordinates continuous,
and apply any pixel snapping to rendering only.

Author one source of truth for terrain, walkability, POIs, shop fronts,
interaction slots, and spawn positions. Extract data into plain Dart so the
simulation remains independent of Flame. Paths are preferred walkable surfaces;
props/water are blocked. Do not keep a separate hand-copied street graph.

### Activity lifecycle

`choose activity -> reserve target -> walk -> face target -> perform/dwell ->
record outcome -> release reservation -> choose next activity`

Activity states should include walking, working, browsing, inspecting,
conversing, resting, and player-engaged. One movement owner is authoritative.
Use bounded grid pathfinding, not arbitrary last-leg movement across scenery.
Reserve interaction slots and handle occupied/unreachable destinations.

Examples: Luz tends flowers and visits the ofrenda; Sefa works the cantina;
Bruno tends graves; Ramon performs at the plaza; Ines investigates the fountain.
The model can select among valid opportunities and react to recent history.
Deterministic code owns routes, occupancy, availability, outcomes, and fallback.

### Dialogue delivery

For a committed conversation, stop/reserve both participants, face them,
and hold the activity through readable delivery and completion. Do not discard
the utterance to enforce the stop. Use a foreground speech presentation layer
and a scrollable recent-conversation log with speaker, listener, and location.
Make it clear which speech the player overheard versus learned as fact.

Inference stays asynchronous. A visible thinking/activity indicator can cover
latency without freezing the town or inventing claims. Ground model context in
the current activity, actual partner, recent events, and speaker-owned knowledge.
Offline fallback should be contextual and labeled as mock, not sold as real AI.

### Village composition

Build a single recognizable scene: bridge over actual water, market row with
three distinct facades/counters, fountain courtyard, cemetery with entrances,
and a candlelit ofrenda garden connected by tile paths.

Choose one palette/projection/pixel density. Use warm marigold/candle focal
points against readable cool dusk terrain. Add bounded trees, fences, shrubs,
and water/cliff edges to explain the boundary. Do not bury the art in a uniform
dark overlay. Full interiors and map transitions are optional later work.

## 6. Artwork Options and Licensing

Stardew screenshots are references, not an asset license. Do not copy its
sprites, maps, UI, or ripped textures.

- Ninja Adventure, Pixel-Boy and AAA: creator lists characters, animated
  creatures, exterior/interior tiles, UI, effects, and CC0 licensing.
  Strong candidate for a complete pipeline proof, but its theme needs visual
  adaptation and the exact character/direction inventory still needs audit. [S14]
- Tiny Town, Kenney: CC0 overworld town tiles; good lightweight environment
  candidate, not proof of a complete directional animation set. [S15]
- Sprout Lands, Cup Nooble: attractive farming reference, but free version is
  noncommercial and both license descriptions restrict redistribution.
  Do not put its raw art in this public repository without permission. [S16]
- Universal LPC: generator has per-piece licenses and attribution export,
  not one blanket CC0 license. Audit each selected layer before adoption. [S17]

First choose an environment/character contact sheet that works together.
Then adapt original calavera outfits, marigold flowers, ofrenda, and papel
picado. Fixing padding is immediate; creating six coherent four-direction
spirit designs is a separate art deliverable.

## 7. Scope and Proof Gates

Implement in feature-sized slices after this direction is accepted:

1. Sprite contract and disposable capture environment: compare idle/run at
   stationary feet, including the player; no source-pixel scale discontinuity.
2. Art/map vertical slice: one finished street, shop, tree, and fountain;
   prove occlusion, collisions, and readable mobile/desktop scale.
3. Activity/movement ownership: an agent reaches a reserved shop-front slot,
   dwells without walking through the counter, and resumes.
4. Speech lifecycle: two agents stop, deliver a visible turn, log it, and resume;
   player interruption reserves only the selected spirit.
5. Extend to six personas and the single complete village; add atmosphere last.

Verification should include targeted tests for source rectangles/pivots,
blocked/occupied routes, shop action target resolution, and dialogue delivery.
Capture actual input-driven scenes, not only direct engine callback commands.
Use entity IDs/Flutter keys, screenshots immediately after actions, and a
10-second motion sequence; validate both desktop and phone viewport dimensions.
Never call a scene verified merely because a build, analyzer, or still PNG passes.

Defer farming seasons, romance, combat, large inventories, procedural worlds,
many interiors, multiplayer, and dozens of residents. Preserve the project's
distinctive six-agent memory/mystery simulation, not Stardew's entire game.

## Sources

- [S1] ConcernedApe, Stardew Valley - About: https://www.stardewvalley.net/about/
- [S2] Stardew Valley Wiki contributors, Modding:Maps: https://wiki.stardewvalley.net/Modding:Maps
- [S3] Stardew Valley Wiki contributors, Modding:Schedule data: https://wiki.stardewvalley.net/Modding:Schedule_data
- [S4] Stardew Modding Wiki contributors, Tutorial: Making a Custom NPC: https://stardewmodding.wiki.gg/wiki/Tutorial:_Making_a_Custom_NPC
- [S5] Stardew Valley Wiki contributors, Modding:Dialogue: https://wiki.stardewvalley.net/Modding:Dialogue
- [S6] PC Gamer, interview with Eric Barone: https://www.pcgamer.com/stardew-valley-interview/
- [S7] Sean Young, Littlewood: https://seanyosg.itch.io/littlewood
- [S8] Tiny Life developer docs, ActionType.AiSettings and social actions: https://docs.tinylifegame.com/api/TinyLife.Actions.ActionType.AiSettings.html ; https://docs.tinylifegame.com/api/TinyLife.Actions.html
- [S9] Solarus documentation, Movements and Sprites: https://docs.solarus-games.org/lua-api/movements/ ; https://docs.solarus-games.org/lua-api/drawable-objects/sprite/
- [S10] RPG Maker, Map Event Settings and NPC move routes: https://rpgmakerofficial.com/product/MZ_help-en/01_09_03.html ; https://rpgmakerweb.com/blog/making-interesting-npc-move-routes-with-script-calls
- [S11] Joon Sung Park et al., Generative Agents: Interactive Simulacra of Human Behavior: https://arxiv.org/abs/2304.03442
- [S12] Flame team, flame_tiled and Layers: https://docs.flame-engine.org/latest/bridge_packages/flame_tiled/flame_tiled.html ; https://docs.flame-engine.org/latest/bridge_packages/flame_tiled/layers.html
- [S13] Tiled contributors, Using Terrains and Working with Layers: https://docs.mapeditor.org/en/stable/manual/terrain/ ; https://docs.mapeditor.org/en/stable/manual/layers/
- [S14] Pixel-Boy and AAA, Ninja Adventure - Asset Pack: https://pixel-boy.itch.io/ninja-adventure-asset-pack
- [S15] Kenney, Tiny Town: https://kenney.nl/assets/tiny-town ; creator's CC0 listing: https://opengameart.org/content/tiny-town
- [S16] Cup Nooble, Sprout Lands - Asset Pack: https://cupnooble.itch.io/sprout-lands-asset-pack
- [S17] Liberated Pixel Cup contributors, Universal LPC generator licensing: https://github.com/liberatedpixelcup/Universal-LPC-Spritesheet-Character-Generator
- [S18] @framesprite, A Fixed-Cell Contract for Sprite Sheets That Do Not Jitter: https://dev.to/framesprite/a-fixed-cell-contract-for-sprite-sheets-that-do-not-jitter-3167
- [S19] @krlz, Make Games with Flutter in 2025: Flame Engine, Tools, and Free Assets: https://dev.to/krlz/make-games-with-flutter-in-2025-flame-engine-tools-and-free-assets-1n6
- [S20] @4um4, Building ENIGMA: a deterministic agent simulation, solo, via free-tier LLM access: https://dev.to/4um4/building-enigma-a-deterministic-agent-simulation-solo-via-free-tier-llm-access-e58

DEV articles support specific practices, not a broad consensus; the inspected
comment threads were empty. Package/API recommendations use official docs rather
than version numbers in the older Flutter overview.
