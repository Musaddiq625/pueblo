import '../lib/sim/world_map.dart';

void main() {
  for (var y = 0; y < villageAscii.length; y++) {
    final row = villageAscii[y];
    final segs = <String>[];
    var start = 0;
    for (var x = 1; x <= row.length; x++) {
      if (x == row.length || row[x] != row[start]) {
        segs.add('${row[start]}$start-${x - 1}');
        start = x;
      }
    }
    print('$y: ${segs.join(' ')}');
  }
}
