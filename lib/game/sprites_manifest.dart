/// Sprite manifest — frame geometry per sheet.
///
/// Character sheets come from `tool/repack_chars.dart`: every animation of a
/// character is cropped to the SAME union alpha-bbox, so idle/run/death cells
/// are identical and the rendered height never changes when an anim switches
/// (the walking-shrink bug this file used to encode by mixing 32px and 64px
/// canvases). Display size: fixed height kCharDisplayH, width ∝ cell aspect.
library;

import 'chars_norm_manifest.g.dart';

class SheetDef {
  final String path;
  final int frames;
  final double frameW, frameH;
  final double stepTime;
  const SheetDef(this.path, this.frames, this.frameW, this.frameH,
      {this.stepTime = 0.12});
}

/// Per-persona animation set.
class CharDef {
  final SheetDef idle;
  final SheetDef walk;

  /// Directional walk cycles — only the trp sheets carry them; everything
  /// else falls back to the single side-view [walk] + horizontal flip.
  final SheetDef? walkDown, walkUp;
  final SheetDef? death;
  final double displayW, displayH;
  const CharDef(this.idle, this.walk,
      {this.walkDown,
      this.walkUp,
      this.death,
      required this.displayW,
      required this.displayH});
}

SheetDef _s(NormSheet n) =>
    SheetDef(n.path, n.frames, n.cellW.toDouble(), n.cellH.toDouble(),
        stepTime: n.stepTime);

CharDef _c(NormChar n) {
  final walk = n.anims['run'] ?? n.anims['walk']!;
  return CharDef(
    _s(n.anims['idle']!),
    _s(walk),
    walkDown: n.anims['walk_down'] != null ? _s(n.anims['walk_down']!) : null,
    walkUp: n.anims['walk_up'] != null ? _s(n.anims['walk_up']!) : null,
    death: n.anims['death'] != null ? _s(n.anims['death']!) : null,
    displayW: n.cellW * kCharDisplayH / n.cellH,
    displayH: kCharDisplayH,
  );
}

final chars = <String, CharDef>{
  for (final e in normChars.entries) e.key: _c(e.value),
};

const objects = <String, SheetDef>{
  'ancient_tree': SheetDef('objects/ancient_tree.png', 1, 448, 368),
  'alchemy_table': SheetDef('objects/alchemy_table.png', 66, 32, 64, stepTime: 0.15),
  'bonfire': SheetDef('objects/bonfire.png', 6, 64, 64, stepTime: 0.18),
  'fire': SheetDef('objects/fire_01.png', 4, 32, 48, stepTime: 0.12),
  'smoke': SheetDef('objects/smoke.png', 4, 32, 48, stepTime: 0.25),
};
