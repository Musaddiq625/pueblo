import 'dart:io';
import 'package:image/image.dart';

void main() {
  for (final n in [
    'sk_base_idle',
    'sk_base_run',
    'sk_mage_idle',
    'sk_mage_run',
    'knight_idle',
    'knight_run',
  ]) {
    final img =
        decodePng(File('assets/sprites/chars_norm/$n.png').readAsBytesSync())!;
    var yMax = -1, yMin = 1 << 30;
    for (var y = 0; y < img.height; y++) {
      for (var x = 0; x < img.width && x < 60; x++) {
        if (img.getPixel(x, y).a > 24) {
          if (y > yMax) yMax = y;
          if (y < yMin) yMin = y;
        }
      }
    }
    print('$n: ${img.width}x${img.height} ink y[$yMin..$yMax] '
        'bottom-gap=${img.height - 1 - yMax}');
  }
}
