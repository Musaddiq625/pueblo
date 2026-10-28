/// Tiny Town tile index — semantic names → `Tiles/tile_NNNN.png`.
/// Verified against the pack's contact sheet (see VILLAGE_REBUILD_PLAN).
/// Tiles are 16×16 source px.
library;

abstract final class Tt {
  // ground / vegetation
  static const grass = [0, 1, 2]; // plain + tufts + flowers — 3 is a mound fragment
  static const pines = [6, 20]; // 8/19 are tree-fragment slivers, not whole pines
  static const leafyTree = 16; // round green tree w/ trunk
  // no usable bush tile — the pack's scrub tiles are all slivers of larger
  // multi-tile trees; 'bush' props are drawn procedurally
  static const autumnTrees = [15]; // round orange tree w/ trunk — 27 is a trunkless cone
  static const hayPiles = [34, 35]; // left/right halves of one mound
  static const mushrooms = [29]; // 30 is a tree-fragment sliver
  static const sprout = 17;
  static const sproutSmall = 18;

  // structures
  static const fenceRail = [45, 46]; // horizontal rail + posts
  static const fencePost = 47;
  static const fenceLong = 80;
  static const sign = 95; // red banner + pole — 81 is a bare frame plaque

  // house kit — terracotta set
  static const roofTerra = [64, 65];
  static const roofTerraGable = 66;
  static const wallTanDoor = [72, 73];
  static const wallGrayDoor = [74, 75];
  static const winTan = [82, 84];
  static const doorTan = [83, 85];
  static const winGray = [88, 90];
  static const doorGray = [89, 91];
  static const archDark = 92; // crypt/dungeon doorway
  static const urnPot = 94; // beehive urn / bread oven
  static const signRed = 95;

  // stone kit
  static const stoneWall = [96, 97, 98];
  static const fencePicket = [99, 100];
  // NB: 103-118 + 129-131 are inventory-style icons in dark frames, not
  // world tiles — props using them render as dark boxes. They're kept out
  // of the prop painters; the indices stay for reference.
  static const crate = 105;
  static const boulder = 103;
  static const logs = [101, 102];
  static const potTerra = 93; // proper world-tile pot (104 is an icon)
  static const stoneArchBarred = [112, 113]; // crypt gate w/ iron bars
  static const pickaxe = 114;
  static const pitchfork = 115;
  static const keyItem = 116;
  static const bowItem = 117;
  static const bone = 118;
  static const stonePath = [119, 120];
  static const stoneBlocks = [124, 125, 126];
  static const winStone = 127;
  static const flagRed = 128;
  static const scythe = 129;
  static const potWater = [130, 131]; // one holds water

  /// Convenience: tile asset path for Flame `images.load`.
  static String path(int i) =>
      'village/tiny_town/Tiles/tile_${i.toString().padLeft(4, '0')}.png';
}
