import 'package:pueblo/sim/world_map.dart';
void main() {
  print('rows: ${villageAscii.length}');
  for (var i = 0; i < villageAscii.length; i++) {
    if (villageAscii[i].length != 44) print('BAD WIDTH row $i: ${villageAscii[i].length}');
  }
  const w = 'edgsbp';
  for (final s in villageSlots) {
    final ch = villageAscii[s.ty][s.tx];
    if (!w.contains(ch)) print('slot ${s.poiId} (${s.tx},${s.ty}) on $ch');
  }
  final counts = <String, int>{};
  for (final row in villageAscii) {
    for (var i = 0; i < row.length; i++) {
      counts[row[i]] = (counts[row[i]] ?? 0) + 1;
    }
  }
  print(counts);
}
