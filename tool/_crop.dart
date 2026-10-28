import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> args) {
  final src = img.decodePng(File(args[0]).readAsBytesSync())!;
  // crops: x y w h out
  final c = img.copyCrop(src,
      x: int.parse(args[1]),
      y: int.parse(args[2]),
      width: int.parse(args[3]),
      height: int.parse(args[4]));
  final big = img.copyResize(c,
      width: c.width * 3,
      height: c.height * 3,
      interpolation: img.Interpolation.nearest);
  File(args[5]).writeAsBytesSync(img.encodePng(big));
  print('ok');
}
