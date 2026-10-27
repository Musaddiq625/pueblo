/// Navigation grid — pure Dart, no Flame imports.
///
/// Derives a walkability grid from the authored village ASCII + prop
/// blockers, and provides 4-directional A* pathfinding. Everything the
/// sim needs to route spirits lives here so it stays unit-testable.
library;

import 'dart:math';

import 'world_map.dart';

class NavGrid {
  /// blocked[y][x] — prop cells that override otherwise-walkable terrain.
  final List<List<bool>> blocked;
  const NavGrid._(this.blocked);

  static const _walkableTerrain = 'edgsbp';

  /// Terrain characters we treat as blocked regardless of props.
  bool _terrainOpen(int x, int y) =>
      x >= 0 &&
      x < kMapTilesW &&
      y >= 0 &&
      y < kMapTilesH &&
      _walkableTerrain.contains(villageAscii[y][x]);

  factory NavGrid.build() {
    final blocked = List.generate(
      kMapTilesH,
      (_) => List.filled(kMapTilesW, false),
    );
    for (final p in villageProps) {
      for (final c in coveredCells(p)) {
        if (c.$1 >= 0 && c.$1 < kMapTilesW && c.$2 >= 0 && c.$2 < kMapTilesH) {
          blocked[c.$2][c.$1] = true;
        }
      }
    }
    return NavGrid._(blocked);
  }

  /// Tiles each prop kind occupies (blocked for walking).
  static List<(int, int)> coveredCells(Prop p) {
    final cells = <(int, int)>[];
    void rect(int w, int h) {
      for (var dy = 0; dy < h; dy++) {
        for (var dx = 0; dx < w; dx++) {
          cells.add((p.tx + dx, p.ty + dy));
        }
      }
    }

    switch (p.kind) {
      case 'pine':
      case 'autumn':
      case 'leafy':
      case 'boulder':
      case 'pot':
      case 'barrel':
      case 'log':
      case 'lantern':
      case 'sign':
      case 'grave':
      case 'grave37':
      case 'pickaxe':
      case 'bench':
      case 'bush':
        cells.add((p.tx, p.ty));
      case 'mushroom':
      case 'bone':
      case 'marigold':
        break; // ground scatter — spirits step over it
      case 'fenceH':
        for (var i = 0; i < (p.args.isEmpty ? 1 : p.args[0]); i++) {
          cells.add((p.tx + i, p.ty));
        }
      case 'fenceV':
        for (var i = 0; i < (p.args.isEmpty ? 1 : p.args[0]); i++) {
          cells.add((p.tx, p.ty + i));
        }
      case 'crypt':
        rect(4, 2);
      case 'cantina':
        rect(4, 4);
      case 'stall':
        rect(3, 2);
      case 'curiosity':
        rect(4, 3);
      case 'hut':
        rect(3, 3);
      case 'well':
        rect(3, 3);
      case 'ofrenda':
        rect(7, 2);
      case 'ceiba':
        rect(3, 3);
      default:
        cells.add((p.tx, p.ty));
    }
    return cells;
  }

  bool walkable(int x, int y) => _terrainOpen(x, y) && !blocked[y][x];

  /// Snap a world position to the nearest walkable tile center — used when
  /// an agent stands somewhere off-grid (e.g. after release).
  (int, int) nearestWalkableTile(int tx, int ty) {
    var best = (tx.clamp(0, kMapTilesW - 1), ty.clamp(0, kMapTilesH - 1));
    var bestD = 1 << 30;
    for (var r = 0; r < 12; r++) {
      for (var dy = -r; dy <= r; dy++) {
        for (var dx = -r; dx <= r; dx++) {
          final nx = tx + dx, ny = ty + dy;
          if (walkable(nx, ny)) {
            final d = dx * dx + dy * dy;
            if (d < bestD) {
              bestD = d;
              best = (nx, ny);
            }
          }
        }
      }
      if (bestD < 1 << 30) return best;
    }
    return best;
  }

  /// A* over the walkable grid. Returns tile centers as world points,
  /// excluding the start tile, including the goal. Empty = no path.
  List<Point<double>> route(double fromX, double fromY, int toTx, int toTy) {
    final start = nearestWalkableTile(
      (fromX / kTile).floor(),
      (fromY / kTile).floor(),
    );
    var goal = (toTx, toTy);
    if (!walkable(goal.$1, goal.$2)) {
      goal = nearestWalkableTile(goal.$1, goal.$2);
      if (!walkable(goal.$1, goal.$2)) return const [];
    }
    if (start == goal) {
      return [Point(tileX(goal.$1), tileY(goal.$2))];
    }

    final cameFrom = <(int, int), (int, int)>{};
    final gScore = <(int, int), double>{start: 0};
    final open = <(int, int)>[start];
    final fScore = <(int, int), double>{start: _h(start, goal)};
    final closed = <(int, int)>{};

    double h((int, int) a) => _h(a, goal);

    while (open.isNotEmpty) {
      // pop lowest fScore (small map — linear scan is fine)
      var bi = 0;
      var bf = fScore[open[0]] ?? double.infinity;
      for (var i = 1; i < open.length; i++) {
        final f = fScore[open[i]] ?? double.infinity;
        if (f < bf) {
          bf = f;
          bi = i;
        }
      }
      final cur = open.removeAt(bi);
      if (cur == goal) {
        final path = <(int, int)>[cur];
        var c = cur;
        while (cameFrom.containsKey(c)) {
          c = cameFrom[c]!;
          path.insert(0, c);
        }
        path.removeAt(0); // drop start tile
        return [for (final t in path) Point(tileX(t.$1), tileY(t.$2))];
      }
      closed.add(cur);
      const dirs = [(1, 0), (-1, 0), (0, 1), (0, -1)];
      for (final d in dirs) {
        final n = (cur.$1 + d.$1, cur.$2 + d.$2);
        if (!walkable(n.$1, n.$2) || closed.contains(n)) continue;
        final tentative = (gScore[cur] ?? double.infinity) + 1;
        if (tentative < (gScore[n] ?? double.infinity)) {
          cameFrom[n] = cur;
          gScore[n] = tentative;
          fScore[n] = tentative + h(n);
          if (!open.contains(n)) open.add(n);
        }
      }
    }
    return const [];
  }

  double _h((int, int) a, (int, int) b) =>
      ((a.$1 - b.$1).abs() + (a.$2 - b.$2).abs()).toDouble();
}
