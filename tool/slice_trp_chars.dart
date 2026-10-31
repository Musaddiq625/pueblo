/// One-off slicer for the tiopalada Tiny RPG CC0 demo sheets.
///
/// Each demo sheet is a 288x192 grid — 6 columns x 4 rows of 48x48 cells,
/// rows ordered down / left / back / right. The pack ships NO idle anim —
/// the down row is a walk cycle, which read as stepping-in-place when the
/// spirit stood. So:
///   idle      = a single frame (row 0, cell 0) — standing, facing viewer
///   walk      = row 3 (right-facing; the engine flips it for left)
///   walk_down = row 0 (walk cycle toward the camera)
///   walk_up   = row 2 (walk cycle away from the camera)
///
/// Run:  dart run tool/slice_trp_chars.dart
/// Input:  tool/art_src/trp_char00..02.png  (raw demo sheets)
/// Output: assets/sprites/chars/trp_KEY_{idle,walk,walk_down,walk_up}.png
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
    // full-row sheets: walk (right), down, up
    for (final (row, anim) in [(3, 'walk'), (0, 'walk_down'), (2, 'walk_up')]) {
      final out = copyCrop(img,
          x: 0, y: row * cell, width: img.width, height: cell);
      _stripWhiteOutline(out);
      final name = 'assets/sprites/chars/${e.value}_$anim.png';
      File(name).writeAsBytesSync(encodePng(out));
      stdout.writeln('$name: ${out.width}x${out.height}');
    }
    // idle — one standing frame, not a cycle: no more stepping in place
    final idle = copyCrop(img, x: 0, y: 0, width: cell, height: cell);
    _stripWhiteOutline(idle);
    File('assets/sprites/chars/${e.value}_idle.png')
        .writeAsBytesSync(encodePng(idle));
    stdout.writeln('${e.value}_idle.png: ${idle.width}x${idle.height}');
  }
}

/// The demo pack bakes a 1-2px cream outline (#F7EDDC) around every
/// character so they pop on white preview pages — on our dark village it
/// reads as a white border. Recolor ONLY outline pixels (the cream that
/// touches transparency) to a dark tone; interior cream (face shine,
/// shirt trim) survives untouched.
void _stripWhiteOutline(Image img) {
  bool isCream(num r, num g, num b) =>
      r > 225 && g > 215 && b > 195 && r - b < 40;
  final marks = <({int x, int y})>[];
  for (var y = 0; y < img.height; y++) {
    for (var x = 0; x < img.width; x++) {
      final p = img.getPixel(x, y);
      if (p.a < 100 || !isCream(p.r, p.g, p.b)) continue;
      // outline pixel iff any 8-neighbor is transparent
      var edge = false;
      for (var dy = -1; dy <= 1 && !edge; dy++) {
        for (var dx = -1; dx <= 1 && !edge; dx++) {
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= img.width || ny >= img.height ||
              img.getPixel(nx, ny).a < 100) {
            edge = true;
          }
        }
      }
      if (edge) marks.add((x: x, y: y));
    }
  }
  for (final m in marks) {
    img.setPixelRgb(m.x, m.y, 0x3A, 0x2C, 0x34); // dark umber outline
  }
}
