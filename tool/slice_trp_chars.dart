/// One-off slicer for the tiopalada Tiny RPG CC0 demo sheets.
///
/// Each demo sheet is a 288x192 grid — 6 columns x 4 rows of 48x48 cells,
/// rows ordered down / left / back / right. Our world walks left-right
/// only (the engine mirrors), so row 0 becomes `idle` and row 1 becomes
/// `walk` — the engine flips horizontally for the other direction.
///
/// Run:  dart run tool/slice_trp_chars.dart
/// Input:  tool/art_src/trp_char00..02.png  (raw demo sheets)
/// Output: assets/sprites/chars/trp_<key>_idle.png / _walk.png (48x48 cells)
library;

import 'dart:io';
import 'package:image/image.dart';

const jobs = <String, String>{
  'trp_char00': 'trp_hat', // wide-brim hat lady
  'trp_char01': 'trp_bard', // feathered cap, satchel — the troubadour
  'trp_char02': 'trp_veil', // hooded mourner
};

void main() {
  const cell = 48;
  for (final e in jobs.entries) {
    final src = File('tool/art_src/${e.key}.png');
    if (!src.existsSync()) {
      stderr.writeln('missing ${src.path}');
      continue;
    }
    final img = decodePng(src.readAsBytesSync())!;
    for (final (row, anim) in [(0, 'idle'), (1, 'walk')]) {
      final out = copyCrop(img,
          x: 0, y: row * cell, width: img.width, height: cell);
      final name = 'assets/sprites/chars/${e.value}_$anim.png';
      File(name).writeAsBytesSync(encodePng(out));
      stdout.writeln('$name: ${out.width}x${out.height}');
    }
  }
}
