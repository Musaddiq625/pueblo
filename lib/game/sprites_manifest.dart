/// Sprite manifest — frame geometry per sheet (measured via sips).
/// Stage-view sheets are side-facing; frame = square unless noted.
library;

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
  const CharDef(this.idle, this.walk);
}

const chars = <String, CharDef>{
  'sk_base': CharDef(
    SheetDef('chars/sk_base_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/sk_base_run.png', 6, 64, 64),
  ),
  'sk_warrior': CharDef(
    SheetDef('chars/sk_warrior_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/sk_warrior_run.png', 6, 64, 64),
  ),
  'sk_rogue': CharDef(
    SheetDef('chars/sk_rogue_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/sk_rogue_run.png', 6, 64, 64),
  ),
  'sk_mage': CharDef(
    SheetDef('chars/sk_mage_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/sk_mage_run.png', 6, 64, 64),
  ),
  'tavern_a': CharDef(
    SheetDef('chars/tavern_a_idle.png', 4, 64, 64, stepTime: 0.25),
    SheetDef('chars/tavern_a_walk.png', 6, 64, 64),
  ),
  'tavern_b': CharDef(
    SheetDef('chars/tavern_b_idle.png', 4, 64, 64, stepTime: 0.25),
    SheetDef('chars/tavern_b_walk.png', 6, 64, 64),
  ),
  'wizzard': CharDef(
    SheetDef('chars/wizzard_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/wizzard_run.png', 6, 64, 64),
  ),
  'knight': CharDef(
    SheetDef('chars/knight_idle.png', 4, 32, 32, stepTime: 0.22),
    SheetDef('chars/knight_run.png', 6, 64, 64),
  ),
};

const objects = <String, SheetDef>{
  'ancient_tree': SheetDef('objects/ancient_tree.png', 1, 448, 368),
  'alchemy_table': SheetDef('objects/alchemy_table.png', 66, 32, 64, stepTime: 0.15),
  'bonfire': SheetDef('objects/bonfire.png', 6, 64, 64, stepTime: 0.18),
  'fire': SheetDef('objects/fire_01.png', 4, 32, 48, stepTime: 0.12),
  'smoke': SheetDef('objects/smoke.png', 4, 32, 48, stepTime: 0.25),
};
