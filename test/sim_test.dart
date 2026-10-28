/// Targeted sim unit tests — knowledge isolation, atomic transfer,
/// engagement semantics. No Flutter widgets, no network.
library;

import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/sim/bootstrap.dart';
import 'package:pueblo/sim/engine.dart';
import 'package:pueblo/sim/llm.dart';
import 'package:pueblo/sim/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _personas = '''
[{"id":"a","name":"Ana","role":"s","persona":"kind","stats":{"curiosity":5,"wit":1,"warmth":5,"spirit_sight":0,"mischief":0,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"b","name":"Bor","role":"s","persona":"gruff","stats":{"curiosity":0,"wit":1,"warmth":0,"spirit_sight":0,"mischief":0,"grump":5},"home":"p2","sprite":"sk_base","initial_secrets":[]}]
''';
const _secrets = '''
[{"id":"s1","surface":"surf","truth":"the buried truth","share_text":"shares s1",
  "initially_known_by":["a"],"unlocks_poi_lore":"p1","wakes_agent":"b","tier":"town"}]
''';

Future<SimBundle> _boot({LLMClient? llm}) async {
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
      Poi(id: 'ofrenda', name: 'Ofrenda', surfaceText: 'the shrine', x: 40, y: 40),
    ],
    homePos: const {
      'p1': [0, 0],
      'p2': [10, 10],
    },
    llm: llm ?? MockLLMClient(seed: 1),
    rng: Random(1),
    freshDb: true,
    dbPath: '${dir.path}/t.db',
  );
}

/// Scripted double — returns fixed turns, records every prompt the engine
/// builds so tests can assert on what the model was offered.
class _ScriptedLLM extends MockLLMClient {
  _ScriptedLLM() : super(seed: 1);
  final prompts = <String>[];
  String? forcedShare;
  bool endNow = true;
  Decision? forcedDecision;
  Map<String, dynamic>? forcedBeat;

  @override
  Future<Decision?> decide(String prompt) async {
    prompts.add(prompt);
    return forcedDecision; // null → engine emits '·' emote, agent stays put
  }

  @override
  Future<ConvoTurn?> convoTurn(String prompt) async {
    prompts.add(prompt);
    return ConvoTurn('a spoken line', sharesSecret: forcedShare, end: endNow);
  }

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async {
    prompts.add(prompt);
    return forcedBeat ?? {'beat': 'none'};
  }
}

/// Pump the async broker/store pipeline while ticking the sim clock.
Future<void> _pump(dynamic e, {int ticks = 60, double dt = 0.5}) async {
  for (var i = 0; i < ticks; i++) {
    e.tick(dt);
    await Future<void>.delayed(const Duration(milliseconds: 3));
  }
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

  test('purpose-bound convo transfers the declared secret deterministically',
      () async {
    final llm = _ScriptedLLM(); // shares_secret stays null on purpose
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.startConversation('a', 'b', purpose: (holder: 'a', secretId: 's1'));
    // convo needs a couple of turn cycles — pump until transfer lands
    for (var i = 0; i < 160 && !e.agents['b']!.knownSecrets.contains('s1');
        i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.agents['b']!.knownSecrets, contains('s1'));
  });

  test('hallucinated shares_secret cannot move knowledge', () async {
    final llm = _ScriptedLLM()..forcedShare = 'bogus_secret';
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.startConversation('a', 'b'); // organic, no purpose
    await _pump(e, ticks: 60);
    expect(e.agents['b']!.knownSecrets, isEmpty);
  });

  test('organic convo still transfers a valid owned secret', () async {
    final llm = _ScriptedLLM()..forcedShare = 's1';
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.startConversation('a', 'b');
    for (var i = 0; i < 160 && !e.agents['b']!.knownSecrets.contains('s1');
        i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.agents['b']!.knownSecrets, contains('s1'));
  });

  test('already-known secret cannot re-transfer', () async {
    final llm = _ScriptedLLM()..forcedShare = 's1';
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.agents['b']!.knownSecrets.add('s1');
    e.startConversation('a', 'b');
    await _pump(e, ticks: 60);
    expect(e.agents['b']!.knownSecrets.length, 1);
  });

  test('converse is not re-offered within the pair cooldown', () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    // put them adjacent, talk once → cooldown starts
    e.agents['a']!.x = 0;
    e.agents['a']!.y = 0;
    e.agents['b']!.x = 30;
    e.agents['b']!.y = 0;
    e.startConversation('a', 'b');
    await _pump(e, ticks: 40);
    // force A to be the next decided agent, inside the 90s cooldown —
    // pin positions so ambient wandering can't separate them mid-test
    llm.prompts.clear();
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final aPrompt =
        llm.prompts.firstWhere((p) => p.contains('You are Ana'), orElse: () => '');
    expect(aPrompt, isNot(contains('converse(b)')));
    // but knowledge offers are never cooled down — Ana holds s1 Bor lacks
    expect(aPrompt, contains('share(b,s1)'));
  });

  test('small talk is withheld while a pair has real news to pass', () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    // Ana knows s1, Bor doesn't → share exists, so no converse( offer
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final aPrompt =
        llm.prompts.firstWhere((p) => p.contains('You are Ana'), orElse: () => '');
    expect(aPrompt, contains('share(b,s1)'));
    expect(aPrompt, isNot(contains('converse(b)')));
  });

  test('grumpy spirits keep the random-talk exemption', () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    // Bor (grump 5) decides — knows nothing, yet converse stays offered
    e.agents['b']!.lastActedAt = -999;
    e.agents['a']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final bPrompt =
        llm.prompts.firstWhere((p) => p.contains('You are Bor'), orElse: () => '');
    expect(bPrompt, isNotEmpty);
    expect(bPrompt, contains('converse(a)'));
    // and Bor can still ask Ana what she knows
    expect(bPrompt, contains('ask(a)'));
  });

  test('name(args) echo from the model normalizes into a share', () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision(
        'share(b,s1)', // small models echo the offered string verbatim
        null,
        'heard something',
      );
    final b = await _boot(llm: llm);
    final e = b.engine;
    // Both on the south road — walkable, and close enough to approach.
    // Pin only until the decision lands; the approach walk needs real motion.
    for (var i = 0; i < 400 && !e.agents['b']!.knownSecrets.contains('s1');
        i++) {
      if (i < 30) {
        e.agents['a']!.x = 624;
        e.agents['a']!.y = 496;
        e.agents['b']!.x = 656;
        e.agents['b']!.y = 496;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(e.agents['b']!.knownSecrets, contains('s1'));
  });

  test('verify errand surfaces in the decision prompt', () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    // Ana knows s1 (unlocks p1) and never inspected it → verify errand
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final aPrompt = llm.prompts
        .firstWhere((p) => p.contains('You are Ana'), orElse: () => '');
    expect(aPrompt, contains('Your errand:'));
    expect(aPrompt, contains('go see for yourself'));
    // and the engine backs it with a concrete offer
    expect(aPrompt, contains('goto(p1)'));
  });

  test('tell errand: carries news to whoever lacks it, clears on convo',
      () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    // verify already satisfied → next priority is tell(Bor)
    e.agents['a']!.verifiedPois.add('p1');
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final aPrompt = llm.prompts
        .firstWhere((p) => p.contains('You are Ana'), orElse: () => '');
    expect(aPrompt, contains('news Bor'));
    // talking to Bor satisfies the errand
    e.startConversation('a', 'b');
    expect(e.agents['a']!.errand, isNull);
  });

  test('data-driven wake: greeting with a name-secret revives a fading spirit',
      () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('greet', 'b', '¡Bor! Still with us?');
    final b = await _boot(llm: llm);
    final e = b.engine;
    final bor = e.agents['b']!;
    bor.battery = 2;
    bor.faded = true;
    // a's next decision sees the rescue and acts on it
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30 && bor.faded; i++) {
      if (i < 26) {
        e.agents['a']!.x = 624;
        e.agents['a']!.y = 496;
        e.agents['b']!.x = 656;
        e.agents['b']!.y = 496;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(llm.prompts.any((p) => p.contains('FADING') && p.contains('greet(b)')),
        isTrue);
    expect(bor.faded, isFalse, reason: 'the spoken name should revive them');
    expect(bor.battery, greaterThan(8));
  });

  test('approach on an engaged target defers and retries when free', () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('converse', 'b', 'hola, compadre');
    final b = await _boot(llm: llm);
    final e = b.engine;
    // B busy with the player — A's approach must wait, not drop
    e.engage('b');
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 26; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.conversations, isEmpty, reason: 'B is engaged — no convo yet');
    // release B — the deferred approach should fire on A's next slot
    e.disengage();
    for (var i = 0; i < 60 && e.conversations.isEmpty; i++) {
      if (i < 20) {
        e.agents['a']!.x = 0;
        e.agents['a']!.y = 0;
        e.agents['b']!.x = 30;
        e.agents['b']!.y = 0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.conversations, isNotEmpty,
        reason: 'the deferred converse should retry once B is free');
  });

  test('fuzzy id resolves a typoed target', () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('greet', 'b!', 'hola'); // model typo
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    var greeted = false;
    e.events.listen((ev) {
      if (ev.data['line'] == 'hola') greeted = true;
    });
    for (var i = 0; i < 60 && !greeted; i++) {
      if (i < 20) {
        e.agents['a']!.x = 0;
        e.agents['a']!.y = 0;
        e.agents['b']!.x = 30;
        e.agents['b']!.y = 0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(greeted, isTrue,
        reason: 'greet(b!) should resolve to greet(b) and fire the line');
  });

  test('rescue errand sends the name-holder to the fading spirit', () async {
    final b = await _boot();
    final e = b.engine;
    final bor = e.agents['b']!..battery = 4;
    bor.faded = true;
    // a holds s1 — wakes_agent: b. Next decision assigns the rescue errand.
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    await _pump(e, ticks: 30);
    expect(e.agents['a']!.errand?.kind, 'seek');
    expect(e.agents['a']!.errand?.targetId, 'b');
  });

  test('scheduled gathering: past 60% of the night everyone tends the ofrenda',
      () async {
    final b = await _boot();
    final e = b.engine;
    e.simTs = 600; // dawnAt 900 → 60% = 540
    // clear any current errand so ensureErrand picks fresh
    e.agents['a']!.errand = null;
    e.agents['a']!.verifiedPois.add('p1'); // no verify pending
    e.agents['a']!.knownSecrets.clear(); // nothing to tell
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    await _pump(e, ticks: 30);
    expect(e.agents['a']!.errand?.kind, 'tend');
    expect(e.agents['a']!.errand?.targetId, 'ofrenda');
  });

  test('persona schedule phase moves the tend target', () async {
    // a's persona has no schedule in _personas — inject one directly
    final b = await _boot();
    final e = b.engine;
    final ana = e.agents['a']!;
    ana.schedule = const [(at: 50, poi: 'p2')];
    ana.verifiedPois.add('p1');
    ana.knownSecrets.clear();
    e.simTs = 100; // past the phase boundary
    ana.errand = null;
    ana.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    await _pump(e, ticks: 30);
    expect(ana.errand?.kind, 'tend');
    expect(ana.errand?.targetId, 'p2');
  });

  test('director gathering beat moves every idle errand to the poi', () async {
    final llm = _ScriptedLLM()
      ..forcedBeat = {'beat': 'gathering', 'poi': 'p1', 'line': null};
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.simTs = 100; // director's first beat fires at 90
    final ana = e.agents['a']!;
    ana.verifiedPois.add('p1');
    ana.knownSecrets.clear();
    ana.errand = null;
    ana.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 40 && ana.errand?.targetId != 'p1'; i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(llm.prompts.any((p) => p.contains('storyteller')), isTrue,
        reason: 'the director prompt should have been sent');
    expect(ana.errand?.kind, 'tend');
    expect(ana.errand?.targetId, 'p1');
  });

  test('completed convo warms both speakers', () async {
    final b = await _boot();
    final e = b.engine;
    e.startConversation('a', 'b');
    await _pump(e, ticks: 40);
    expect(e.agents['a']!.warmth['b'], greaterThanOrEqualTo(2));
    expect(e.agents['b']!.warmth['a'], greaterThanOrEqualTo(2));
    // and the bond is persisted to the world kv
    expect(await b.store.getWorld('warmth.a'), contains('b'));
  });

  test('purpose convo starts with a purpose flag for the spark cue',
      () async {
    final b = await _boot();
    final e = b.engine;
    var sawPurpose = false;
    e.events.listen((ev) {
      if (ev.data['purpose'] == true) sawPurpose = true;
    });
    e.startConversation('a', 'b', purpose: (holder: 'a', secretId: 's1'));
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(sawPurpose, isTrue,
        reason: 'pairStart should carry purpose:true for the ✨ cue');
  });

  test('asking an engaged spirit a question teaches the player', () async {
    final b = await _boot();
    final e = b.engine;
    e.engage('a'); // Ana knows s1, player doesn't
    await for (final _ in e.sendPlayerMessage('what do you know?')) {}
    expect(e.playerKnown, contains('s1'),
        reason: 'a question should draw out a held secret');
    e.disengage();
  });

  test('idle and stroll leave the menu while knowledge could move', () async {
    final llm = _ScriptedLLM();
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 30; i++) {
      e.agents['a']!.x = 0;
      e.agents['a']!.y = 0;
      e.agents['b']!.x = 30;
      e.agents['b']!.y = 0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final aPrompt =
        llm.prompts.firstWhere((p) => p.contains('You are Ana'), orElse: () => '');
    // share(b,s1) is on the menu → drift options must not be
    expect(aPrompt, contains('share(b,s1)'));
    final menu = aPrompt.split('Choose ONE of:').last.split('- ').first;
    expect(menu, isNot(contains('idle')));
    expect(menu, isNot(contains('stroll')));
  });

  test('director rumor beat lands as an overheard memory', () async {
    final llm = _ScriptedLLM()
      ..forcedBeat = {
        'beat': 'rumor',
        'poi': 'p1',
        'line': 'the lane hums after midnight',
      };
    final b = await _boot(llm: llm);
    final e = b.engine;
    e.simTs = 100;
    var overheard = false;
    for (var i = 0; i < 40 && !overheard; i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      // the two nearest spirits get the rumor in their memory stream —
      // importance 6 outranks fresh observations in recall
      for (final a in e.agents.values) {
        final ms = await b.store.recall(a, e.simTs);
        if (ms.any((m) => m.text.contains('lane hums'))) overheard = true;
      }
    }
    expect(overheard, isTrue,
        reason: 'the rumor should enter at least one memory stream');
  });

  // ======================= rumor ecology (the headline arc) ===============

  /// Five spirits so the ≥4-knower verdict can pass. 'a' is a cold teller
  /// (warmth/mischief 0 — needs a bond); 'c' is the gossip (mischief 4).
  const rumorPersonas = '''
[{"id":"a","name":"Ana","role":"s","persona":"cold","stats":{"curiosity":5,"wit":1,"warmth":0,"spirit_sight":0,"mischief":0,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"b","name":"Bor","role":"s","persona":"plain","stats":{"curiosity":0,"wit":1,"warmth":0,"spirit_sight":0,"mischief":0,"grump":0},"home":"p2","sprite":"sk_base","initial_secrets":[]},
 {"id":"c","name":"Che","role":"s","persona":"gossip","stats":{"curiosity":3,"wit":1,"warmth":1,"spirit_sight":0,"mischief":4,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"d","name":"Del","role":"s","persona":"plain","stats":{"curiosity":1,"wit":1,"warmth":1,"spirit_sight":0,"mischief":0,"grump":0},"home":"p2","sprite":"sk_base","initial_secrets":[]},
 {"id":"e","name":"Eli","role":"s","persona":"plain","stats":{"curiosity":1,"wit":1,"warmth":1,"spirit_sight":0,"mischief":0,"grump":0},"home":"p2","sprite":"sk_base","initial_secrets":[]}]
''';

  String rumorSecrets({int deepKnowers = 4}) {
    final all = ['b', 'c', 'd', 'e'];
    final knowers =
        all.take(deepKnowers).map((id) => '"$id"').join(',');
    return '''
[{"id":"head","surface":"empty frame","truth":"b removed it","share_text":"b took the photo down",
  "initially_known_by":["a"],"unlocks_poi_lore":"ofrenda","about_agent":"b","headline":true,"tier":"rumor"},
 {"id":"own","surface":"a glances","truth":"a did it","share_text":"a took it down herself",
  "initially_known_by":["a"],"about_agent":"a","tier":"rumor"},
 {"id":"deep","surface":"name goes quiet","truth":"the betrayal","share_text":"the deep truth",
  "initially_known_by":[$knowers],"about_agent":"b","verdict_of":"head",
  "verdict_pass":"the photo returns","verdict_fail":"stays dark","tier":"rumor"}]
''';
  }

  Future<SimBundle> bootRumor({
    LLMClient? llm,
    int deepKnowers = 4,
  }) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('simtest');
    return bootstrap(
      personasJson: rumorPersonas,
      secretsJson: rumorSecrets(deepKnowers: deepKnowers),
      pois: const [
        Poi(id: 'p1', name: 'P1', surfaceText: 'just a lane', x: 0, y: 0),
        Poi(id: 'p2', name: 'P2', surfaceText: 'just a stall', x: 10, y: 10),
        Poi(id: 'ofrenda', name: 'Ofrenda', surfaceText: 'the shrine', x: 40, y: 40),
      ],
      homePos: const {'p1': [0, 0], 'p2': [10, 10]},
      llm: llm ?? MockLLMClient(seed: 1),
      rng: Random(1),
      freshDb: true,
      dbPath: '${dir.path}/t.db',
    );
  }

  /// Pin everyone adjacent but only [id] due for a decision, then collect
  /// the prompt the engine built for them.
  Future<String> promptFor(
    dynamic e,
    _ScriptedLLM llm,
    String id,
  ) async {
    for (final a in e.agents.values) {
      a.lastActedAt = a.id == id ? -999.0 : 99999.0;
      a.x = a.id == id ? 0.0 : 30.0;
      a.y = 0.0;
    }
    llm.prompts.clear();
    for (var i = 0; i < 30 && llm.prompts.isEmpty; i++) {
      for (final a in e.agents.values) {
        a.x = a.id == id ? 0.0 : 30.0;
        a.y = 0.0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    return llm.prompts.isEmpty ? '' : llm.prompts.first;
  }

  test('cold teller cannot offer a rumor until a bond forms', () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    // a knows 'head' (about b) but warmth/mischief 0 and no bond → gated
    var p = await promptFor(e, llm, 'a');
    expect(p, isNot(contains('share(b,head)')),
        reason: 'a cold teller should not be offered rumor shares');
    // converse comes back when no legal share exists for the pair
    expect(p, contains('converse(b)'));
    // a real bond opens the channel
    e.agents['a']!.warmth['b'] = 2;
    p = await promptFor(e, llm, 'a');
    expect(p, contains('share(b,head)'));
  });

  test('gossip leaks rumor with no bond at all', () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.agents['c']!.knownSecrets.add('head'); // the gossip heard it too
    final p = await promptFor(e, llm, 'c');
    expect(p, contains('share(b,head)'),
        reason: 'mischief≥3 shares rumor to anyone — no bond needed');
  });

  test('self-scandal stays buried until deep trust', () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.agents['a']!.warmth['b'] = 3; // friendly, not trusted
    var p = await promptFor(e, llm, 'a');
    expect(p, contains('share(b,head)')); // about b: bond≥2 suffices
    expect(p, isNot(contains('share(b,own)')),
        reason: 'a secret ABOUT the teller needs warmth≥4');
    e.agents['a']!.warmth['b'] = 4;
    p = await promptFor(e, llm, 'a');
    expect(p, contains('share(b,own)'));
  });

  test('organic rumor leak is rejected when the channel is closed', () async {
    final llm = _ScriptedLLM()..forcedShare = 'head';
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.startConversation('a', 'b'); // cold teller, no bond
    await _pump(e, ticks: 60);
    expect(e.agents['b']!.knownSecrets, isNot(contains('head')));
  });

  test('verdict passes when the deep truth reaches ≥4 spirits', () async {
    final b = await bootRumor(deepKnowers: 4);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.simTs = (e.dawnAt * 0.8).ceil() - 1;
    await _pump(e, ticks: 10);
    await sub.cancel();
    expect(events.any((ev) => ev.type == SimEventType.log && 
        (ev.data['text'] as String).contains('photo returns')), isTrue);
    expect(
      events.any((ev) =>
          ev.type == SimEventType.poiGlow && ev.data['poi'] == 'ofrenda'),
      isTrue,
    );
  });

  test('verdict fails when the truth stayed whispers', () async {
    final b = await bootRumor(deepKnowers: 2);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.simTs = (e.dawnAt * 0.8).ceil() - 1;
    await _pump(e, ticks: 10);
    await sub.cancel();
    expect(events.any((ev) => ev.type == SimEventType.log &&
        (ev.data['text'] as String).contains('stays dark')), isTrue);
  });
}
