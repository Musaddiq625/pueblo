// crop a region of a screenshot to inspect label clipping
import 'dart:io';
import 'package:image/image.dart' as img;

void main(List<String> argv) {
  final src = argv[0], dst = argv[1];
  final x = int.parse(argv[2]), y = int.parse(argv[3]),
      w = int.parse(argv[4]), h = int.parse(argv[5]);
  final im = img.decodePng(File(src).readAsBytesSync())!;
  final c = img.copyCrop(im, x: x, y: y, width: w, height: h);
  // upscale 4x for readability
  final big = img.copyResize(c, width: w * 4, interpolation: img.Interpolation.nearest);
  File(dst).writeAsBytesSync(img.encodePng(big));
  print('saved $dst');
}
