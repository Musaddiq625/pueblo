import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  const cols = 11, cell = 64;
  final out = img.Image(width: cols * cell, height: 12 * (cell + 14));
  img.fill(out, color: img.ColorRgb8(24, 24, 32));
  for (var id = 0; id <= 131; id++) {
    final f = File(
        'assets/sprites/village/tiny_town/Tiles/tile_${id.toString().padLeft(4, '0')}.png');
    if (!f.existsSync()) continue;
    final t = img.decodePng(f.readAsBytesSync())!;
    final big = img.copyResize(t,
        width: cell, height: cell, interpolation: img.Interpolation.nearest);
    final cx = (id % cols) * cell, cy = (id ~/ cols) * (cell + 14);
    img.compositeImage(out, big, dstX: cx, dstY: cy + 14);
    img.drawString(out, '$id',
        font: img.arial14, x: cx + 2, y: cy, color: img.ColorRgb8(255, 255, 0));
  }
  File('/tmp/tt_sheet.png').writeAsBytesSync(img.encodePng(out));
  print('done');
}
