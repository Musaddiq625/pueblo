import 'dart:io';
import 'package:image/image.dart';
void main() {
  final img = decodePng(File('assets/sprites/objects/ancient_tree.png').readAsBytesSync())!;
  print('sheet ${img.width}x${img.height}');
  // scan a coarse grid to find each tree's alpha extent
  for (var gy = 0; gy < 3; gy++) {
    for (var gx = 0; gx < 4; gx++) {
      var x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;
      final rx = gx * 112, ry = gy * 122;
      for (var y = ry; y < ry + 122 && y < img.height; y++) {
        for (var x = rx; x < rx + 112 && x < img.width; x++) {
          if (img.getPixel(x, y).a > 24) {
            if (x < x0) x0 = x;
            if (x > x1) x1 = x;
            if (y < y0) y0 = y;
            if (y > y1) y1 = y;
          }
        }
      }
      print('grid($gx,$gy): ink [$x0,$y0]-[$x1,$y1]');
    }
  }
}
