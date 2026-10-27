/// Ninja Adventure `tileset_floor.png` — atlas coordinates (16 px cells,
/// 22 cols × 26 rows) + the terrain blob table extracted from the pack's
/// `content/map/tileset.tres` (Godot peering bits → tile lookup).
///
/// Region map (verified by inspection):
///   rows 0-3   desert-sand blobs (left: sand-into-tan, right: pale)
///   rows 4-6   scatter decals + transition strips
///   rows 7-11  LEFT: dirt-into-grass blob (terrain 1, documented below)
///              RIGHT: dirt-into-dark-soil blob
///   row  12    plain grass fill variants (cols 0-4)
///   rows 14-18 LEFT: pale paving (light stone); RIGHT: dark-soil blob —
///              dark packed earth w/ pale stone scalloped edges on tan clay
///   rows 19-25 LEFT: pale blue (snow); RIGHT: autumn-leaves blob
library;

/// Atlas coords for the fills we paint (col, row in 16px cells).
abstract final class NaTile {
  /// Grass fill (plain green + sparse variants).
  static const grassA = (0, 12);
  static const grassB = (1, 12);
  static const grassC = (2, 12);
  static const grassD = (3, 12);

  /// Dark soil — from the right-side blob's dark interior tiles.
  static const soilA = (16, 16);
  static const soilB = (17, 16);
  static const soilC = (16, 17);

  /// Light packed clay — the blob's surround (street/plaza floor).
  static const clayA = (12, 15);
  static const clayB = (13, 15);

  /// Pale paving — solid light stone from the left pale region.
  static const paveA = (4, 15);
  static const paveB = (6, 15);

  /// Autumn leaves — marigold carpet from the bottom-right blob.
  static const leavesA = (17, 23);
  static const leavesB = (16, 22);

  /// Pale stone slab — bridge deck.
  static const slabA = (8, 15);
}

/// The documented dirt-into-green-grass blob (terrain 1). `bits` encodes
/// neighbor terrain per direction, order TL,T,TR,L,R,BL,B,BR, 1 = dirt.
/// Generated from `content/map/tileset.tres` (see STARDEW_RESEARCH notes).
const naBlob = <(int, int, int)>[
  (0, 7, 0x0B), (1, 7, 0x1F), (2, 7, 0x16),
  (3, 7, 0x02), (4, 7, 0x0A), (5, 7, 0x1E),
  (6, 7, 0x1B), (7, 7, 0x12), (8, 7, 0x1A),
  (9, 7, 0xDB),
  (0, 8, 0x6B), (1, 8, 0xFF), (2, 8, 0xD6),
  (3, 8, 0x42), (4, 8, 0x6A), (5, 8, 0xFE),
  (6, 8, 0xFB), (7, 8, 0xD2), (8, 8, 0xFA),
  (9, 8, 0x7E),
  (0, 9, 0x68), (1, 9, 0xF8), (2, 9, 0xD0),
  (3, 9, 0x40), (4, 9, 0x4B), (5, 9, 0xDF),
  (6, 9, 0x7F), (7, 9, 0x56), (8, 9, 0x5F),
  (9, 9, 0x5B), (10, 9, 0x5E),
  (0, 10, 0x08), (1, 10, 0x18), (2, 10, 0x10),
  (3, 10, 0x00), (4, 10, 0x48), (5, 10, 0xD8),
  (6, 10, 0x78), (7, 10, 0x50), (8, 10, 0x58),
  (9, 10, 0x7A), (10, 10, 0xDA),
  (0, 11, 0xFF), (1, 11, 0xFF),
  (4, 11, 0x4A), (5, 11, 0xDE), (6, 11, 0x7B),
  (7, 11, 0x52), (8, 11, 0x5A),
];

/// Grass-fill tiles also declared in the terrain set (plain, no feature).
const naGrassFill = <(int, int)>[
  (2, 11), (3, 11), (0, 12), (1, 12), (2, 12), (3, 12), (4, 12)
];

/// Bit order: TL,T,TR,L,R,BL,B,BR in bits 7..0.
///   TL=0x80 T=0x40 TR=0x20 L=0x10 R=0x08 BL=0x04 B=0x02 BR=0x01
const _corners = [0x80, 0x20, 0x04, 0x01]; // TL, TR, BL, BR
const _edges = [0x40, 0x10, 0x08, 0x02]; // T, L, R, B
const _cornerDeps = [
  [0x40, 0x10], // TL depends on T & L
  [0x40, 0x08], // TR depends on T & R
  [0x10, 0x02], // BL depends on L & B
  [0x08, 0x02], // BR depends on R & B
];

/// Match a dirt blob tile for a cell whose 8 neighbors' dirt-ness = [bits].
/// Fallback order: exact → drop corner bits where either adjacent edge is 0
/// → edge bits only → dirt fill.
(int, int) naDirtTile(int bits) {
  for (final t in naBlob) {
    if (t.$3 == bits) return (t.$1, t.$2);
  }
  // Ignore corner bits where either adjacent edge neighbor is grass —
  // those corners are visually covered by edge transitions anyway.
  var cmask = 0;
  for (var i = 0; i < 4; i++) {
    if (bits & _cornerDeps[i][0] == 0 || bits & _cornerDeps[i][1] == 0) {
      cmask |= _corners[i];
    }
  }
  for (final t in naBlob) {
    if (t.$3 & ~cmask == (bits & ~cmask)) return (t.$1, t.$2);
  }
  final edgeOnly =
      bits & (_edges[0] | _edges[1] | _edges[2] | _edges[3]);
  for (final t in naBlob) {
    if (t.$3 & 0x5A == edgeOnly) return (t.$1, t.$2);
  }
  return (0, 11); // dirt fill — last resort
}

/// Bit helper: build the 8-bit neighbor mask for cell (x,y) where
/// [isSet] reports whether a cell counts as dirt.
int naNeighborBits(bool Function(int x, int y) isSet, int x, int y) {
  var b = 0;
  if (isSet(x - 1, y - 1)) b |= 0x80;
  if (isSet(x, y - 1)) b |= 0x40;
  if (isSet(x + 1, y - 1)) b |= 0x20;
  if (isSet(x - 1, y)) b |= 0x10;
  if (isSet(x + 1, y)) b |= 0x08;
  if (isSet(x - 1, y + 1)) b |= 0x04;
  if (isSet(x, y + 1)) b |= 0x02;
  if (isSet(x + 1, y + 1)) b |= 0x01;
  return b;
}
