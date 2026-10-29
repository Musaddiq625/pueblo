/// InspectCard chat-field contract — the field must accept input, the send
/// button must deliver, the busy state must ALWAYS clear, and a dead or
/// throwing backend must surface a visible beat instead of a silent wedge.
/// (Regression for the Pixel "unable to send" report.)
///
/// NOTE: real async (sqlite via ffi) can't complete inside testWidgets' fake
/// zone — engines boot in setUpAll and stream completion waits use runAsync.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/sim/bootstrap.dart';
import 'package:pueblo/sim/engine.dart';
import 'package:pueblo/sim/llm.dart';
import 'package:pueblo/sim/models.dart';
import 'package:pueblo/ui/inspect_card.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _personas = '''
[{"id":"a","name":"Ana","role":"s","persona":"kind","stats":{"curiosity":5,"wit":1,"warmth":5,"spirit_sight":0,"mischief":0,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"b","name":"Bor","role":"s","persona":"gruff","stats":{"curiosity":0,"wit":1,"warmth":0,"spirit_sight":0,"mischief":0,"grump":5},"home":"p2","sprite":"sk_base","initial_secrets":[]}]
''';
const _secrets = '''
[{"id":"s1","surface":"surf","truth":"the buried truth","share_text":"shares s1",
  "initially_known_by":["a"],"unlocks_poi_lore":"p1","wakes_agent":"b","tier":"town"}]
''';

class _EmptyLLM extends MockLLMClient {
  _EmptyLLM() : super(seed: 1);
  @override
  Stream<String> playerChat(String prompt) async* {}
}

class _ThrowingLLM extends MockLLMClient {
  _ThrowingLLM() : super(seed: 1);
  @override
  Stream<String> playerChat(String prompt) async* {
    yield 'partial';
    throw StateError('backend exploded');
  }
}

Widget _wrap(SimEngine e) => MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: InspectCard(
            engine: e,
            spiritSprite: 'sk_base',
            onEnd: () {},
          ),
        ),
      ),
    );

Future<SimBundle> _boot(LLMClient? llm) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  final dir = await Directory.systemTemp.createTemp('cardtest');
  return bootstrap(
    personasJson: _personas,
    secretsJson: _secrets,
    pois: const [
      Poi(id: 'p1', name: 'P1', surfaceText: 'x', x: 0, y: 0),
      Poi(id: 'p2', name: 'P2', surfaceText: 'y', x: 10, y: 10),
    ],
    homePos: const {'p1': [0, 0], 'p2': [10, 10]},
    llm: llm ?? MockLLMClient(seed: 1),
    rng: Random(1),
    freshDb: true,
    dbPath: '${dir.path}/t.db',
  );
}

void main() {
  final engines = <String, SimBundle>{};
  setUpAll(() async {
    engines['mock'] = await _boot(null);
    engines['empty'] = await _boot(_EmptyLLM());
    engines['throw'] = await _boot(_ThrowingLLM());
  });

  Future<void> sendMsg(WidgetTester t, SimBundle b, String msg) async {
    final e = b.engine..engage('a');
    await t.pumpWidget(_wrap(e));
    await t.pump();
    await t.enterText(find.byKey(const Key('playerChatField')), msg);
    await t.pump();
    await t.tap(find.byKey(const Key('sendChatButton')));
    await t.pump();
    // sqlite + stream completion are real async — runAsync gives them a real
    // event loop, then a pump renders whatever arrived.
    await t.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 300)));
    await t.pump();
  }

  testWidgets('field accepts input, send delivers, busy clears', (t) async {
    await sendMsg(t, engines['mock']!, 'the tree is full of gold');
    expect(find.text('the tree is full of gold'), findsOneWidget);
    final IconButton btn = t.widget(find.byKey(const Key('sendChatButton')));
    expect(btn.onPressed, isNotNull);
    await t.pump(const Duration(seconds: 11)); // flush sqflite watchdog timers
  });

  testWidgets('empty stream still answers visibly', (t) async {
    await sendMsg(t, engines['empty']!, 'gold under the lane');
    // The engine's silent-listen beat — the spirit takes it in wordlessly.
    expect(find.text('· listens in silence.'), findsOneWidget);
    final IconButton btn = t.widget(find.byKey(const Key('sendChatButton')));
    expect(btn.onPressed, isNotNull);
    await t.pump(const Duration(seconds: 11));
  });

  testWidgets('throwing stream shows error and un-wedges send', (t) async {
    await sendMsg(t, engines['throw']!, 'gold under the lane');
    expect(find.textContaining('the words fall unheard'), findsOneWidget);
    final IconButton btn = t.widget(find.byKey(const Key('sendChatButton')));
    expect(btn.onPressed, isNotNull);
    await t.pump(const Duration(seconds: 11));
  });
}
