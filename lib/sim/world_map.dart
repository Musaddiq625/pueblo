/// Village map — the authored layout for El Pueblo de los Muertos.
///
/// Terrain is declared as ASCII rows (44 cols × 26 rows, one char = one
/// 32px logical tile). Props (buildings, trees, fences, stalls, graves)
/// are declared as tile rects + semantic types and rendered as components.
/// Everything downstream — walkability, pathing, activity slots — derives
/// from this file, so the map is unit-testable end to end.
///
/// The ground rule that makes it read as a town, not a starfield:
///   grass is the base, dirt is carved through it, and every walkable
///   district touches a street. Zones are joined, never islands.
///
/// Terrain legend:
///   w  river water            g  grass (base terrain — everywhere)
///   d  dirt street            e  packed earth (yards, graveyard interiors)
///   s  plaza stone            b  bridge deck
///   p  marigold carpet        (ofrenda approach — the petal path)
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
  'gggggggggggggggggggggddggggggggggggggggggggg', // 2 landing meadow
  'gggggggggggggggggggggddgggggggggeeeeeeeeeegg', // 3 main st + NE cemetery
  'gggggggggggggggggggggddgggggggggeeeeeeeeeegg', // 4
  'gggggggggggggggggggggddgggggggggeeeeeeeeeegg', // 5
  'gggggggggggggggggggggddgggggggggeeeeeeeeeegg', // 6
  'gggggggggggggggggggggddgggggggggeeeeeeeeeegg', // 7
  'ggddddddddddddddddddddddddddddddddeeddeeeegg', // 8 sidewalk + cemetery gate
  'ggddddddddddddddddddddddddddddddddddddddddgg', // 9 market street
  'ggddddddddddddddddddddddddddddddddddddddddgg', // 10
  'ggddggggggggggsssssssssssssgggggggddgggggggg', // 11 plaza north rim
  'ggddggggggggggsssssssssssssgggggggddgggggggg', // 12
  'ggddggggggggggsssssssssssssgggggggddgggggggg', // 13
  'ggddggggggggggsssssssssssssgggggggddeeeeeeeg', // 14 + SE yard top
  'ggddggggggggggsssssssssssssgggggggddeeeeeeeg', // 15
  'ggddggggggggggsssssssssssssgggggggdddeeeeeeg', // 16 lane + yard gate
  'ggddggggggggggsssssssssssssgggggggdddeeeeeeg', // 17
  'ggddggggggggggsssssssssssssgggggggddeeeeeeeg', // 18 plaza south rim
  'ggddgggggggggggggggggddgggggggggggddeeeeeeeg', // 19 street resumes S
  'ggddgggggggggggpppppppppppppggggggddgggggggg', // 20 ofrenda garden
  'ggddgggggggggggpppppppppppppggggggddgggggggg', // 21
  'ggddgggggggggggpppppppppppppggggggddgggggggg', // 22
  'ggddgggggggggggpppppppppppppggggggddgggggggg', // 23
  'ggddddddddddddddddddddddddddddddddddgggggggg', // 24 south ring
  'gggggggggggggggggggggggggggggggggggggggggggg', // 25
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
  // ---- border hedge — the tree line framing the town ----
  // north meadow, flanking the bridge road
  Prop('pine', 2, 2), Prop('bush', 6, 3), Prop('pine', 10, 2),
  Prop('pine', 14, 3), Prop('bush', 17, 2), Prop('pine', 19, 3),
  Prop('pine', 24, 2), Prop('bush', 27, 3), Prop('pine', 30, 2),
  // west edge
  Prop('bush', 1, 4), Prop('pine', 0, 6), Prop('pine', 1, 9),
  Prop('bush', 0, 12), Prop('pine', 1, 15), Prop('bush', 0, 18),
  Prop('pine', 1, 21), Prop('pine', 0, 24),
  // east edge
  Prop('pine', 43, 5), Prop('bush', 43, 8), Prop('pine', 43, 12),
  Prop('bush', 43, 21), Prop('pine', 43, 24),
  // south edge
  Prop('pine', 4, 25), Prop('bush', 9, 25), Prop('pine', 14, 25),
  Prop('pine', 20, 25), Prop('bush', 26, 25), Prop('pine', 32, 25),
  Prop('bush', 38, 25),

  // ---- NE cemetery — fenced bare-earth yard, gate S onto the street ----
  Prop('fenceH', 32, 3, [10]),
  Prop('fenceV', 32, 4, [4]),
  Prop('fenceV', 41, 4, [4]),
  Prop('fenceH', 32, 8, [4]),
  Prop('fenceH', 38, 8, [4]), // gate gap at 36-37
  Prop('crypt', 33, 4), // covers 33-36 × 4-5
  Prop('grave', 39, 4), Prop('grave', 33, 6), Prop('grave', 35, 7),
  Prop('grave', 39, 6), Prop('grave', 33, 7), Prop('grave', 39, 7),
  Prop('mushroom', 38, 5), Prop('bone', 34, 6), Prop('bone', 40, 5),

  // ---- market row — buildings on grass fronting the sidewalk ----
  Prop('hut', 4, 5), // covers 4-6 × 5-7
  Prop('stall', 10, 7, [0]), // flower stall — covers 10-12 × 7-8
  Prop('cantina', 14, 4), // covers 14-17 × 4-7 — door at (15,7)
  Prop('hut', 18, 5), // covers 18-20 × 5-7
  Prop('hut', 23, 5), // covers 23-25 × 5-7
  Prop('curiosity', 27, 5), // covers 27-30 × 5-7
  // sidewalk dressing
  Prop('lantern', 7, 8), Prop('barrel', 9, 8), Prop('pot', 13, 8),
  Prop('sign', 17, 8), Prop('lantern', 21, 8), Prop('barrel', 26, 8),
  Prop('pot', 31, 8),

  // ---- plaza — the stone heart of town ----
  Prop('well', 20, 14), // fountain — covers 20-22 × 14-16
  Prop('bench', 15, 12), Prop('bench', 25, 12),
  Prop('bench', 15, 17), Prop('bench', 25, 17),
  Prop('lantern', 14, 11), Prop('lantern', 26, 11),
  Prop('lantern', 14, 18), Prop('lantern', 26, 18),
  Prop('bush', 13, 12), Prop('bush', 27, 18),

  // ---- east lane ----
  Prop('hut', 30, 14), // gravedigger's hut — covers 30-32 × 14-16
  Prop('pickaxe', 33, 16), Prop('lantern', 29, 14), Prop('bone', 32, 18),

  // ---- SE graveyard — fenced bare-earth yard, gate W onto the lane ----
  Prop('fenceH', 36, 14, [7]),
  Prop('fenceV', 42, 15, [4]),
  Prop('fenceH', 36, 19, [7]),
  Prop('fenceV', 36, 15, [1]), Prop('fenceV', 36, 18, [2]),
  Prop('grave', 38, 15), Prop('grave', 40, 15),
  Prop('grave', 38, 18), Prop('grave', 41, 18),
  Prop('grave37', 40, 17), // the special grave — marigolds, no name
  Prop('bone', 37, 18), Prop('mushroom', 41, 17),

  // ---- ofrenda garden ----
  Prop('ofrenda', 18, 22), // tiered shrine — covers 18-24 × 22-23
  Prop('lantern', 14, 21), Prop('lantern', 28, 21),

  // ---- the old ceiba (SE, past the lower graveyard) ----
  Prop('ceiba', 38, 21), // covers 38-40 × 21-23
  Prop('bush', 41, 22), Prop('mushroom', 37, 20),

  // ---- marigold field — flower rows on grass, west of the plaza ----
  Prop('marigold', 4, 13), Prop('marigold', 5, 13), Prop('marigold', 6, 13),
  Prop('marigold', 7, 13), Prop('marigold', 8, 13), Prop('marigold', 9, 13),
  Prop('marigold', 10, 13),
  Prop('marigold', 4, 15), Prop('marigold', 5, 15), Prop('marigold', 6, 15),
  Prop('marigold', 7, 15), Prop('marigold', 8, 15), Prop('marigold', 9, 15),
  Prop('marigold', 10, 15),
  Prop('marigold', 4, 17), Prop('marigold', 5, 17), Prop('marigold', 6, 17),
  Prop('marigold', 7, 17), Prop('marigold', 8, 17), Prop('marigold', 9, 17),
  Prop('marigold', 10, 17),
  Prop('marigold', 4, 19), Prop('marigold', 5, 19), Prop('marigold', 6, 19),
  Prop('marigold', 7, 19), Prop('marigold', 8, 19), Prop('marigold', 9, 19),
  Prop('marigold', 10, 19),
  Prop('marigold', 4, 21), Prop('marigold', 5, 21), Prop('marigold', 6, 21),
  Prop('marigold', 7, 21), Prop('marigold', 8, 21), Prop('marigold', 9, 21),
  Prop('marigold', 10, 21),
  Prop('hay', 5, 14), Prop('hay', 9, 20), Prop('sign', 10, 11),

  // ---- meadow scatter ----
  Prop('autumn', 11, 13), Prop('bush', 12, 16), Prop('mushroom', 11, 18),
  Prop('autumn', 28, 12), Prop('bush', 32, 11), Prop('boulder', 29, 12),
  Prop('autumn', 28, 18), Prop('mushroom', 30, 19), Prop('bone', 29, 21),
  Prop('bush', 32, 22), Prop('pine', 12, 21), Prop('bush', 14, 23),
  Prop('boulder', 13, 20),
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
  // flower stall counter — stand in the street, face north
  ActivitySlot('flower_stall', 10, 9, 0, -1),
  ActivitySlot('flower_stall', 11, 9, 0, -1),
  ActivitySlot('flower_stall', 12, 9, 0, -1),
  // cantina door
  ActivitySlot('cantina', 15, 8, 0, -1),
  ActivitySlot('cantina', 16, 8, 0, -1),
  // curiosity shop
  ActivitySlot('curiosity_shop', 28, 9, 0, -1),
  ActivitySlot('curiosity_shop', 29, 9, 0, -1),
  ActivitySlot('curiosity_shop', 30, 9, 0, -1),
  // fountain rim
  ActivitySlot('fountain', 19, 14, 1, 0),
  ActivitySlot('fountain', 23, 15, -1, 0),
  ActivitySlot('fountain', 21, 13, 0, 1),
  ActivitySlot('fountain', 21, 17, 0, -1),
  // gravedigger's door
  ActivitySlot('gravedigger_hut', 31, 17, 0, -1),
  ActivitySlot('gravedigger_hut', 33, 15, -1, 0),
  // cemetery lane — face east into the graveyard
  ActivitySlot('cemetery_lane', 34, 15, 1, 0),
  ActivitySlot('cemetery_lane', 34, 18, 1, 0),
  ActivitySlot('cemetery_lane', 34, 21, 1, 0),
  // grave 37
  ActivitySlot('grave_37', 39, 17, 1, 0),
  ActivitySlot('grave_37', 40, 18, 0, -1),
  // the old ceiba
  ActivitySlot('ancient_tree', 37, 22, 1, 0),
  ActivitySlot('ancient_tree', 39, 24, 0, -1),
  // ofrenda — face south to the shrine
  ActivitySlot('ofrenda', 19, 21, 0, 1),
  ActivitySlot('ofrenda', 21, 21, 0, 1),
  ActivitySlot('ofrenda', 24, 21, 0, 1),
  // plaza gathering
  ActivitySlot('plaza', 16, 12, 1, 0),
  ActivitySlot('plaza', 24, 12, -1, 0),
  ActivitySlot('plaza', 18, 17, 0, -1),
];

/// POI anchor tile (component position + label anchor).
const poiTiles = <String, (int, int)>{
  'bridge': (22, 1),
  'flower_stall': (11, 8),
  'cantina': (15, 7),
  'curiosity_shop': (28, 8),
  'fountain': (21, 14),
  'gravedigger_hut': (31, 15),
  'cemetery_lane': (34, 16),
  'grave_37': (40, 16),
  'ancient_tree': (39, 22),
  'ofrenda': (21, 22),
  'plaza': (18, 14),
};

double tileX(int tx) => tx * kTile + kTile / 2;
double tileY(int ty) => ty * kTile + kTile / 2;
double tileBottom(int ty) => ty * kTile + kTile;
