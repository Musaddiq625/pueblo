/// Village map — the authored layout for El Pueblo de los Muertos.
///
/// Terrain is declared as ASCII rows (44 cols × 26 rows, one char = one
/// 32px logical tile). Props (buildings, trees, fences, stalls, graves)
/// are declared as tile rects + semantic types and rendered as components.
/// Everything downstream — walkability, pathing, activity slots — derives
/// from this file, so the map is unit-testable end to end.
///
/// Terrain legend:
///   w  river water            e  packed earth (village floor)
///   d  dirt street            g  graveyard grass (cemetery plots)
///   s  plaza stone            b  bridge deck
///   p  marigold carpet        (ofrenda approach)
library;

/// Logical tile size in world px (16px source art at 2×).
const kTile = 32.0;
const kMapTilesW = 44;
const kMapTilesH = 26;
const kMapW = kMapTilesW * kTile; // 1408
const kMapH = kMapTilesH * kTile; // 832

const villageAscii = <String>[
  //   0         1         2         3         4
  //   01234567890123456789012345678901234567890123
  'wwwwwwwwwwwwwwwwwwwwwbbwwwwwwwwwwwwwwwwwwwww', // 0 river + bridge
  'wwwwwwwwwwwwwwwwwwwwwbbwwwwwwwwwwwwwwwwwwwww', // 1
  'eeeeeeeeeeeeeeeeeeeeebbeeeeeeeeeeeeeeeeeeeee', // 2 landing
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeeeeeeeeeeeee', // 3 main street N
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeeeeeeeeeeeee', // 4
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeggggggggggee', // 5 NE plot grass
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeggggggggggee', // 6
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeggggggggggee', // 7
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeggggggggggee', // 8
  'eeeeeeeeeeeeeeeeeeeeeddeeeeeeeeeggggggggggee', // 9 (gate → street)
  'eeeedddddddddddddddddddddddddddddddddddeeeee', // 10 market street
  'eeeeddddddddddddddddssssssssdddddddeddddeeee', // 11 street + plaza west edge
  'eeeeeeeeeeeeeeeeeeessssssssseeeeeeeeddddeeee', // 12 plaza bowl
  'eeeeeeeeeeeeeeeeeeessssssssseeeeeeeeddddeeee', // 13
  'eeeeeeeeeeeeeeeeeeessssssssseeeeeeeeddddeeee', // 14
  'eeeeeeeeeeeeeeeeeeeessssssseeeeeeeeeddggeeee', // 15 plaza taper
  'eeeeeeeeeeeeeeeeeeeeeddddeeeeeeeeeeddgggggee', // 16
  'eeeeeeeeeeeeeeeeeeeeeddddeeeeeeeeeeddgggggee', // 17 lane + plot grass
  'eeeeeeeeeeeeeeeeeeeeeddddeeeeeeeeeeddgggggee', // 18
  'eeeeeeeeeeeeeeeeeeeeeddddeeeeeeeeeeddgggggee', // 19
  'eeeeeeeeeeeeeeeeeeeppddpppppeeeeeeeeddddeeee', // 20 marigold approach
  'eeeeeeeeeeeeeeeeeeepppddpppppeeeeeeeeddddeee', // 21
  'eeeeeeeeeeeeeeeeeeeppppppppeeeeeeeeeddddeeee', // 22 ofrenda garden
  'eeeeeeeeeeeeeeeeeeeppppppppeeeeeeeeeddddeeee', // 23
  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeddeeee', // 24 lane to ceiba
  'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeddeeee', // 25 south edge
];

/// A declared prop: [kind] + tile position + optional args (e.g. fence
/// length). The tilemap renderer knows how to draw each kind and which
/// cells it blocks.
class Prop {
  final String kind;
  final int tx, ty;
  final List<int> args;
  const Prop(this.kind, this.tx, this.ty, [this.args = const []]);
}

/// Buildings, fences, vegetation, clutter — the visible village.
const villageProps = <Prop>[
  // ---- border hedge — pines/bushes ring the map inside the edge ----
  Prop('pine', 1, 3), Prop('bush', 6, 2), Prop('pine', 9, 3),
  Prop('pine', 14, 2), Prop('bush', 18, 3), Prop('pine', 26, 2),
  Prop('pine', 2, 7), Prop('pine', 1, 12), Prop('bush', 2, 17),
  Prop('pine', 1, 21), Prop('pine', 4, 24), Prop('pine', 9, 24),
  Prop('bush', 15, 24), Prop('pine', 28, 24), Prop('pine', 33, 24),
  Prop('pine', 42, 24), Prop('pine', 42, 20), Prop('bush', 42, 16),
  Prop('pine', 42, 11), Prop('pine', 42, 7), Prop('pine', 43, 3),
  // west field
  Prop('autumn', 3, 5), Prop('pine', 5, 4), Prop('autumn', 7, 6),
  Prop('bush', 4, 7), Prop('mushroom', 6, 8), Prop('bush', 9, 5),
  Prop('leafy', 2, 9), Prop('pine', 11, 3),
  // east field
  Prop('autumn', 38, 3), Prop('bush', 40, 3), Prop('pine', 43, 5),
  // plaza dressing
  Prop('autumn', 16, 13), Prop('bush', 18, 16), Prop('bush', 27, 16),
  Prop('autumn', 16, 17), Prop('bush', 17, 20),

  // ---- NE cemetery plot (fence: cols 31,42 / rows 4,9; gate S at 35-36) ----
  Prop('fenceH', 31, 4, [11]),
  Prop('fenceV', 31, 5, [4]),
  Prop('fenceV', 42, 5, [4]),
  Prop('fenceH', 31, 9, [4]),
  Prop('fenceH', 37, 9, [5]),
  Prop('crypt', 35, 5), // covers 35-38 × 5-6
  // sparse graves — the center lane from the gate stays walkable
  Prop('grave', 32, 5), Prop('grave', 41, 5),
  Prop('grave', 33, 7), Prop('grave', 40, 7),
  Prop('grave', 34, 8), Prop('grave', 41, 8),
  Prop('mushroom', 33, 6), Prop('mushroom', 40, 6),
  Prop('bone', 32, 8), Prop('bone', 39, 8),

  // ---- SE graveyard (fence cols 37-42 rows 15-20; gate W at (37,17)) ----
  Prop('fenceH', 37, 15, [5]),
  Prop('fenceV', 42, 16, [4]),
  Prop('fenceH', 37, 20, [5]),
  Prop('fenceV', 37, 16, [1]),
  Prop('fenceV', 37, 18, [2]),
  // graves hug the walls — the lane from the gate stays open
  Prop('grave', 38, 16), Prop('grave', 40, 16), Prop('grave', 41, 16),
  Prop('grave37', 40, 18), // the special grave — marigolds, no name
  Prop('grave', 39, 19),
  Prop('mushroom', 39, 16), Prop('bone', 38, 19),

  // ---- market row (buildings sit on 'e' north of the street) ----
  Prop('cantina', 14, 6), // covers 14-17 × 6-9 — door at (15,9)
  Prop('stall', 10, 8, [0]), // flower stall — covers 10-12 × 8-9
  Prop('sign', 18, 9),
  Prop('pot', 13, 9), Prop('barrel', 9, 9),
  Prop('lantern', 7, 9), Prop('lantern', 20, 9),
  Prop('curiosity', 27, 7), // covers 27-30 × 7-9
  Prop('barrel', 32, 9), Prop('pot', 26, 9),
  Prop('lantern', 25, 9), Prop('lantern', 33, 9),
  Prop('hut', 31, 14), // gravedigger's hut — covers 31-33 × 14-16
  Prop('pickaxe', 34, 15), Prop('lantern', 30, 14),

  // ---- plaza + fountain ----
  Prop('well', 25, 13), // fountain — covers 25-27 × 13-15
  Prop('bench', 19, 12), Prop('bench', 23, 12),
  Prop('lantern', 18, 12), Prop('lantern', 28, 12),

  // ---- ofrenda ----
  Prop('ofrenda', 19, 22), // tiered shrine — covers 19-25 × 22-23
  Prop('lantern', 17, 21), Prop('lantern', 27, 21),

  // ---- the old ceiba (SE, past the lower graveyard) ----
  Prop('ceiba', 38, 21), // covers 38-40 × 21-23
  // ---- street clutter ----
  Prop('boulder', 4, 13), Prop('pot', 6, 15), Prop('barrel', 8, 17),
  Prop('boulder', 29, 13), Prop('pot', 30, 12),
  Prop('log', 5, 18), Prop('mushroom', 8, 20), Prop('boulder', 10, 23),
  Prop('bone', 29, 17), Prop('boulder', 33, 21),

  // ---- west marigold field — where Luz's flowers come from ----
  // non-blocking scatter: spirits drift through the rows like ghosts do
  Prop('marigold', 3, 12), Prop('marigold', 4, 12), Prop('marigold', 5, 12),
  Prop('marigold', 6, 12), Prop('marigold', 7, 12),
  Prop('marigold', 3, 14), Prop('marigold', 4, 14), Prop('marigold', 5, 14),
  Prop('marigold', 6, 14), Prop('marigold', 7, 14),
  Prop('marigold', 3, 16), Prop('marigold', 4, 16), Prop('marigold', 5, 16),
  Prop('marigold', 6, 16), Prop('marigold', 7, 16),
  Prop('marigold', 3, 18), Prop('marigold', 4, 18), Prop('marigold', 5, 18),
  Prop('marigold', 6, 18), Prop('marigold', 7, 18),
  Prop('hay', 2, 13), Prop('hay', 8, 19), Prop('hay', 9, 15),
  Prop('boulder', 2, 20), Prop('log', 8, 21), Prop('autumn', 11, 20),
];

/// Activity slots — standable tiles in front of POIs, with facing.
/// (fx,fy) = the direction the spirit faces on arrival (toward the POI).
class ActivitySlot {
  final String poiId;
  final int tx, ty;
  final int fx, fy;
  const ActivitySlot(this.poiId, this.tx, this.ty, this.fx, this.fy);
}

const villageSlots = <ActivitySlot>[
  // bridge overlook — face the river
  ActivitySlot('bridge', 21, 3, 0, -1),
  ActivitySlot('bridge', 22, 3, 0, -1),
  // flower stall counter
  ActivitySlot('flower_stall', 10, 10, 0, -1),
  ActivitySlot('flower_stall', 11, 10, 0, -1),
  ActivitySlot('flower_stall', 12, 10, 0, -1),
  // curiosity shop
  ActivitySlot('curiosity_shop', 28, 10, 0, -1),
  ActivitySlot('curiosity_shop', 29, 10, 0, -1),
  ActivitySlot('curiosity_shop', 30, 10, 0, -1),
  // cantina door + side
  ActivitySlot('cantina', 15, 10, 0, -1),
  ActivitySlot('cantina', 16, 10, 0, -1),
  // fountain rim
  ActivitySlot('fountain', 24, 13, 1, 0),
  ActivitySlot('fountain', 24, 15, 1, 0),
  ActivitySlot('fountain', 26, 12, 0, 1),
  ActivitySlot('fountain', 26, 16, 0, -1),
  // gravedigger's door
  ActivitySlot('gravedigger_hut', 32, 17, 0, -1),
  ActivitySlot('gravedigger_hut', 34, 14, -1, 0),
  // cemetery lanes — face the graves
  ActivitySlot('cemetery_lane', 35, 11, 0, -1),
  ActivitySlot('cemetery_lane', 35, 16, 1, 0),
  ActivitySlot('cemetery_lane', 36, 19, 0, 1),
  // grave 37
  ActivitySlot('grave_37', 39, 18, 1, 0),
  ActivitySlot('grave_37', 40, 17, 0, 1),
  // the old ceiba
  ActivitySlot('ancient_tree', 37, 22, 1, 0),
  ActivitySlot('ancient_tree', 39, 24, 0, -1),
  // ofrenda — face south to the shrine
  ActivitySlot('ofrenda', 20, 21, 0, 1),
  ActivitySlot('ofrenda', 22, 21, 0, 1),
  ActivitySlot('ofrenda', 24, 21, 0, 1),
  // plaza gathering
  ActivitySlot('plaza', 21, 12, 0, 1),
  ActivitySlot('plaza', 23, 13, -1, 0),
  ActivitySlot('plaza', 21, 14, 0, -1),
];

/// POI anchor tile (component position + label anchor).
const poiTiles = <String, (int, int)>{
  'bridge': (22, 2),
  'flower_stall': (11, 9),
  'cantina': (15, 9),
  'curiosity_shop': (28, 9),
  'fountain': (26, 14),
  'gravedigger_hut': (32, 15),
  'cemetery_lane': (35, 17),
  'grave_37': (39, 17),
  'ancient_tree': (39, 22),
  'ofrenda': (22, 22),
  'plaza': (22, 15),
};

double tileX(int tx) => tx * kTile + kTile / 2;
double tileY(int ty) => ty * kTile + kTile / 2;
double tileBottom(int ty) => ty * kTile + kTile;
