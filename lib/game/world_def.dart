/// World layout — map bounds + POI anchors, derived from the authored
/// tile map so the sim and renderer always agree. Pure data.
library;

import '../sim/models.dart';
import '../sim/world_map.dart';

/// Logical map bounds (world units ≈ px at 1× zoom).
const mapW = kMapW;
const mapH = kMapH;

/// POIs anchored to their prop tiles — x/y = world px of the anchor tile
/// center-bottom (the spot you'd stand in front of).
final poiDefs = <Poi>[
  Poi(
    id: 'bridge',
    name: 'Marigold Bridge',
    surfaceText:
        'Petals stretch across dark water — the only road the living walk.',
    x: _px('bridge'),
    y: _py('bridge'),
    radius: 70,
  ),
  Poi(
    id: 'flower_stall',
    name: 'Flower Stall',
    surfaceText: 'Marigolds piled high. Tía Luz arranges them like she\'s expecting someone.',
    x: _px('flower_stall'),
    y: _py('flower_stall'),
    radius: 80,
    isStall: true,
  ),
  Poi(
    id: 'cantina',
    name: 'La Catrina Feliz',
    surfaceText:
        'A cantina for the dead. The aguas frescas still taste of afternoon.',
    x: _px('cantina'),
    y: _py('cantina'),
    radius: 80,
    isStall: true,
  ),
  Poi(
    id: 'curiosity_shop',
    name: 'Curiosity Shop',
    surfaceText: 'Bottles, bones, and things that hum when the wind is right.',
    x: _px('curiosity_shop'),
    y: _py('curiosity_shop'),
    radius: 80,
    isStall: true,
  ),
  Poi(
    id: 'fountain',
    name: 'The Fountain',
    surfaceText:
        'The water ripples against the wind. Abuela Inés never leaves it.',
    x: _px('fountain'),
    y: _py('fountain'),
    radius: 80,
    anomaly: true,
  ),
  Poi(
    id: 'gravedigger_hut',
    name: 'Gravedigger\'s Hut',
    surfaceText:
        'A shovel, a lamp, and a man who knows where every story is buried.',
    x: _px('gravedigger_hut'),
    y: _py('gravedigger_hut'),
    radius: 80,
  ),
  Poi(
    id: 'cemetery_lane',
    name: 'Cemetery Lane',
    surfaceText:
        'Rows of stones. Grave 37 stands apart — no photo, fresh marigolds.',
    x: _px('cemetery_lane'),
    y: _py('cemetery_lane'),
    radius: 100,
  ),
  Poi(
    id: 'grave_37',
    name: 'Grave 37',
    surfaceText:
        'No name carved. Marigolds appear anyway — someone still cares.',
    x: _px('grave_37'),
    y: _py('grave_37'),
    radius: 60,
    anomaly: true,
  ),
  Poi(
    id: 'ancient_tree',
    name: 'The Old Ceiba',
    surfaceText:
        'The ceiba leans wrong, like it\'s listening to the town below.',
    x: _px('ancient_tree'),
    y: _py('ancient_tree'),
    radius: 110,
    anomaly: true,
  ),
  Poi(
    id: 'ofrenda',
    name: 'The Great Ofrenda',
    surfaceText:
        'Three tiers of candles and photographs. The town\'s beating heart.',
    x: _px('ofrenda'),
    y: _py('ofrenda'),
    radius: 110,
  ),
  Poi(
    id: 'plaza',
    name: 'The Plaza',
    surfaceText: 'Where the dead gather to remember being alive together.',
    x: _px('plaza'),
    y: _py('plaza'),
    radius: 90,
  ),
];

double _px(String id) => tileX(poiTiles[id]!.$1);
double _py(String id) => tileY(poiTiles[id]!.$2);

/// Spirit spawn = their home POI center, nudged south so they don't stack.
Map<String, List<double>> homePositions(Map<String, Poi> pois) => {
  for (final e in pois.entries) e.key: [e.value.x, e.value.y + 34],
};
