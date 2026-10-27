/// World layout — stage-view map data: waypoints (walkable graph), POIs,
/// homes. Pure data; consumed by sim + renderer.
library;

import '../sim/models.dart';

/// Logical map bounds (world units ≈ px at 1× zoom).
const mapW = 1400.0;
const mapH = 820.0;

/// Waypoint positions — the walkable path network (stage view: x = horizontal,
/// y = depth). Spirits move ONLY between these nodes.
const waypointPos = <List<double>>[
  [700, 90],   // 0 bridge north (spawn)
  [700, 220],  // 1 bridge→plaza path
  [700, 330],  // 2 plaza center
  [520, 330],  // 3 plaza west (market row)
  [420, 330],  // 4 flower stall front
  [880, 330],  // 5 plaza east
  [1030, 350], // 6 curiosity shop front
  [820, 450],  // 7 fountain
  [1120, 450], // 8 gravedigger hut
  [1120, 560], // 9 cemetery lane
  [1230, 660], // 10 ancient tree
  [700, 560],  // 11 plaza→ofrenda path
  [700, 700],  // 12 ofrenda wall
  [420, 560],  // 13 west lower path
];

/// Adjacency — spirits only travel along these edges.
const waypoints = <List<int>>[
  [1],                 // 0 bridge
  [0, 2],              // 1
  [1, 3, 5, 7, 11],    // 2 plaza
  [2, 4, 13],          // 3
  [3],                 // 4 flower stall
  [2, 6, 7],           // 5
  [5, 8],              // 6 curiosity shop
  [2, 5, 8, 11],       // 7 fountain
  [6, 7, 9],           // 8 gravedigger hut
  [8, 10],             // 9 cemetery
  [9],                 // 10 ancient tree
  [2, 7, 12, 13],      // 11
  [11],                // 12 ofrenda
  [3, 11],             // 13
];

/// Points of interest — POIs that can be inspected / shopped / talked about.
const poiDefs = <Poi>[
  Poi(
    id: 'bridge', name: 'Marigold Bridge', surfaceText:
        'Petals stretch across dark water — the only road the living walk.',
    x: 700, y: 90, radius: 90),
  Poi(
    id: 'flower_stall', name: 'Flower Stall', surfaceText:
        'Marigolds piled high. Tía Luz arranges them like she\'s expecting someone.',
    x: 420, y: 300, radius: 80, isStall: true),
  Poi(
    id: 'cantina', name: 'La Catrina Feliz', surfaceText:
        'A cantina for the dead. The aguas frescas still taste of afternoon.',
    x: 540, y: 280, radius: 80, isStall: true),
  Poi(
    id: 'curiosity_shop', name: 'Curiosity Shop', surfaceText:
        'Bottles, bones, and things that hum when the wind is right.',
    x: 1030, y: 320, radius: 80, isStall: true),
  Poi(
    id: 'fountain', name: 'The Fountain', surfaceText:
        'The water ripples against the wind. Abuela Inés never leaves it.',
    x: 820, y: 440, radius: 80, anomaly: true),
  Poi(
    id: 'gravedigger_hut', name: 'Gravedigger\'s Hut', surfaceText:
        'A shovel, a lamp, and a man who knows where every story is buried.',
    x: 1120, y: 430, radius: 80),
  Poi(
    id: 'cemetery_lane', name: 'Cemetery Lane', surfaceText:
        'Rows of stones. Grave 37 stands apart — no photo, fresh marigolds.',
    x: 1120, y: 560, radius: 100),
  Poi(
    id: 'grave_37', name: 'Grave 37', surfaceText:
        'No name carved. Marigolds appear anyway — someone still cares.',
    x: 1180, y: 590, radius: 60, anomaly: true),
  Poi(
    id: 'ancient_tree', name: 'The Old Ceiba', surfaceText:
        'The ceiba leans wrong, like it\'s listening to the town below.',
    x: 1230, y: 680, radius: 110, anomaly: true),
  Poi(
    id: 'ofrenda', name: 'The Great Ofrenda', surfaceText:
        'Three tiers of candles and photographs. The town\'s beating heart.',
    x: 700, y: 720, radius: 100),
  Poi(
    id: 'plaza', name: 'The Plaza', surfaceText:
        'Where the dead gather to remember being alive together.',
    x: 700, y: 330, radius: 90),
];

/// Spirit spawn = their home POI center (offset slightly so they don't stack).
Map<String, List<double>> homePositions(Map<String, Poi> pois) => {
      for (final e in pois.entries) e.key: [e.value.x, e.value.y + 30],
    };
