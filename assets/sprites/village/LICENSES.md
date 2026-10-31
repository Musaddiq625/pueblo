# Third-party art — licenses & provenance

All external art in this directory is Creative Commons Zero (CC0). Attribution is
not legally required but is kept here for credit and auditability.

## ninja_adventure/

**Ninja Adventure — Asset Pack** by Pixel-Boy & AAA
- Source: https://pixel-boy.itch.io/ninja-adventure-asset-pack
- Mirror used: https://github.com/pixel-boy/NinjaAdventure (Godot 4 demo project)
- License: Creative Commons Zero v1.0 Universal (CC0). Stated on the itch page:
  "You can use any and all of the assets found in this package in your own games,
  even commercial ones. Attribution is not required but appreciated."
- Content: "No generative AI was used" (per itch page).
- Files used: `tileset_floor.png` (terrain autotiles), `tileset_village_abandoned.png`
  (buildings/trees/fences), `tileset_wall_simple.png`, `tileset_interior_floor.png`,
  `tileset_animated.png` (water/flame animations), `crate.png`, `pot.png`, `grass.png`.
- Tiles are 16×16 source pixels.

## tiny_town/

**Tiny Town** by Kenney (kenney.nl)
- Source: https://kenney.nl/assets/tiny-town
- Mirror used: https://opengameart.org/content/tiny-town
- License: CC0 — see `tiny_town/License.txt` (bundled in the original zip).
- Files used: `Tiles/tile_0000.png` … `tile_0131.png` — 132 individual 16×16 tiles:
  terracotta-roof houses, market stall tents, lanterns, well, signs, fences,
  pots, bone piles, grass/dirt/cobble edge tiles.

## First-party art (elsewhere in assets/)

`assets/sprites/objects/*` — pack-provided object sheets.

`assets/sprites/chars/*` — character sheets from two sources:

### Pixel Crawler — Free Pack 2.11 by Anokolisa
- Source: https://anokolisa.itch.io/free-pixel-art-asset-pack-topdown-tileset-rpg-16x16-sprites
- Free asset pack; author states "you can use the packs for your project or
  for commercial projects freely" (itch page/community replies).
- Files used: `sk_*`, `knight_*`, `wizzard_*`, `tavern_*` (from the earlier
  1.x pack), plus `peasant_*` (Citizen_F/Peasant_A), `npc_rogue_*`
  (Npc's/Rogue), `bodya_*` (Characters/Body_A side sheets).

### Tiny RPG — Char Workshop I demo by tiopalada (CC0)
- Source: https://opengameart.org/content/tiny-rpg-cc0-characters-and-portraits
- License: Creative Commons Zero v1.0 Universal — explicitly the CC0 demo.
- Files used: `trp_hat_*`, `trp_bard_*`, `trp_veil_*` — the three demo
  characters (down/left/back/right rows; we slice down→idle, left→walk via
  `tool/slice_trp_chars.dart`; raw 288×192 sheets kept in `tool/art_src/`).
