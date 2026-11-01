import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:pueblo/sim/store.dart';

void main() {
  test('fresh reopen under a live store → old dies, new writes', () async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('deadstore');
    final path = '${dir.path}/t.db';
    final s1 = await SimStore.open(path: path, fresh: true);
    await s1.simLog(0, 'a', 'k', 'before');
    // "Play again": fresh open on the same path while s1 is still live.
    final s2 = await SimStore.open(path: path, fresh: true);
    await s1.simLog(0, 'a', 'k', 'stale write — must drop quietly');
    await s2.simLog(1, 'b', 'k', 'new world write');
    final rows = await s2.tailLog(10);
    print('s2.isDead=${s2.isDead} rows=${rows.length}');
    expect(s2.isDead, isFalse);
    expect(rows.any((r) => r['payload'] == 'new world write'), isTrue);
  });
}
