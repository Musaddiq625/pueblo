/// Dev tool — validates the authored map: every POI slot reachable,
/// no isolated walkable pockets. Run: fvm dart run tool/navcheck.dart
// ignore_for_file: avoid_print
library;

import 'package:pueblo/sim/navgrid.dart';
import 'package:pueblo/sim/world_map.dart';

void main() {
  final nav = NavGrid.build();
  var fails = 0;
  for (final s in villageSlots) {
    final p = nav.route(704, 368, s.tx, s.ty);
    if (p.isEmpty) {
      print('UNREACHABLE slot ${s.poiId} (${s.tx},${s.ty})');
      fails++;
    }
  }
  // flood-fill connectivity from the plaza
  final seen = <(int, int)>{};
  final q = [(22, 11)];
  while (q.isNotEmpty) {
    final c = q.removeLast();
    if (seen.contains(c) || !nav.walkable(c.$1, c.$2)) continue;
    seen.add(c);
    for (final d in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
      q.add((c.$1 + d.$1, c.$2 + d.$2));
    }
  }
  var walk = 0, isolated = 0;
  for (var y = 0; y < kMapTilesH; y++) {
    for (var x = 0; x < kMapTilesW; x++) {
      if (nav.walkable(x, y)) {
        walk++;
        if (!seen.contains((x, y))) {
          isolated++;
          print('isolated: ($x,$y) "${villageAscii[y][x]}"');
        }
      }
    }
  }
  print('slots checked: ${villageSlots.length}, fails: $fails');
  print('walkable: $walk, isolated: $isolated');
}
