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
    show BlendMode, Canvas, Color, Offset, Paint, Rect, RRect, Radius;

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
    ...Tt.grass, ...Tt.pines, Tt.leafyTree, ...Tt.bushes,
    ...Tt.autumnTrees, ...Tt.hayPiles, ...Tt.mushrooms,
    Tt.sprout, Tt.sproutSmall,
    ...Tt.fenceRail, Tt.fencePost, Tt.fenceLong, Tt.sign,
    ...Tt.roofTerra, Tt.roofTerraGable,
    ...Tt.wallTanDoor, ...Tt.wallGrayDoor,
    ...Tt.winTan, ...Tt.doorTan, ...Tt.winGray, ...Tt.doorGray,
    Tt.archDark, Tt.urnPot, Tt.signRed,
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

  // 1. base earth — warm dark soil, reads as dusk
  c.drawRect(
    Rect.fromLTWH(0, 0, w, h),
    Paint()..color = const Color(0xFF241a14),
  );

  for (var y = 0; y < kMapTilesH; y++) {
    for (var x = 0; x < kMapTilesW; x++) {
      final ch = villageAscii[y][x];
      final r = Rect.fromLTWH(x * kTile, y * kTile, kTile, kTile);
      switch (ch) {
        case 'g':
          _grass(c, r, x, y, a);
        case 'd':
          _street(c, r, x, y);
        case 's':
          _plaza(c, r, x, y, a);
        case 'p':
          _marigold(c, r);
        case 'b':
          _deck(c, r);
        case 'w':
          c.drawRect(r, Paint()..color = const Color(0xFF141b2e));
        default:
          // 'e' — scatter subtle ground texture so the field isn't flat
          _earthSpeckle(c, r, x, y);
      }
    }
  }

  // 2. street/plaza edge accents — darker rim where walk-surface meets earth
  for (var y = 0; y < kMapTilesH; y++) {
    for (var x = 0; x < kMapTilesW; x++) {
      final ch = villageAscii[y][x];
      if (ch == 'd' || ch == 's' || ch == 'b') {
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

void _grass(Canvas c, Rect r, int x, int y, TileAssets a) {
  final pick = (x * 7 + y * 13) % 4;
  _tile(c, a.tt[pick], r);
  // dusk grade — the pack's noon-green reads wrong at night
  c.drawRect(r, Paint()..color = const Color(0x66121a20));
}

void _street(Canvas c, Rect r, int x, int y) {
  c.drawRect(r, Paint()..color = const Color(0xFF4a3a2c));
  // packed-clay speckle
  final p = Paint()..color = const Color(0xFF5a4838);
  final rr = Random(x * 31 + y * 17 + 7);
  for (var i = 0; i < 5; i++) {
    c.drawCircle(
      Offset(
        r.left + rr.nextDouble() * kTile,
        r.top + rr.nextDouble() * kTile,
      ),
      1.4,
      p,
    );
  }
  // occasional pebble
  if ((x * 11 + y * 5) % 7 == 0) {
    c.drawCircle(
      Offset(
        r.left + 8 + rr.nextDouble() * 16,
        r.top + 8 + rr.nextDouble() * 16,
      ),
      2.5,
      Paint()..color = const Color(0xFF6b5a48),
    );
  }
}

void _plaza(Canvas c, Rect r, int x, int y, TileAssets a) {
  // moonlit cobbles — procedural so the dusk grade stays consistent
  c.drawRect(r, Paint()..color = const Color(0xFF4d4658));
  final rr = Random(x * 53 + y * 29);
  final grout = Paint()..color = const Color(0xFF38323f);
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
        Paint()..color = const Color(0x22524b60));
  }
}

void _marigold(Canvas c, Rect r) {
  c.drawRect(r, Paint()..color = const Color(0xFF2e2118));
  final rr = Random(r.left.toInt() * 13 + r.top.toInt());
  for (var i = 0; i < 26; i++) {
    final gold = rr.nextBool();
    c.drawCircle(
      Offset(
        r.left + rr.nextDouble() * kTile,
        r.top + rr.nextDouble() * kTile,
      ),
      1.6 + rr.nextDouble() * 1.6,
      Paint()..color = gold ? const Color(0xFFe8962e) : const Color(0xFFc9741c),
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

void _earthSpeckle(Canvas c, Rect r, int x, int y) {
  final rr = Random(x * 97 + y * 41 + 3);
  final p = Paint()..color = const Color(0xFF2d211a);
  for (var i = 0; i < 4; i++) {
    c.drawCircle(
      Offset(
        r.left + rr.nextDouble() * kTile,
        r.top + rr.nextDouble() * kTile,
      ),
      1.2 + rr.nextDouble(),
      p,
    );
  }
  // rare tuft of dead grass
  if ((x * 13 + y * 7) % 11 == 0) {
    c.drawCircle(
      Offset(
        r.left + 6 + rr.nextDouble() * 20,
        r.top + 6 + rr.nextDouble() * 20,
      ),
      2.2,
      Paint()..color = const Color(0xFF3a3220),
    );
  }
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

void _tile(Canvas c, ui.Image? img, Rect dst) {
  if (img == null) {
    // loud placeholder — a missing tile must never kill the render pass
    c.drawRect(dst, Paint()..color = const Color(0xFFcc2266));
    return;
  }
  c.drawImageRect(
    img,
    Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
    dst,
    Paint(),
  );
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
        comp(
          p.tx,
          p.ty,
          1,
          1,
          (c, s) =>
              tile(c, a.tt[Tt.pines[(p.tx + p.ty) % Tt.pines.length]], 0, 0),
        );
      case 'autumn':
        comp(
          p.tx,
          p.ty,
          1,
          1,
          (c, s) => tile(
            c,
            a.tt[Tt.autumnTrees[(p.tx * 3 + p.ty) % Tt.autumnTrees.length]],
            0,
            0,
          ),
        );
      case 'leafy':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.leafyTree], 0, 0));
      case 'bush':
        comp(
          p.tx,
          p.ty,
          1,
          1,
          (c, s) => tile(
            c,
            a.tt[Tt.bushes[(p.tx + p.ty * 2) % Tt.bushes.length]],
            0,
            0,
          ),
        );
      case 'mushroom':
        comp(
          p.tx,
          p.ty,
          1,
          1,
          (c, s) => tile(c, a.tt[Tt.mushrooms[(p.tx + p.ty) % 2]], 0, 0),
        );
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
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.boulder], 0, 0));
      case 'pot':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.potTerra], 0, 0));
      case 'barrel':
      case 'log':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.crate], 0, 0));
      case 'bone':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.bone], 0, 0));
      case 'hay':
        comp(
          p.tx,
          p.ty,
          1,
          1,
          (c, s) =>
              tile(c, a.tt[Tt.hayPiles[(p.tx + p.ty) % 3]], 0, 0),
        );
      case 'pickaxe':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.pickaxe], 0, 0));
      case 'sign':
        comp(p.tx, p.ty, 1, 1, (c, s) => tile(c, a.tt[Tt.sign], 0, 0));
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
        comp(p.tx, p.ty, 1, 1, (c, s) {
          c.drawRect(
            Rect.fromLTWH(4, 26, 24, 4),
            Paint()..color = const Color(0xFF1c1512),
          );
          tile(c, a.tt[120], 0, -4); // rounded-top stone reads as gravestone
        });
      case 'grave37':
        comp(p.tx, p.ty, 1, 1, (c, s) {
          c.drawRect(
            Rect.fromLTWH(2, 26, 28, 5),
            Paint()..color = const Color(0xFF1c1512),
          );
          tile(c, a.tt[120], 0, -4);
          // unmarked plank + marigolds
          c.drawRect(
            Rect.fromLTWH(19, 6, 9, 14),
            Paint()..color = const Color(0xFF4a3524),
          );
          final rr = Random(37);
          for (var i = 0; i < 7; i++) {
            c.drawCircle(
              Offset(4 + rr.nextDouble() * 26, 24 + rr.nextDouble() * 6),
              2.2,
              Paint()..color = const Color(0xFFe8962e),
            );
          }
        });
      case 'fenceH':
        final n = p.args.isEmpty ? 1 : p.args[0];
        comp(p.tx, p.ty, n, 1, (c, s) {
          for (var i = 0; i < n; i++) {
            tile(c, a.tt[i % 3 == 0 ? 45 : 46], i * kTile, 0);
          }
        });
      case 'fenceV':
        final n = p.args.isEmpty ? 1 : p.args[0];
        comp(p.tx, p.ty, 1, n, (c, s) {
          for (var i = 0; i < n; i++) {
            tile(c, a.tt[Tt.fencePost], 0, i * kTile);
          }
        });
      case 'crypt':
        comp(p.tx, p.ty, 4, 2, (c, s) {
          tile(c, a.tt[96], 0, 0);
          tile(c, a.tt[97], 32, 0);
          tile(c, a.tt[98], 64, 0);
          tile(c, a.tt[96], 96, 0);
          tile(c, a.tt[96], 0, 32);
          tile(c, a.tt[112], 32, 32); // barred gate
          tile(c, a.tt[113], 64, 32);
          tile(c, a.tt[96], 96, 32);
        });
      case 'cantina':
        comp(p.tx, p.ty, 4, 4, (c, s) {
          final roof = [66, 64, 64, 66];
          final r1 = [72, 82, 84, 72];
          final r2 = [72, 73, 72, 73];
          final r3 = [73, 83, 84, 73];
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
          tile(c, a.tt[64], 0, 0);
          tile(c, a.tt[65], 32, 0);
          tile(c, a.tt[64], 64, 0);
          tile(c, a.tt[Tt.fencePost], 0, 32);
          tile(c, a.tt[Tt.fencePost], 64, 32);
          // counter plank
          c.drawRect(
            Rect.fromLTWH(6, 44, 84, 8),
            Paint()..color = const Color(0xFF5a4432),
          );
          // goods on the counter
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
              Offset(10 + rr.nextDouble() * 70, 40 - rr.nextDouble() * 4),
              3.2,
              Paint()..color = goods[i % 3],
            );
          }
        });
      case 'curiosity':
        comp(p.tx, p.ty, 4, 3, (c, s) {
          final roof = [66, 64, 65, 66];
          final mid = [74, 88, 90, 75];
          final bot = [74, 89, 74, 75];
          for (var i = 0; i < 4; i++) {
            tile(c, a.tt[roof[i]], i * kTile, 0);
            tile(c, a.tt[mid[i]], i * kTile, 32);
            tile(c, a.tt[bot[i]], i * kTile, 64);
          }
          tile(c, a.tt[Tt.signRed], 3 * kTile - 8, 40);
        });
      case 'hut':
        comp(p.tx, p.ty, 3, 3, (c, s) {
          tile(c, a.tt[64], 0, 0);
          tile(c, a.tt[65], 32, 0);
          tile(c, a.tt[66], 64, 0);
          tile(c, a.tt[74], 0, 32);
          tile(c, a.tt[75], 32, 32);
          tile(c, a.tt[74], 64, 32);
          tile(c, a.tt[75], 0, 64);
          tile(c, a.tt[89], 32, 64); // door
          tile(c, a.tt[74], 64, 64);
        });
      case 'well':
        comp(p.tx, p.ty, 3, 3, (c, s) {
          final ring = [124, 125, 126, 124, -1, 126, 125, 124, 125];
          for (var i = 0; i < 9; i++) {
            if (ring[i] < 0) continue;
            tile(c, a.tt[ring[i]], (i % 3) * kTile, (i ~/ 3) * kTile);
          }
          // water + shimmer
          c.drawCircle(
            Offset(48, 48),
            14,
            Paint()..color = const Color(0xFF1d2c48),
          );
          c.drawCircle(
            Offset(44, 44),
            5,
            Paint()..color = const Color(0xFF5a7cae),
          );
          // the urn on top
          tile(c, a.tt[Tt.urnPot], 32, -6);
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
          // framed photos (3)
          for (var i = 0; i < 3; i++) {
            final fx = 40.0 + i * 52;
            c.drawRect(
              Rect.fromLTWH(fx, 12, 22, 26),
              Paint()..color = const Color(0xFF5a4432),
            );
            c.drawRect(
              Rect.fromLTWH(fx + 2, 14, 18, 22),
              Paint()..color = const Color(0xFFe8dcc8),
            );
            c.drawCircle(
              Offset(fx + 11, 24),
              5,
              Paint()..color = const Color(0xFFb0927c),
            );
          }
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
            c.drawImageRect(
              img,
              Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
              Rect.fromLTWH(-16, -40, 128, 136),
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
