/// Authored-map contract tests — the tilemap is the world's foundation;
/// a bad row or unreachable slot breaks the whole sim silently.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/sim/navgrid.dart';
import 'package:pueblo/sim/world_map.dart';

void main() {
  test('map is exactly kMapTilesW x kMapTilesH', () {
    expect(villageAscii.length, kMapTilesH);
    for (var y = 0; y < kMapTilesH; y++) {
      expect(
        villageAscii[y].length,
        kMapTilesW,
        reason: 'row $y has ${villageAscii[y].length} cols',
      );
    }
  });

  test('every activity slot sits on a walkable tile', () {
    final nav = NavGrid.build();
    for (final s in villageSlots) {
      expect(
        nav.walkable(s.tx, s.ty),
        isTrue,
        reason: 'slot ${s.poiId} @ (${s.tx},${s.ty}) is blocked',
      );
    }
  });

  test('every slot is reachable from the bridge landing', () {
    final nav = NavGrid.build();
    for (final s in villageSlots) {
      final path = nav.route(tileX(22), tileY(3), s.tx, s.ty);
      expect(
        path,
        isNotEmpty,
        reason: 'no route to ${s.poiId} @ (${s.tx},${s.ty})',
      );
    }
  });

  test('walkable area is a single connected region', () {
    final nav = NavGrid.build();
    // flood fill from the bridge landing — every walkable cell reachable
    final seen = <(int, int)>{};
    var start = (0, 0);
    outer:
    for (var y = 0; y < kMapTilesH; y++) {
      for (var x = 0; x < kMapTilesW; x++) {
        if (nav.walkable(x, y)) {
          start = (x, y);
          break outer;
        }
      }
    }
    final stack = [start];
    seen.add(start);
    while (stack.isNotEmpty) {
      final c = stack.removeLast();
      for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final n = (c.$1 + d.$1, c.$2 + d.$2);
        if (seen.contains(n) || !nav.walkable(n.$1, n.$2)) continue;
        seen.add(n);
        stack.add(n);
      }
    }
    var isolated = 0;
    for (var y = 0; y < kMapTilesH; y++) {
      for (var x = 0; x < kMapTilesW; x++) {
        if (nav.walkable(x, y) && !seen.contains((x, y))) isolated++;
      }
    }
    expect(isolated, 0, reason: '$isolated walkable cells unreachable');
  });

  test('every POI has an anchor and at least one slot', () {
    for (final id in poiTiles.keys) {
      final slots = villageSlots.where((s) => s.poiId == id);
      expect(slots, isNotEmpty, reason: 'POI $id has no activity slots');
    }
  });
}
