/// Targeted sim unit tests — knowledge isolation, atomic transfer,
/// engagement semantics. No Flutter widgets, no network.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/sim/bootstrap.dart';
import 'package:pueblo/sim/llm.dart';
import 'package:pueblo/sim/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _personas = '''
[{"id":"a","name":"Ana","role":"s","persona":"kind","stats":{"curiosity":5,"wit":1,"warmth":5,"spirit_sight":0,"mischief":0,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"b","name":"Bor","role":"s","persona":"gruff","stats":{"curiosity":0,"wit":1,"warmth":0,"spirit_sight":0,"mischief":0,"grump":5},"home":"p2","sprite":"sk_base","initial_secrets":[]}]
''';
const _secrets = '''
[{"id":"s1","surface":"surf","truth":"the buried truth","share_text":"shares s1",
  "initially_known_by":["a"],"unlocks_poi_lore":"p1","tier":"town"}]
''';

Future<SimBundle> _boot() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('simtest');
  return bootstrap(
    personasJson: _personas,
    secretsJson: _secrets,
    pois: const [
      Poi(id: 'p1', name: 'P1', surfaceText: 'just a lane', x: 0, y: 0),
      Poi(id: 'p2', name: 'P2', surfaceText: 'just a stall', x: 10, y: 10),
    ],
    waypointsIdx: const [
      [1],
      [0]
    ],
    waypointPos: const [
      [0, 0],
      [10, 10]
    ],
    homePos: const {
      'p1': [0, 0],
      'p2': [10, 10]
    },
    llm: MockLLMClient(seed: 1),
    rng: Random(1),
    freshDb: true,
    dbPath: '${dir.path}/t.db',
  );
}

void main() {
  test('initial knowledge comes from secrets.json only', () async {
    final b = await _boot();
    expect(b.engine.agents['a']!.knownSecrets, contains('s1'));
    expect(b.engine.agents['b']!.knownSecrets, isEmpty);
  });

  test('engagement is exclusive and user-released only', () async {
    final b = await _boot();
    final e = b.engine;
    e.engage('a');
    expect(e.engagedId, 'a');
    expect(e.agents['a']!.engaged, isTrue);
    // grump can't release it — only user actions can
    e.engage('b'); // switching releases A, engages B
    expect(e.engagedId, 'b');
    expect(e.agents['a']!.engaged, isFalse);
    expect(e.agents['b']!.engaged, isTrue);
    e.disengage();
    expect(e.engagedId, isNull);
    expect(e.agents['b']!.engaged, isFalse);
  });

  test('player claims store as claims, knowledge unchanged', () async {
    final b = await _boot();
    final e = b.engine;
    e.engage('a');
    await for (final _ in e.sendPlayerMessage('the tree is full of gold')) {}
    expect(e.agents['a']!.knownSecrets, isNot(contains('gold')));
    e.disengage();
  });

  test('inspection deep-lore gates on player knowledge', () async {
    final b = await _boot();
    final e = b.engine;
    // without the secret → surface text only
    expect(e.inspectPoi('p1'), 'just a lane');
    e.playerKnown.add('s1');
    expect(e.inspectPoi('p1'), 'the buried truth');
  });
}
