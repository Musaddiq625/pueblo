/// Tilemap renderer — bakes the authored terrain into a single ground
/// image and builds prop components (buildings, trees, fences, stalls,
/// graves) whose priority = foot-line y, so characters depth-sort
/// naturally in front of / behind them.
library;

import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/cache.dart';
import 'package:flame/components.dart';
import 'package:flutter/material.dart'
    show
        BlendMode,
        Canvas,
        Color,
        Offset,
        Paint,
        PaintingStyle,
        Rect,
        StrokeCap,
        RRect,
        Radius;

import 'na_terrain.dart';
import 'tile_index.dart';
import '../sim/world_map.dart';

/// Pre-loaded image bundle the renderer draws from.
class TileAssets {
  /// Tiny Town tile index → image.
  final Map<int, ui.Image> tt;

  /// Ninja Adventure floor atlas (16px cells).
  final ui.Image floor;

  /// Optional set-dressing images.
  final ui.Image? ceiba;
  const TileAssets({required this.tt, required this.floor, this.ceiba});

  /// Every Tiny Town tile referenced anywhere in the renderer — derived
  /// from the semantic lists so it can't drift out of sync.
  static final neededTt = <int>{
    ...Tt.grass, ...Tt.pines, Tt.leafyTree,
    ...Tt.autumnTrees, ...Tt.hayPiles, ...Tt.mushrooms,
    Tt.sprout, Tt.sproutSmall,
    ...Tt.fenceRail, Tt.fencePost, Tt.fenceLong, Tt.sign,
    ...Tt.roofTerra, Tt.roofTerraGable,
    ...Tt.wallTanDoor, ...Tt.wallGrayDoor,
    ...Tt.winTan, ...Tt.doorTan, ...Tt.winGray, ...Tt.doorGray,
    Tt.archDark, Tt.urnPot,
    ...Tt.stoneWall, Tt.boulder, ...Tt.logs, Tt.potTerra,
    ...Tt.fencePicket, Tt.crate,
    ...Tt.stoneArchBarred, Tt.pickaxe, Tt.pitchfork,
    Tt.keyItem, Tt.bowItem, Tt.bone,
    ...Tt.stonePath, ...Tt.stoneBlocks, Tt.winStone,
    Tt.flagRed, Tt.scythe, ...Tt.potWater,
  };

  static Future<TileAssets> load(Images images) async {
    final tt = <int, ui.Image>{};
    for (final i in neededTt) {
      tt[i] = await images.load(Tt.path(i));
    }
    final floor = await images.load(
      'village/ninja_adventure/tileset_floor.png',
    );
    ui.Image? ceiba;
    try {
      ceiba = await images.load('objects/ancient_tree.png');
    } catch (_) {}
    return TileAssets(tt: tt, floor: floor, ceiba: ceiba);
  }
}

// ---------- ground baking ----------

Future<ui.Image> bakeGround(TileAssets a) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  final w = kMapW, h = kMapH;

  // 1. terrain — grass is the continuous base; dirt streets/earth yards are
  //    carved through it with real autotile edges (the Stardew trick: the
  //    ground is one coherent surface, paths live IN it)
  for (var y = 0; y < kMapTilesH; y++) {
    for (var x = 0; x < kMapTilesW; x++) {
      final ch = villageAscii[y][x];
      final r = Rect.fromLTWH(x * kTile, y * kTile, kTile, kTile);
      switch (ch) {
        case 'g':
          _grass(c, r, x, y, a);
        case 'd':
          _dirt(c, r, x, y, a);
        case 'e':
          _dirt(c, r, x, y, a, packed: true);
        case 's':
          _plaza(c, r, x, y, a);
        case 'p':
          _marigold(c, r);
        case 'b':
          _deck(c, r);
        case 'w':
          c.drawRect(r, Paint()..color = const Color(0xFF141b2e));
        default:
          _grass(c, r, x, y, a);
      }
    }
  }

  // 2. one dusk wash over the whole ground — keeps every terrain family in
  //    the same light so the map reads as a single festival world
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0x33141c28),
  );

  // 3. rim accents on the paved/special surfaces (dirt already has fringe
  //    tiles baked into its edges)
  for (var y = 0; y < kMapTilesH; y++) {
    for (var x = 0; x < kMapTilesW; x++) {
      final ch = villageAscii[y][x];
      if (ch == 's' || ch == 'b' || ch == 'p') {
        _edgeRim(c, x, y, const Color(0x660f0a08));
      }
      if (ch == 'g') {
        _grassFringe(c, x, y);
      }
    }
  }

  final pic = rec.endRecording();
  return pic.toImage(w.ceil(), h.ceil());
}

/// Grass fill — real NA grass tiles so the ground has organic texture
/// everywhere instead of a flat wash.
void _grass(Canvas c, Rect r, int x, int y, TileAssets a) {
  final pick = naGrassFill[(x * 7 + y * 13) % naGrassFill.length];
  _floorCell(c, a, pick.$1, pick.$2, r);
}

/// Dirt — streets and packed-earth yards. Uses the pack's dirt-into-grass
/// autotile so paths get soft fringed edges where they meet grass.
/// [packed] darkens the cell — bare worked earth (cemetery/market yards).
void _dirt(Canvas c, Rect r, int x, int y, TileAssets a, {bool packed = false}) {
  bool isDirt(int nx, int ny) {
    if (nx < 0 || nx >= kMapTilesW || ny < 0 || ny >= kMapTilesH) {
      return false;
    }
    return 'desbp'.contains(villageAscii[ny][nx]);
  }

  final bits = naNeighborBits(isDirt, x, y);
  final (col, row) = naDirtTile(bits);
  _floorCell(c, a, col, row, r);
  if (packed) {
    c.drawRect(r, Paint()..color = const Color(0x401b1009));
  }
}

void _floorCell(Canvas c, TileAssets a, int col, int row, Rect dst) {
  c.drawImageRect(
    a.floor,
    Rect.fromLTWH(col * 16.0, row * 16.0, 16, 16),
    dst,
    Paint(),
  );
}

void _plaza(Canvas c, Rect r, int x, int y, TileAssets a) {
  // moonlit cobbles — light slate so the plaza reads as stone, not void
  c.drawRect(r, Paint()..color = const Color(0xFF7b7488));
  final rr = Random(x * 53 + y * 29);
  final grout = Paint()..color = const Color(0xFF575066);
  // running-bond cobble joints
  final off = (y % 2 == 0) ? 0.0 : 8.0;
  c.drawRect(Rect.fromLTWH(r.left, r.top + 10, kTile, 1.5), grout);
  c.drawRect(Rect.fromLTWH(r.left, r.top + 21, kTile, 1.5), grout);
  for (var i = 0; i < 3; i++) {
    c.drawRect(
        Rect.fromLTWH(r.left + (off + i * 11) % kTile, r.top, 1.5, 10.5),
        grout);
    c.drawRect(
        Rect.fromLTWH(r.left + ((off + 5.5) + i * 11) % kTile, r.top + 11.5,
            1.5, 9.5),
        grout);
    c.drawRect(
        Rect.fromLTWH(r.left + (off + i * 11) % kTile, r.top + 22.5, 1.5, 9.5),
        grout);
  }
  if (rr.nextDouble() < 0.4) {
    c.drawCircle(
        Offset(r.left + rr.nextDouble() * kTile,
            r.top + rr.nextDouble() * kTile),
        3 + rr.nextDouble() * 3,
        Paint()..color = const Color(0x2a8a8498));
  }
}

/// Gray rock cluster — the pack's boulder is an inventory icon in a
/// dark frame, not a world tile.
void _boulder(Canvas c) {
  final rock = Paint()..color = const Color(0xFF6e6878);
  final shade = Paint()..color = const Color(0xFF4a4456);
  c.drawOval(Rect.fromLTWH(4, 12, 20, 16), rock);
  c.drawOval(Rect.fromLTWH(14, 16, 16, 12), rock);
  c.drawOval(Rect.fromLTWH(4, 22, 26, 7), shade); // ground shadow
  c.drawOval(Rect.fromLTWH(7, 14, 8, 5), Paint()..color = const Color(0xFF8d8698));
}

void _crate(Canvas c) {
  final wood = Paint()..color = const Color(0xFF6a4e34);
  final rim = Paint()..color = const Color(0xFF4a3524);
  c.drawRect(Rect.fromLTWH(6, 8, 20, 20), wood);
  c.drawRect(
    Rect.fromLTWH(6, 8, 20, 20),
    Paint()
      ..color = const Color(0xFF3a2c20)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6,
  );
  c.drawRect(Rect.fromLTWH(6, 8, 20, 4), rim); // lid rim
  c.drawLine(
    const Offset(6, 8),
    const Offset(26, 28),
    Paint()
      ..color = const Color(0xFF4a3524)
      ..strokeWidth = 1.4,
  );
  c.drawLine(
    const Offset(26, 8),
    const Offset(6, 28),
    Paint()
      ..color = const Color(0xFF4a3524)
      ..strokeWidth = 1.4,
  );
}

void _bonePile(Canvas c) {
  final bone = Paint()
    ..color = const Color(0xFFd8d0bc)
    ..strokeWidth = 2
    ..strokeCap = StrokeCap.round;
  c.drawOval(
    Rect.fromLTWH(6, 24, 20, 5),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawLine(const Offset(9, 23), const Offset(21, 16), bone);
  c.drawLine(const Offset(11, 16), const Offset(23, 23), bone);
  c.drawCircle(const Offset(19, 19), 3.5, Paint()..color = const Color(0xFFe0d8c4));
  c.drawCircle(const Offset(17.8, 18.2), 1, Paint()..color = const Color(0xFF3a3230));
}

void _scrub(Canvas c, int seed) {
  final rr = Random(seed);
  c.drawOval(
    Rect.fromLTWH(5, 24, 22, 6),
    Paint()..color = const Color(0x55301f14),
  );
  final dark = Paint()..color = const Color(0xFF2e4a2a);
  final mid = Paint()..color = const Color(0xFF3d6034);
  c.drawOval(Rect.fromLTWH(5, 13, 15, 13), dark);
  c.drawOval(Rect.fromLTWH(13, 11, 14, 15), dark);
  c.drawOval(
    Rect.fromLTWH(8 + rr.nextDouble() * 4, 14, 9, 8),
    mid,
  );
  c.drawOval(Rect.fromLTWH(15, 13 + rr.nextDouble() * 3, 8, 7), mid);
}

void _autumnTree(Canvas c) {
  c.drawOval(
    Rect.fromLTWH(6, 26, 20, 5),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawRect(
    Rect.fromLTWH(14, 18, 4, 10),
    Paint()..color = const Color(0xFF4a3524),
  );
  final canopy = Paint()..color = const Color(0xFFc96f2e);
  c.drawCircle(const Offset(16, 12), 9, canopy);
  c.drawCircle(const Offset(9, 16), 5.5, canopy);
  c.drawCircle(const Offset(23, 16), 5.5, canopy);
  c.drawCircle(const Offset(13, 9), 3, Paint()..color = const Color(0xFFe8962e));
  c.drawCircle(const Offset(20, 14), 2.5, Paint()..color = const Color(0xFFe8962e));
}

void _pine(Canvas c) {
  c.drawOval(
    Rect.fromLTWH(7, 27, 18, 4),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawRect(
    Rect.fromLTWH(14, 21, 4, 8),
    Paint()..color = const Color(0xFF4a3524),
  );
  final dark = Paint()..color = const Color(0xFF2e5230);
  final light = Paint()..color = const Color(0xFF3d6b3a);
  for (final (i, tier) in [(4.0, 12.0), (10.0, 20.0), (16.0, 28.0)].indexed) {
    final top = tier.$1, base = tier.$2;
    final half = 6.0 + i * 4;
    c.drawPath(
      ui.Path()
        ..moveTo(16, top)
        ..lineTo(16 - half, base)
        ..lineTo(16 + half, base)
        ..close(),
      dark,
    );
    // west-lit edge
    c.drawPath(
      ui.Path()
        ..moveTo(16, top + 1)
        ..lineTo(16 - half + 2, base - 1)
        ..lineTo(16, base - 1)
        ..close(),
      light,
    );
  }
}

void _pot(Canvas c) {
  final terra = Paint()..color = const Color(0xFFb06a3a);
  final dark = Paint()..color = const Color(0xFF7a4526);
  c.drawOval(
    Rect.fromLTWH(9, 26, 14, 4),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawOval(Rect.fromLTWH(9, 12, 14, 16), terra);
  c.drawRect(Rect.fromLTWH(8, 9, 16, 5), terra);
  c.drawRect(Rect.fromLTWH(8, 9, 16, 2), dark);
  // marigold sprig
  c.drawLine(
    const Offset(16, 11),
    const Offset(16, 5),
    Paint()
      ..color = const Color(0xFF3d6034)
      ..strokeWidth = 1.4,
  );
  c.drawCircle(const Offset(16, 4), 3, Paint()..color = const Color(0xFFe8962e));
}

void _plankSign(Canvas c) {
  final wood = Paint()..color = const Color(0xFF6a4e34);
  final dark = Paint()..color = const Color(0xFF3a2c20);
  c.drawOval(
    Rect.fromLTWH(11, 28, 10, 3),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawRect(Rect.fromLTWH(14, 10, 4, 20), wood);
  // plank — angled for a hand-built look
  c.save();
  c.translate(16, 11);
  c.rotate(-0.06);
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(-13, -7, 26, 12),
      const Radius.circular(2),
    ),
    wood,
  );
  c.drawRRect(
    RRect.fromRectAndRadius(
      Rect.fromLTWH(-13, -7, 26, 12),
      const Radius.circular(2),
    ),
    Paint()
      ..color = const Color(0xFF3a2c20)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2,
  );
  // plank grain + nail
  c.drawLine(
    const Offset(-9, -1),
    const Offset(9, -1),
    Paint()
      ..color = const Color(0xFF3a2c20)
      ..strokeWidth = 0.8,
  );
  c.drawCircle(const Offset(0, -2), 1.2, dark);
  c.restore();
}

void _pickaxe(Canvas c) {
  final wood = Paint()
    ..color = const Color(0xFF6a4e34)
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round;
  final iron = Paint()
    ..color = const Color(0xFF8d8698)
    ..strokeWidth = 3
    ..strokeCap = StrokeCap.round;
  c.drawOval(
    Rect.fromLTWH(6, 26, 20, 4),
    Paint()..color = const Color(0x55301f14),
  );
  c.drawLine(const Offset(16, 26), const Offset(16, 10), wood);
  c.drawLine(const Offset(8, 12), const Offset(24, 8), iron);
}

/// Procedural gravestone — the pack's "stone" tiles are wall blocks; a
/// drawn rounded-top slab + mound reads as a grave at any zoom.
void _gravestone(Canvas c) {
  // mound shadow
  c.drawOval(
    Rect.fromLTWH(3, 24, 26, 7),
    Paint()..color = const Color(0x55301f14),
  );
  // rounded-top slab
  final slab = RRect.fromRectAndCorners(
    Rect.fromLTWH(8, 3, 16, 24),
    topLeft: const Radius.circular(8),
    topRight: const Radius.circular(8),
  );
  c.drawRRect(slab, Paint()..color = const Color(0xFF8a8390));
  c.drawRRect(
    slab,
    Paint()
      ..color = const Color(0xFF4f4a5c)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );
  // etched cross
  final etch = Paint()
    ..color = const Color(0xFF4f4a5c)
    ..strokeWidth = 1.2;
  c.drawLine(const Offset(16, 9), const Offset(16, 18), etch);
  c.drawLine(const Offset(12, 12.5), const Offset(20, 12.5), etch);
}

void _marigold(Canvas c, Rect r) {
  // warm loam base + a dense carpet of petals — the ofrenda path should
  // glow, not read as plowed mud
  c.drawRect(r, Paint()..color = const Color(0xFF4a3020));
  final rr = Random(r.left.toInt() * 13 + r.top.toInt());
  for (var i = 0; i < 52; i++) {
    final pick = rr.nextInt(3);
    c.drawCircle(
      Offset(
        r.left + rr.nextDouble() * kTile,
        r.top + rr.nextDouble() * kTile,
      ),
      1.8 + rr.nextDouble() * 1.8,
      Paint()
        ..color = pick == 0
            ? const Color(0xFFf0a838)
            : pick == 1
                ? const Color(0xFFd17a1f)
                : const Color(0xFFb85c14),
    );
  }
}

void _deck(Canvas c, Rect r) {
  c.drawRect(r, Paint()..color = const Color(0xFF3d2f22));
  // plank stripes (bridge runs north-south → vertical planks)
  final p = Paint()..color = const Color(0xFF2c2117);
  for (var dx = 0; dx < kTile; dx += 8) {
    c.drawRect(Rect.fromLTWH(r.left + dx, r.top, 2, kTile), p);
  }
  // rail shadows at column edges handled by prop pass — subtle inner shade:
  c.drawRect(
    Rect.fromLTWH(r.left, r.top, kTile, 3),
    Paint()..color = const Color(0x550f0a08),
  );
}


/// Dark rim inside a walk tile where its neighbors aren't walk-surface.
void _edgeRim(Canvas c, int x, int y, Color col) {
  bool o(int nx, int ny) {
    if (nx < 0 || nx >= kMapTilesW || ny < 0 || ny >= kMapTilesH) return true;
    return !'dsbp'.contains(villageAscii[ny][nx]);
  }

  final p = Paint()..color = col;
  final l = x * kTile, t = y * kTile;
  if (o(x, y - 1)) c.drawRect(Rect.fromLTWH(l, t, kTile, 3), p);
  if (o(x, y + 1)) c.drawRect(Rect.fromLTWH(l, t + kTile - 3, kTile, 3), p);
  if (o(x - 1, y)) c.drawRect(Rect.fromLTWH(l, t, 3, kTile), p);
  if (o(x + 1, y)) c.drawRect(Rect.fromLTWH(l + kTile - 3, t, 3, kTile), p);
}

/// Fringe of grass color bleeding onto neighboring non-grass tiles.
void _grassFringe(Canvas c, int x, int y) {
  final p = Paint()..color = const Color(0xFF2f4526);
  final l = x * kTile, t = y * kTile;
  bool isG(int nx, int ny) =>
      nx >= 0 &&
      nx < kMapTilesW &&
      ny >= 0 &&
      ny < kMapTilesH &&
      villageAscii[ny][nx] == 'g';
  if (!isG(x, y - 1)) {
    c.drawRect(Rect.fromLTWH(l, t, kTile, 2), p);
  }
  if (!isG(x, y + 1)) {
    c.drawRect(Rect.fromLTWH(l, t + kTile - 2, kTile, 2), p);
  }
  if (!isG(x - 1, y)) {
    c.drawRect(Rect.fromLTWH(l, t, 2, kTile), p);
  }
  if (!isG(x + 1, y)) {
    c.drawRect(Rect.fromLTWH(l + kTile - 2, t, 2, kTile), p);
  }
}

// ---------- river water (animated overlay above baked riverbed) ----------

class RiverComponent extends PositionComponent {
  double _t = 0;
  RiverComponent()
    : super(
        position: Vector2(0, 0),
        size: Vector2(kMapW, 2 * kTile),
        priority: -999999999 + 1,
      );

  @override
  void update(double dt) {
    _t += dt;
  }

  @override
  void render(Canvas canvas) {
    // base water
    canvas.drawRect(size.toRect(), Paint()..color = const Color(0xFF182238));
    // moonlit flow bands
    final p = Paint()
      ..color = const Color(0xFF2c3d5e)
      ..strokeWidth = 2;
    for (var i = 0; i < 14; i++) {
      final y = 8.0 + (i % 4) * 16 + sin(_t * 0.8 + i) * 3;
      final speed = 30 + (i % 3) * 14;
      final x0 = ((_t * speed + i * 120) % (size.x + 120)) - 60;
      canvas.drawLine(Offset(x0, y), Offset(x0 + 26, y), p);
    }
    // bank foam line
    canvas.drawRect(
      Rect.fromLTWH(0, size.y - 3, size.x, 3),
      Paint()..color = const Color(0xFF24324e),
    );
  }
}

/// Candle glow — a row of additive warm halos that breathe/flicker.
/// Screen blend brightens whatever's beneath; spirits passing through
/// catch the light instead of being hidden by it.
class CandleFlickerComponent extends PositionComponent {
  final int count;
  double _t = 0;
  CandleFlickerComponent(Vector2 pos, {this.count = 5})
    : super(position: pos, priority: 2000000);

  @override
  void update(double dt) {
    _t += dt;
  }

  @override
  void render(Canvas canvas) {
    for (var i = 0; i < count; i++) {
      final x = i * 46.0 + (i.isOdd ? 8 : 0);
      final flick = 1 + 0.35 * sin(_t * 7 + i * 2.1) +
          0.15 * sin(_t * 13 + i * 4.7);
      canvas.drawCircle(
        Offset(x, 0),
        14 * flick,
        Paint()
          ..color = const Color(0x44ffb45e)
          ..blendMode = BlendMode.plus,
      );
      canvas.drawCircle(
        Offset(x, 0),
        4.5,
        Paint()..color = const Color(0xFFffd98a),
      );
      // tiny flame tip
      canvas.drawCircle(
        Offset(x, -6 - 2 * sin(_t * 9 + i)),
        2,
        Paint()..color = const Color(0xFFffe9b0),
      );
    }
  }
}

// ---------- props ----------

/// A prop component: paints [paint] inside its own bounds; [priority] is
/// the foot-line world y so characters sort in front of / behind it.
class PropComponent extends PositionComponent {
  final void Function(Canvas, Vector2) painter;
  PropComponent({
    required Vector2 position,
    required Vector2 size,
    required double footY,
    required this.painter,
  }) : super(position: position, size: size, priority: footY.round());

  @override
  void render(Canvas canvas) => painter(canvas, size);
}

/// Build all prop components for the village.
List<PropComponent> buildProps(TileAssets a) {
  final out = <PropComponent>[];
  PropComponent comp(
    int tx,
    int ty,
    int wTiles,
    int hTiles,
    void Function(Canvas, Vector2) draw, {
    double? footY,
  }) {
    final c = PropComponent(
      position: Vector2(tx * kTile, ty * kTile),
      size: Vector2(wTiles * kTile, hTiles * kTile),
      footY: footY ?? (ty + hTiles) * kTile,
      painter: draw,
    );
    out.add(c);
    return c;
  }

  void tile(Canvas c, ui.Image? img, double dx, double dy, [double s = 1]) {
    if (img == null) {
      c.drawRect(
        Rect.fromLTWH(dx, dy, kTile * s, kTile * s),
        Paint()..color = const Color(0xFFcc2266),
      );
      return;
    }
    c.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(dx, dy, kTile * s, kTile * s),
      Paint(),
    );
  }

  for (final p in villageProps) {
    switch (p.kind) {
      case 'pine':
        // the pack's pine tiles are two-tree clusters with a heavy maroon
        // outline — at 32px they read as broken green fragments
        comp(p.tx, p.ty, 1, 1, (c, s) => _pine(c));
      case 'autumn':
        // tile 15's trunk is invisible at 32px — reads as a floating orange
        // ball. A drawn trunk + canopy keeps it a tree at any zoom.
        comp(p.tx, p.ty, 1, 1, (c, s) => _autumnTree(c));
      case 'leafy':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.leafyTree], 0, 0));
      case 'bush':
        // the pack has no standalone scrub tile — every candidate is a
        // sliver of a multi-tile tree. A clump of dark-green ellipses reads
        // cleanly at any zoom.
        comp(p.tx, p.ty, 1, 1, (c, s) => _scrub(c, p.tx * 7 + p.ty));
      case 'mushroom':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.mushrooms[0]], 0, 0));
      case 'marigold':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          final rr = Random(p.tx * 31 + p.ty);
          for (var i = 0; i < 8; i++) {
            c.drawCircle(
              Offset(6 + rr.nextDouble() * 20, 6 + rr.nextDouble() * 20),
              2.4,
              Paint()
                ..color = rr.nextBool()
                    ? const Color(0xFFe8962e)
                    : const Color(0xFFd17a1f),
            );
          }
        });
      case 'boulder':
        comp(p.tx, p.ty, 1, 1, (c, s) => _boulder(c));
      case 'pot':
        comp(p.tx, p.ty, 1, 1, (c, s) => _pot(c));
      case 'barrel':
      case 'log':
        comp(p.tx, p.ty, 1, 1, (c, s) => _crate(c));
      case 'bone':
        comp(p.tx, p.ty, 1, 1, (c, s) => _bonePile(c));
      case 'hay':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          // 34+35 are left/right halves of one mound — join them at the
          // cell's bottom edge
          tile(c, a.tt[Tt.hayPiles[0]], 0, 16, 0.5);
          tile(c, a.tt[Tt.hayPiles[1]], 16, 16, 0.5);
        });
      case 'pickaxe':
        comp(p.tx, p.ty, 1, 1, (c, s) => _pickaxe(c));
      case 'sign':
        // tile 95 reads as a bright-red "no entry" marker — a wooden plank
        // on a post matches the pueblo palette
        comp(p.tx, p.ty, 1, 1, (c, s) => _plankSign(c));
      case 'bench':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          final wood = Paint()..color = const Color(0xFF5a4432);
          final dark = Paint()..color = const Color(0xFF3a2c20);
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(2, 12, 28, 7),
              const Radius.circular(2),
            ),
            wood,
          );
          c.drawRect(Rect.fromLTWH(5, 19, 4, 8), dark);
          c.drawRect(Rect.fromLTWH(23, 19, 4, 8), dark);
        });
      case 'lantern':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          tile(c, a.tt[Tt.fencePost], 0, 0);
          // glowing head
          c.drawCircle(
            Offset(16, 8),
            9,
            Paint()..color = const Color(0x33ffb45e),
          );
          c.drawCircle(
            Offset(16, 8),
            4.5,
            Paint()..color = const Color(0xFFffd98a),
          );
        });
      case 'grave':
        comp(p.tx, p.ty, 1, 1, (c, s) => _gravestone(c));
      case 'grave37':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          _gravestone(c);
          // unmarked plank + marigolds — the grave nobody named
          c.drawRect(
            Rect.fromLTWH(20, 8, 8, 15),
            Paint()..color = const Color(0xFF4a3524),
          );
          final rr = Random(37);
          for (var i = 0; i < 7; i++) {
            c.drawCircle(
              Offset(3 + rr.nextDouble() * 26, 24 + rr.nextDouble() * 6),
              2.2,
              Paint()..color = const Color(0xFFe8962e),
            );
          }
        });
      case 'fenceH':
        final n = p.args.isEmpty ? 1 : p.args[0];
        comp(p.tx, p.ty, n, 1, (c, s) {
          // continuous rail under the pieces — unifies joins at gates/corners
          c.drawRect(
            Rect.fromLTWH(0, 13, s.x, 3),
            Paint()..color = const Color(0xFF4a3524),
          );
          c.drawRect(
            Rect.fromLTWH(0, 20, s.x, 3),
            Paint()..color = const Color(0xFF4a3524),
          );
          for (var i = 0; i < n; i++) {
            tile(c, a.tt[i % 3 == 0 ? 45 : 46], i * kTile, 0);
          }
        });
      case 'fenceV':
        final n = p.args.isEmpty ? 1 : p.args[0];
        comp(p.tx, p.ty, 1, n, (c, s) {
          // vertical rail — without it the column reads as floating posts
          c.drawRect(
            Rect.fromLTWH(15, 0, 4, s.y),
            Paint()..color = const Color(0xFF4a3524),
          );
          for (var i = 0; i < n; i++) {
            tile(c, a.tt[Tt.fencePost], 0, i * kTile);
          }
        });
      case 'crypt':
        comp(p.tx, p.ty, 4, 2, (c, s) {
          final w = s.x;
          // body — moonlit stone wall with block joints
          c.drawRect(
            Rect.fromLTWH(2, 8, w - 4, 48),
            Paint()..color = const Color(0xFF6a6478),
          );
          final j = Paint()
            ..color = const Color(0xFF524c60)
            ..strokeWidth = 1;
          for (var yy = 18.0; yy < 52; yy += 12) {
            c.drawLine(Offset(2, yy), Offset(w - 2, yy), j);
          }
          c.drawRect(
            Rect.fromLTWH(2, 8, w - 4, 48),
            Paint()
              ..color = const Color(0xFF4f4a5c)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.5,
          );
          // cornice + pediment
          c.drawRect(
            Rect.fromLTWH(0, 6, w, 5),
            Paint()..color = const Color(0xFF575066),
          );
          c.drawRRect(
            RRect.fromRectAndCorners(
              Rect.fromLTWH(w / 2 - 14, 0, 28, 7),
              topLeft: const Radius.circular(3),
              topRight: const Radius.circular(3),
            ),
            Paint()..color = const Color(0xFF6a6478),
          );
          // arch door (the pack's real gothic arch pair)
          tile(c, a.tt[112], w / 2 - 32, 26);
          tile(c, a.tt[113], w / 2, 26);
          // threshold step
          c.drawRect(
            Rect.fromLTWH(w / 2 - 38, 56, 76, 6),
            Paint()..color = const Color(0xFF575066),
          );
        });
      case 'cantina':
        comp(p.tx, p.ty, 4, 4, (c, s) {
          // house kit: 72/74 = edge caps, 73 = wall+door, 84/88 = wall+window
          final roof = [66, 64, 64, 66];
          final r1 = [72, 84, 88, 74];
          final r2 = [72, 88, 84, 74];
          final r3 = [72, 73, 84, 74];
          for (var i = 0; i < 4; i++) {
            tile(c, a.tt[roof[i]], i * kTile, 0);
            tile(c, a.tt[r1[i]], i * kTile, 32);
            tile(c, a.tt[r2[i]], i * kTile, 64);
            tile(c, a.tt[r3[i]], i * kTile, 96);
          }
        });
      case 'stall':
        final v = p.args.isEmpty ? 0 : p.args[0];
        comp(p.tx, p.ty, 3, 2, (c, s) {
          final w = s.x;
          // posts
          final post = Paint()..color = const Color(0xFF4a3524);
          c.drawRect(Rect.fromLTWH(6, 18, 4, 42), post);
          c.drawRect(Rect.fromLTWH(w - 10, 18, 4, 42), post);
          // striped awning — marigold/cream, scalloped hem
          final seg = (w - 8) / 6;
          for (var i = 0; i < 6; i++) {
            c.drawRect(
              Rect.fromLTWH(4 + i * seg, 2, seg, 16),
              Paint()
                ..color = i.isEven
                    ? const Color(0xFFe8962e)
                    : const Color(0xFFe8dcc8),
            );
            c.drawCircle(
              Offset(4 + i * seg + seg / 2, 18),
              seg / 2.4,
              Paint()
                ..color = i.isEven
                    ? const Color(0xFFe8962e)
                    : const Color(0xFFe8dcc8),
            );
          }
          // counter
          c.drawRect(
            Rect.fromLTWH(4, 42, w - 8, 6),
            Paint()..color = const Color(0xFF5a4432),
          );
          c.drawRect(
            Rect.fromLTWH(6, 48, w - 12, 12),
            Paint()..color = const Color(0xFF3a2c20),
          );
          // goods on the counter — flower colors for the marigold stall,
          // curio colors for the rest
          final rr = Random(p.tx * 7 + v);
          final goods = v == 0
              ? [
                  const Color(0xFFe8962e),
                  const Color(0xFFe0607a),
                  const Color(0xFFf2c94c),
                ]
              : [
                  const Color(0xFF7ec4b6),
                  const Color(0xFF9a7bd8),
                  const Color(0xFFe0e0e0),
                ];
          for (var i = 0; i < 9; i++) {
            c.drawCircle(
              Offset(10 + rr.nextDouble() * (w - 20), 38 - rr.nextDouble() * 4),
              3.2,
              Paint()..color = goods[i % 3],
            );
          }
        });
      case 'curiosity':
        comp(p.tx, p.ty, 4, 3, (c, s) {
          final roof = [66, 64, 65, 66];
          final mid = [72, 84, 90, 74];
          final bot = [72, 73, 84, 74];
          for (var i = 0; i < 4; i++) {
            tile(c, a.tt[roof[i]], i * kTile, 0);
            tile(c, a.tt[mid[i]], i * kTile, 32);
            tile(c, a.tt[bot[i]], i * kTile, 64);
          }
          // hanging wooden shop sign
          c.save();
          c.translate(3 * kTile + 4, 46);
          c.rotate(0.05);
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(-16, -9, 30, 15),
              const Radius.circular(2),
            ),
            Paint()..color = const Color(0xFF6a4e34),
          );
          c.drawRRect(
            RRect.fromRectAndRadius(
              Rect.fromLTWH(-16, -9, 30, 15),
              const Radius.circular(2),
            ),
            Paint()
              ..color = const Color(0xFF3a2c20)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 1.2,
          );
          c.drawLine(
            const Offset(-11, -2),
            const Offset(9, -2),
            Paint()
              ..color = const Color(0xFFe8dcc8)
              ..strokeWidth = 1.2,
          );
          c.restore();
        });
      case 'hut':
        comp(p.tx, p.ty, 3, 3, (c, s) {
          // roof | cap-window-cap | cap-door-cap
          tile(c, a.tt[64], 0, 0);
          tile(c, a.tt[65], 32, 0);
          tile(c, a.tt[66], 64, 0);
          tile(c, a.tt[72], 0, 32);
          tile(c, a.tt[84], 32, 32);
          tile(c, a.tt[74], 64, 32);
          tile(c, a.tt[72], 0, 64);
          tile(c, a.tt[73], 32, 64); // door
          tile(c, a.tt[74], 64, 64);
        });
      case 'well':
        comp(p.tx, p.ty, 3, 3, (c, s) {
          const cx = 48.0;
          // ground shadow
          c.drawOval(
            Rect.fromLTWH(8, 74, 80, 14),
            Paint()..color = const Color(0x55301f14),
          );
          // stone ring — octagonal basin built from stacked courses
          final stone = Paint()..color = const Color(0xFF6a6478);
          final rim = Paint()..color = const Color(0xFF8d8698);
          c.drawCircle(const Offset(cx, 58), 34, stone);
          c.drawCircle(
            const Offset(cx, 58),
            34,
            Paint()
              ..color = const Color(0xFF4f4a5c)
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
          // rim highlight + block joints
          c.drawCircle(const Offset(cx, 54), 30, rim);
          final j = Paint()
            ..color = const Color(0xFF524c60)
            ..strokeWidth = 1.2;
          for (var i = 0; i < 8; i++) {
            final ang = i * 3.14159 / 4;
            c.drawLine(
              Offset(cx + 26 * cos(ang), 54 + 26 * sin(ang)),
              Offset(cx + 34 * cos(ang), 58 + 34 * sin(ang)),
              j,
            );
          }
          // water
          c.drawCircle(
            const Offset(cx, 52),
            24,
            Paint()..color = const Color(0xFF1d2c48),
          );
          c.drawCircle(
            const Offset(cx - 6, 46),
            8,
            Paint()..color = const Color(0xFF3d5a86),
          );
          c.drawCircle(
            const Offset(cx - 9, 44),
            3,
            Paint()..color = const Color(0xFF7ea6d8),
          );
          // center column + spout
          c.drawRect(
            Rect.fromLTWH(cx - 5, 20, 10, 24),
            Paint()..color = const Color(0xFF6a6478),
          );
          c.drawRect(
            Rect.fromLTWH(cx - 8, 14, 16, 8),
            Paint()..color = const Color(0xFF8d8698),
          );
          c.drawCircle(
            const Offset(cx, 12),
            4,
            Paint()..color = const Color(0xFF8d8698),
          );
        });
      case 'ofrenda':
        comp(p.tx, p.ty, 7, 2, (c, s) {
          // two stone tiers
          final bot = [124, 125, 126, 124, 125, 126, 124];
          for (var i = 0; i < 7; i++) {
            tile(c, a.tt[bot[i]], i * kTile, 32);
          }
          for (var i = 1; i < 6; i++) {
            tile(c, a.tt[i.isEven ? 125 : 126], i * kTile, 8);
          }
          // framed photos — a row of the remembered dead… and one bare
          // frame. The middle slot is Solorio's: stolen, a dark
          // empty panel where his face hung.
          for (var i = 0; i < 3; i++) {
            final fx = 40.0 + i * 52;
            final bare = i == 1;
            c.drawRect(
              Rect.fromLTWH(fx, 12, 22, 26),
              Paint()
                ..color = bare
                    ? const Color(0xFF2a1f16) // loosened, darker wood
                    : const Color(0xFF5a4432),
            );
            c.drawRect(
              Rect.fromLTWH(fx + 2, 14, 18, 22),
              Paint()
                ..color = bare
                    ? const Color(0xFF171320) // the hollow where he was
                    : const Color(0xFFe8dcc8),
            );
            if (!bare) {
              c.drawCircle(
                Offset(fx + 11, 24),
                5,
                Paint()..color = const Color(0xFFb0927c),
              );
            }
          }
          // where his portrait stood, a stray petal lodged in the empty frame
          c.drawCircle(
            const Offset(40 + 52 + 11, 30),
            1.6,
            Paint()..color = const Color(0xFFe8962e),
          );
          // marigold scatter at the base
          final rr = Random(11);
          for (var i = 0; i < 20; i++) {
            c.drawCircle(
              Offset(4 + rr.nextDouble() * 216, 52 + rr.nextDouble() * 10),
              2,
              Paint()..color = const Color(0xFFe8962e),
            );
          }
        });
      case 'ceiba':
        comp(p.tx, p.ty, 3, 3, (c, s) {
          final img = a.ceiba;
          if (img != null) {
            // the sheet is a 4x3 contact grid — crop the big leaf tree
            // at cell (0,0) (ink spans 0-107 × 0-121)
            c.drawImageRect(
              img,
              const Rect.fromLTWH(0, 0, 112, 122),
              const Rect.fromLTWH(-16, -40, 128, 136),
              Paint(),
            );
          } else {
            tile(c, a.tt[Tt.pines[0]], 0, 0, 3);
          }
        });
    }
  }
  return out;
}
