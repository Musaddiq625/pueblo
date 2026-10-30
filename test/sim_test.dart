/// Targeted sim unit tests — knowledge isolation, atomic transfer,
/// engagement semantics. No Flutter widgets, no network.
library;

import 'dart:convert';
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
  String? forcedReply; // raw playerChat output — may be JSON or plain text

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

  @override
  Stream<String> playerChat(String prompt) async* {
    prompts.add(prompt);
    yield forcedReply ?? 'a canned reply';
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
    e.startConversation('a', 'b', purpose: (holder: 'a', subject: 's1', isClaim: false));
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
    e.simTs = 600; // festivalAt 900 → 60% = 540
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
    e.startConversation('a', 'b', purpose: (holder: 'a', subject: 's1', isClaim: false));
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
 {"id":"d","name":"Del","role":"s","persona":"skeptic","stats":{"curiosity":3,"wit":4,"warmth":1,"spirit_sight":0,"mischief":0,"grump":0},"home":"p2","sprite":"sk_base","initial_secrets":[]},
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
  "verdict_pass":"the photo returns","verdict_fail":"stays dark","tier":"rumor"},
 {"id":"head_lie","surface":"empty frame","truth":"she sold it too","share_text":"b stole the photo outright",
  "initially_known_by":[],"about_agent":"b","variant_of":"head","tier":"rumor"}]
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

  test('verdict resolves the moment a fourth mouth learns the truth', () async {
    // earned path — no festival clock needed: the fourth learn fires it
    final b = await bootRumor(deepKnowers: 3);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.playerKnown.add('deep');
    e.playerChatCount['a'] = 3; // warmth gate — a believes the living one
    await e.teachSpirit('a', 'deep');
    await Future<void>.delayed(Duration.zero); // flush the event broadcast
    await sub.cancel();
    expect(events.any((ev) =>
        ev.type == SimEventType.verdict && ev.data['passed'] == true), isTrue);
    expect(
      events.any((ev) =>
          ev.type == SimEventType.poiGlow && ev.data['poi'] == 'ofrenda'),
      isTrue,
    );
    // …and the world never halted
    expect(events.any((ev) => ev.type == SimEventType.endRun), isTrue);
  });

  test('verdict passes at the festival mark when ≥4 spirits know', () async {
    final b = await bootRumor(deepKnowers: 4);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.simTs = e.festivalAt - 1; // clock fallback only fires at festivalAt
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
    e.simTs = e.festivalAt - 1;
    await _pump(e, ticks: 10);
    await sub.cancel();
    expect(events.any((ev) => ev.type == SimEventType.log &&
        (ev.data['text'] as String).contains('stays dark')), isTrue);
  });

  test('the world keeps running after the resolution report', () async {
    final b = await bootRumor(deepKnowers: 2);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.simTs = e.festivalAt - 1;
    await _pump(e, ticks: 10);
    final tsAfterResolution = e.simTs;
    await _pump(e, ticks: 20);
    await sub.cancel();
    expect(events.any((ev) => ev.type == SimEventType.endRun), isTrue);
    expect(e.simTs, greaterThan(tsAfterResolution),
        reason: 'no halt — the festival continues behind the card');
    expect(
      events.where((ev) => ev.type == SimEventType.endRun).length,
      1,
      reason: 'the resolution report is one-shot',
    );
  });

  // ============ reply hygiene, curiosity aliases, directives ============

  test('PlayerReply filters model null-words', () {
    expect(PlayerReply.parse('Null').say, isNull);
    expect(PlayerReply.parse('{"say":"Null"}').say, isNull);
    expect(PlayerReply.parse('{"say":"None"}').say, isNull);
    expect(PlayerReply.parse('{"say":"N/A"}').say, isNull);
    expect(PlayerReply.parse('{"say":"hola"}').say, 'hola');
    expect(PlayerReply.parse('null').say, isNull);
  });

  test('place-words send the curious to look (alias matching)', () async {
    final b = await _boot();
    final e = b.engine;
    e.engage('a'); // Ana: curiosity 5
    await for (final _ in e.sendPlayerMessage('the altar glows after dark')) {}
    expect(e.agents['a']!.errand?.kind, 'verify');
    expect(e.agents['a']!.errand?.targetId, 'ofrenda',
        reason: '"altar" is an ofrenda alias — should trigger the verify errand');
    e.disengage();
  });

  // Personas with ≥4-char ids — directive matching ignores short ids by
  // design ("luz" must not match inside everyday words).
  Future<SimBundle> bootNamed({LLMClient? llm}) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final dir = await Directory.systemTemp.createTemp('simtest');
    const personas = '''
[{"id":"anita","name":"Anita","role":"s","persona":"kind","stats":{"curiosity":5,"wit":1,"warmth":5,"spirit_sight":0,"mischief":0,"grump":0},"home":"p1","sprite":"sk_base","initial_secrets":[]},
 {"id":"bruno","name":"Bruno","role":"s","persona":"plain","stats":{"curiosity":1,"wit":1,"warmth":1,"spirit_sight":0,"mischief":0,"grump":0},"home":"p2","sprite":"sk_base","initial_secrets":["s1"]}]
''';
    return bootstrap(
      personasJson: personas,
      secretsJson: _secrets,
      pois: const [
        Poi(id: 'p1', name: 'P1', surfaceText: 'just a lane', x: 0, y: 0),
        Poi(id: 'p2', name: 'P2', surfaceText: 'just a stall', x: 10, y: 10),
        Poi(id: 'ofrenda', name: 'Ofrenda', surfaceText: 'the shrine', x: 40, y: 40),
        Poi(id: 'grave_37', name: 'Grave 37', surfaceText: 'nameless stone', x: 60, y: 60),
      ],
      homePos: const {'p1': [0, 0], 'p2': [10, 10]},
      llm: llm ?? MockLLMClient(seed: 1),
      rng: Random(1),
      freshDb: true,
      dbPath: '${dir.path}/t.db',
    );
  }

  test('"ask bruno about his secret" sends the spirit to him — and it lands',
      () async {
    final b = await bootNamed();
    final e = b.engine;
    // park them close so the approach resolves fast
    e.agents['anita']!.x = 0; e.agents['anita']!.y = 0;
    e.agents['bruno']!.x = 40; e.agents['bruno']!.y = 0;
    e.engage('anita');
    await for (final _ in e.sendPlayerMessage('ask bruno about his secret')) {}
    e.disengage();
    expect(e.agents['anita']!.errand?.targetId, 'bruno',
        reason: 'the imperative routes a seek errand to the named spirit');
    // approach is in flight — pump until the ask-convo lands
    await _pump(e, ticks: 30);
    expect(
      e.conversations.isNotEmpty || e.agents['anita']!.inConvo,
      isTrue,
      reason: 'anita should reach bruno and start talking',
    );
    // the audit trail shows the routing
    final log = await b.store.tailLog(10);
    expect(log.any((r) => r['kind'] == 'directive'), isTrue);
    expect(log.any((r) => r['kind'] == 'reply'), isTrue);
  });

  test('"hiding a secret" is a rumor, not a question — plants, steers reply, sparks curiosity',
      () async {
    // Regression: "Bruno hiding a secret near grave 37" contains the word
    // 'secret' and used to be classified as an ask — no claim planted, no
    // curiosity, and the model free-associated its own stories instead.
    final llm = _ScriptedLLM()
      ..forcedReply = '{"say":"oh?","react":"curious","believes":true}';
    final b = await bootNamed(llm: llm);
    final e = b.engine;
    e.engage('anita');
    await for (final _
        in e.sendPlayerMessage('bruno hiding a secret near grave 37')) {}
    expect(e.claims, isNotEmpty,
        reason: 'a rumor containing "secret" is still a rumor — it must plant');
    expect(e.claims.values.first.about, contains('bruno'),
        reason: 'the claim should tag its named subject');
    expect(e.agents['anita']!.goal, 'askAbout:grave_37',
        reason: 'naming a place makes the spirit want to know about it');
    expect(e.agents['anita']!.errand?.kind, 'verify',
        reason: 'her go-look errand rides — the whisper hop is guaranteed '
            'by the pending approach, not the errand slot');
    // the prompt tells the model it was handed a rumor — to weigh, not derail
    expect(
      llm.prompts.last,
      contains('rumor about Bruno'),
      reason: 'the spirit should be told to react to the rumor itself',
    );
  });

  test('chat history survives release — kept per spirit, not shared',
      () async {
    // Regression: playerHist used to clear on every engage — reopening a
    // spirit forgot the whole conversation and repeats felt bot-like.
    final b = await bootNamed();
    final e = b.engine;
    e.engage('anita');
    await for (final _ in e.sendPlayerMessage('the fountain is haunted')) {}
    expect(e.playerHistoryFor('anita'), isNotEmpty);
    e.engage('bruno'); // auto-releases anita
    expect(e.playerHistoryFor('bruno'), isEmpty,
        reason: 'bruno never heard what was said to anita');
    e.engage('anita'); // back to her — the thread returns
    final h = e.playerHistoryFor('anita');
    expect(h.any((m) => m.isUser && m.text.contains('fountain')), isTrue,
        reason: 'anita remembers what the living one told her earlier');
  });

  test('a whisper about someone can be sent straight to them', () async {
    final llm = _ScriptedLLM()
      ..forcedReply = '{"say":"oh?","react":"curious","believes":true}';
    final b = await bootNamed(llm: llm);
    final e = b.engine;
    e.agents['anita']!.x = 0; e.agents['anita']!.y = 0;
    e.agents['bruno']!.x = 40; e.agents['bruno']!.y = 0;
    e.engage('anita');
    await for (final _ in e.sendPlayerMessage('go tell bruno the fountain is haunted')) {}
    e.disengage();
    await _pump(e, ticks: 40);
    expect(
      e.claims.values.any((cl) => cl.version.containsKey('bruno')),
      isTrue,
      reason: 'the claim should reach its subject via the directed carrier',
    );
  });

  test('a follow-up order does not stomp the directive still queued', () async {
    // "Bruno got some secrets, find out" then "You have to find out" —
    // the second message is a targetless order, not a rumor: no claim,
    // no confidant hop, and the ask(bruno) approach must survive.
    final llm = _ScriptedLLM()
      ..forcedReply = '{"say":"hm?","react":"curious","believes":true}';
    final b = await bootNamed(llm: llm);
    final e = b.engine;
    e.agents['anita']!.x = 0; e.agents['anita']!.y = 0;
    e.agents['bruno']!.x = 40; e.agents['bruno']!.y = 0;
    e.engage('anita');
    await for (final _
        in e.sendPlayerMessage('bruno got some secrets, find out')) {}
    await for (final _
        in e.sendPlayerMessage('you have to find out')) {}
    e.disengage();
    expect(e.claims, hasLength(1),
        reason: 'the declarative front seeds — only the imperative tail '
            'stays an order, and "you have to find out" names nothing');
    expect(e.claims.values.first.text, contains('bruno'),
        reason: 'the claim carries the rumor, not the order');
    for (var i = 0;
        i < 160 && !e.conversations.isNotEmpty && !e.agents['anita']!.inConvo;
        i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    final log = await b.store.tailLog(30);
    expect(log.any((r) => r['kind'] == 'directive'), isTrue);
    expect(
      e.conversations.isNotEmpty || e.agents['anita']!.inConvo,
      isTrue,
      reason: 'anita should still reach bruno — the order stood',
    );
  });

  // =============== player-planted rumors (D1/D2) + P0 fixes ===============

  test('mischievous teller passes the embellished variant, not the truth',
      () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('share', 'b', 'have you heard?');
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.agents['c']!.knownSecrets.add('head'); // Che knows the truth…
    e.agents['c']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    // pin c next to b and let the share → purpose convo complete
    for (var i = 0; i < 80 && !e.agents['b']!.knownSecrets.contains('head_lie'); i++) {
      if (i < 20) {
        e.agents['c']!.x = 0.0;
        e.agents['c']!.y = 0.0;
        e.agents['b']!.x = 30.0;
        e.agents['b']!.y = 0.0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.agents['b']!.knownSecrets, contains('head_lie'),
        reason: 'mischief≥4 passes the lie, not the truth');
    expect(e.agents['b']!.knownSecrets, isNot(contains('head')));
    expect(e.agents['c']!.knownSecrets, containsAll(['head', 'head_lie']),
        reason: 'the teller keeps the truth AND their own embellishment');
  });

  test('truthful teller never distorts', () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('share', 'b', 'have you heard?');
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    // Ana (mischief 0) knows 'head' — but cold, needs a bond to pass a rumor
    e.agents['a']!.warmth['b'] = 3;
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    for (var i = 0; i < 80 && !e.agents['b']!.knownSecrets.contains('head'); i++) {
      if (i < 20) {
        e.agents['a']!.x = 0.0;
        e.agents['a']!.y = 0.0;
        e.agents['b']!.x = 30.0;
        e.agents['b']!.y = 0.0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(e.agents['b']!.knownSecrets, contains('head'));
    expect(e.agents['b']!.knownSecrets, isNot(contains('head_lie')),
        reason: 'warm-bonded truthful teller passes the truth itself');
  });

  test('player teach: trusting spirit believes and learns', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.learnSecretAsPlayer('own', 'test');
    // Del doesn't believe a stranger yet — 3 chats earns rapport
    e.engage('d');
    for (var i = 0; i < 3; i++) {
      await for (final _ in e.sendPlayerMessage('hola $i')) {}
    }
    final note = await e.teachSpirit('d', 'own');
    expect(note, contains('believes'));
    expect(e.agents['d']!.knownSecrets, contains('own'));
  });

  test('player teach: skeptic refuses but goes to verify the claim',
      () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.learnSecretAsPlayer('head', 'test'); // head unlocks ofrenda lore
    final note = await e.teachSpirit('d', 'head');
    expect(note, contains('see for themselves'));
    expect(e.agents['d']!.knownSecrets, isNot(contains('head')),
        reason: 'wit≥4 skeptics don\'t take a stranger\'s word');
    expect(e.agents['d']!.goal, 'askAbout:ofrenda');
  });

  test('hearing their own scandal from the player is a jolt', () async {
    final b = await bootRumor(deepKnowers: 2, llm: _ScriptedLLM());
    final e = b.engine;
    // 'head' is about b but only a knows it — telling b directly
    e.learnSecretAsPlayer('head', 'test');
    final note = await e.teachSpirit('b', 'head');
    expect(note, contains('goes very still'));
    expect(e.agents['b']!.knownSecrets, contains('head'));
    expect(e.agents['b']!.mood, 'shaken');
  });

  test('player ask-and-learn respects the rumor gate (B3)', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.engage('a');
    // one message isn't rapport — rumor-tier stays sealed
    await for (final _ in e.sendPlayerMessage('what do you know?')) {}
    expect(e.playerKnown, isNot(contains('head')),
        reason: 'a stranger gets no gossip');
    // rapport ≥2 opens the rumor channel
    await for (final _ in e.sendPlayerMessage('what do you know?')) {}
    expect(e.playerKnown, contains('head'));
    // the teller's own scandal needs rapport AND a gift
    await for (final _ in e.sendPlayerMessage('what else do you know?')) {}
    expect(e.playerKnown, isNot(contains('own')),
        reason: 'rapport alone doesn\'t open her own scandal');
    e.playerInventory['bouquet'] = 1;
    await e.giveGift('a', 'bouquet');
    await for (final _ in e.sendPlayerMessage('tell me the truth?')) {}
    expect(e.playerKnown, contains('own'),
        reason: 'rapport + a kindness earns the confession');
  });

  test('typed claim naming a place sets a curiosity goal (D2)', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.engage('a');
    await for (final _ in e.sendPlayerMessage('the ofrenda looks different tonight')) {}
    expect(e.agents['a']!.goal, 'askAbout:ofrenda');
    // the curious keep their go-look errand — the whisper still reaches a
    // confidant via the guaranteed pending approach, then they go see
    expect(e.agents['a']!.errand?.kind, 'verify');
    expect(e.agents['a']!.errand?.claim, isTrue);
  });

  test('a nameless greeting does NOT revive a fading spirit (B5)', () async {
    final llm = _ScriptedLLM()
      ..forcedDecision = Decision('greet', 'b', 'evening.');
    final b = await _boot(llm: llm);
    final e = b.engine;
    final bor = e.agents['b']!;
    bor.battery = 5; // high enough that +5 would revive under the old rule
    bor.faded = true;
    e.agents['a']!.knownSecrets.clear(); // Ana doesn't know the name
    e.agents['a']!.lastActedAt = -999;
    e.agents['b']!.lastActedAt = 99999;
    var greeted = false;
    for (var i = 0; i < 90; i++) {
      if (i < 40) {
        // real walkable plaza coords — nav.route can't reach tile (0,0)
        e.agents['a']!.x = 624.0;
        e.agents['a']!.y = 496.0;
        e.agents['b']!.x = 656.0;
        e.agents['b']!.y = 496.0;
      }
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      if (bor.battery > 5) greeted = true; // the +5 landed
    }
    expect(greeted, isTrue, reason: 'the nameless greet should still land');
    expect(bor.faded, isTrue,
        reason: 'only a name spoken aloud revives, not any greeting');
  });

  test('ask-purpose convo cannot end before the holder speaks (B9)', () async {
    final llm = _ScriptedLLM()..endNow = true; // every turn requests end
    final b = await _boot(llm: llm);
    final e = b.engine;
    // ask-purpose: a approaches b to draw out s1 — move ownership to b
    e.agents['a']!.knownSecrets.remove('s1');
    e.agents['b']!.knownSecrets.add('s1');
    e.startConversation('a', 'b',
        purpose: (holder: 'b', subject: 's1', isClaim: false));
    await _pump(e, ticks: 60);
    expect(e.agents['a']!.knownSecrets, contains('s1'),
        reason: 'end=true on the asker\'s opener can\'t kill the purpose');
  });

  test('petals spawn on the economy timer (B1)', () async {
    final b = await _boot();
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    await _pump(e, ticks: 100, dt: 1.0); // >petalEvery sim-seconds
    await sub.cancel();
    expect(events.any((ev) => ev.type == SimEventType.petalSpawn), isTrue);
  });

  test('purchases use the live petal balance (B2)', () async {
    final b = await _boot();
    final e = b.engine;
    e.playerPetals = 10;
    expect(await e.buyItem('bouquet'), isFalse,
        reason: '15-petal bouquet unaffordable at 10');
    expect(await e.buyItem('agua_fresca'), isTrue);
    expect(e.playerPetals, 2);
    expect(await e.store.getWorld('petals'), '2',
        reason: 'world kv mirrors the live balance');
  });

  test('gifts require engagement (B22)', () async {
    final b = await _boot();
    final e = b.engine;
    e.playerInventory['bouquet'] = 1;
    expect(await e.giveGift('a', 'bouquet'), isFalse,
        reason: 'can\'t gift a spirit you\'re not talking to');
    e.engage('a');
    expect(await e.giveGift('a', 'bouquet'), isTrue);
    expect(e.giftedAgents, contains('a'));
  });

  // ==================== player-planted rumors (claims) ====================

  test('a declarative message plants a claim the spirit carries', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.engage('a');
    await for (final _ in e.sendPlayerMessage('the night air tastes of iron')) {}
    expect(e.claims, hasLength(1));
    final cl = e.claims.values.first;
    expect(cl.version.containsKey('a'), isTrue,
        reason: 'the hearer carries the claim from that moment');
    expect(cl.text, 'the night air tastes of iron');
    // claims never touch the knowledge graph
    expect(e.agents['a']!.knownSecrets.where((s) => s.startsWith('claim_')),
        isEmpty);
    e.disengage();
  });

  test('questions ask, they don\'t seed — no claim on ?-shaped text',
      () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    e.engage('a');
    await for (final _ in e.sendPlayerMessage('what do you know?')) {}
    expect(e.claims, isEmpty);
    e.disengage();
  });

  test('the spirit may simply react instead of speaking', () async {
    final llm = _ScriptedLLM()
      ..forcedReply =
          '{"say":null,"react":"shock","believes":null,"share_with":null,"twist":null}';
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    final events = <SimEvent>[];
    final sub = e.events.listen(events.add);
    e.engage('a');
    final out = await e.sendPlayerMessage('bor hums the funeral march').toList();
    await Future<void>.delayed(Duration.zero);
    expect(out.last, '· gasps softly.',
        reason: 'a react-only reply renders as a nonverbal beat');
    expect(
        events.any((ev) =>
            ev.type == SimEventType.emote && ev.data['glyph'] == '❗'),
        isTrue,
        reason: 'the shock floats over their head in-world');
    expect(llm.prompts.last, contains('The village:'),
        reason: 'the cast block gives the model the who\'s-who');
    await sub.cancel();
    e.disengage();
  });

  test('LLM intent drives the spread: believes + names the carrier', () async {
    final llm = _ScriptedLLM()
      ..forcedReply =
          '{"say":"¡Virgencita!","react":"shock","believes":true,"share_with":"b","twist":null}';
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.engage('a');
    final out = await e.sendPlayerMessage('the marigolds wilted early').toList();
    expect(out.last, '¡Virgencita!');
    final cl = e.claims.values.first;
    expect(cl.believers, contains('a'),
        reason: 'the model declared belief — recorded');
    final er = e.agents['a']!.errand;
    expect(er?.kind, 'tell');
    expect(er?.targetId, 'b');
    expect(er?.subject, cl.id,
        reason: 'a claim-tagged tell errand carries the living one\'s words');
    e.disengage();
  });

  test('twisted retelling rides the telephone — verbatim stays in the ledger',
      () async {
    final llm = _ScriptedLLM()
      ..forcedReply =
          '{"say":"hmm","react":"curious","believes":true,"share_with":null,"twist":"the marigolds wilted into BONES"}';
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.engage('c'); // Che — mischief 4, twist-capable
    await for (final _ in e.sendPlayerMessage('the marigolds wilted early')) {}
    final cl = e.claims.values.first;
    expect(cl.heardBy('c'), 'the marigolds wilted into BONES',
        reason: 'the mischievous spirit holds their own embellishment');
    expect(cl.text, 'the marigolds wilted early',
        reason: 'the living one\'s verbatim words stay in the ledger');
    e.disengage();
    // ...and when Che passes it on, the twist is what travels
    e.startConversation('c', 'b',
        purpose: (holder: 'c', subject: cl.id, isClaim: true));
    await _pump(e, ticks: 60);
    expect(cl.heardBy('b'), 'the marigolds wilted into BONES',
        reason: 'telephone: the receiver inherits the twisted version');
    expect(e.agents['b']!.knownSecrets.where((s) => s.startsWith('claim_')),
        isEmpty,
        reason: 'rumors never enter the secret ledger');
  });

  test('a rumor about you only repeats to a trusted ear', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    final cl = Claim(
        id: 'claim_9', text: 'ana hides things', bornTs: 0, about: const ['a']);
    cl.version['a'] = 'ana hides things';
    e.claims[cl.id] = cl;
    e.startConversation('a', 'b',
        purpose: (holder: 'a', subject: 'claim_9', isClaim: true));
    await _pump(e, ticks: 60);
    expect(cl.version.containsKey('b'), isFalse,
        reason: 'your own rumor stays sealed to strangers');
    e.agents['a']!.warmth['b'] = 4; // deep trust opens even your own name
    e.startConversation('a', 'b',
        purpose: (holder: 'a', subject: 'claim_9', isClaim: true));
    await _pump(e, ticks: 60);
    expect(cl.version.containsKey('b'), isTrue);
  });

  test('hearing a rumor about yourself is a jolt', () async {
    final b = await bootRumor(llm: _ScriptedLLM());
    final e = b.engine;
    final cl = Claim(
        id: 'claim_8', text: 'bor digs at night', bornTs: 0, about: const ['b']);
    cl.version['a'] = 'bor digs at night';
    e.claims[cl.id] = cl;
    e.startConversation('a', 'b',
        purpose: (holder: 'a', subject: 'claim_8', isClaim: true));
    await _pump(e, ticks: 60);
    expect(cl.version['b'], 'bor digs at night',
        reason: 'the rumor reaches its subject — allowed, unlike re-telling');
    expect(e.agents['b']!.mood, 'shaken');
  });

  test('planted rumors appear as share() offers to their holders', () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.engage('c'); // Che — mischief 4, spreads to anyone
    await for (final _ in e.sendPlayerMessage('something wicked hums tonight')) {}
    e.disengage();
    final cl = e.claims.values.first;
    // The confidant hop is guaranteed now — the queued approach executes
    // and the claim actually changes mouths (no LLM offer needed).
    e.agents['c']!.x = 624.0;
    e.agents['c']!.y = 496.0;
    e.agents['b']!.x = 656.0;
    e.agents['b']!.y = 496.0;
    e.agents['a']!.x = 900.0; // parked far — only the named confidant hops
    e.agents['a']!.y = 900.0;
    for (var i = 0;
        i < 120 && cl.version.length == 1;
        i++) {
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
    }
    expect(cl.version.length, greaterThan(1),
        reason: 'the whisper must travel — at least one hop per plant');
    final log = await b.store.tailLog(30);
    expect(log.any((r) => r['kind'] == 'errand'), isTrue,
        reason: 'the carry errand lands in the audit trail');
  });

  test('every prompt carries the village cast', () async {
    final b = await _boot(llm: _ScriptedLLM());
    expect(b.engine.prompts.cast, contains('Ana'));
    expect(b.engine.prompts.cast, contains('Bor'));
  });

  test('end-to-end: share(x, claim_N) survives dispatch and transfers',
      () async {
    // The mock picked a claim offer — the whole pipeline must honor it:
    // fuzzy-id resolution, share dispatch, purpose convo, the transfer.
    // Regression for the _fuzzyId subject-set that once ate claim ids.
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    final cl = Claim(id: 'claim_7', text: 'the bridge hums', bornTs: 0);
    cl.version['a'] = 'the bridge hums';
    e.claims[cl.id] = cl;
    llm.forcedDecision = Decision('share', 'b', 'line', subject: 'claim_7');
    e.agents['a']!.lastActedAt = -999;
    var moved = false;
    for (var i = 0; i < 120 && !moved; i++) {
      // real walkable plaza coords so the approach completes
      e.agents['a']!.x = 624.0;
      e.agents['a']!.y = 496.0;
      e.agents['b']!.x = 656.0;
      e.agents['b']!.y = 496.0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      moved = cl.version.containsKey('b');
    }
    expect(moved, isTrue,
        reason: 'a picked claim share must travel the full pipeline');
  });

  // ==================== roster dossier ====================

  test('spiritDossier separates baseline knowledge from tonight\'s learning',
      () async {
    final b = await _boot();
    final e = b.engine;
    // 'a' woke knowing s1 — baseline, not learned.
    var d = await e.spiritDossier('a');
    expect(d.initialSecrets, 1);
    expect(d.learnedSecrets, isEmpty);
    expect(d.memoryCount, greaterThanOrEqualTo(0));
    expect(d.learningLevel, isNotEmpty);
    // teach 'a' something new tonight → learned grows, baseline doesn't
    final s2 = Secret(
      id: 's2',
      surface: 'x',
      truth: 'y',
      shareText: 'shares s2',
      initiallyKnownBy: const [],
    );
    e.secrets['s2'] = s2;
    e.agents['a']!.knownSecrets.add('s2');
    d = await e.spiritDossier('a');
    expect(d.initialSecrets, 1);
    expect(d.learnedSecrets, contains('s2'));
    expect(d.learningScore, greaterThan(0));
  });

  test('real data: every persona home/schedule + initial knower resolves',
      () async {
    // Data-integrity on the shipped JSON — catches typos in homes,
    // schedule POIs, and initially_known_by without a widget harness.
    final personas = (jsonDecode(
            File('assets/data/personas.json').readAsStringSync())
        as List)
        .cast<Map<String, dynamic>>();
    final secrets = (jsonDecode(
            File('assets/data/secrets.json').readAsStringSync())
        as List)
        .cast<Map<String, dynamic>>();
    final agentIds = personas.map((p) => p['id'] as String).toSet();
    final secretIds = secrets.map((s) => s['id'] as String).toSet();
    const realPois = {
      'bridge', 'flower_stall', 'cantina', 'curiosity_shop', 'fountain',
      'gravedigger_hut', 'cemetery_lane', 'grave_37', 'ancient_tree',
      'ofrenda', 'plaza',
    };
    for (final p in personas) {
      expect(realPois, contains(p['home']),
          reason: '${p['id']} home ${p['home']} must be a real POI');
      for (final sc in (p['schedule'] as List? ?? const [])) {
        expect(realPois, contains(sc['poi']),
            reason: '${p['id']} schedule POI ${sc['poi']} must exist');
      }
      for (final s in (p['initial_secrets'] as List? ?? const [])) {
        expect(secretIds, contains(s),
            reason: '${p['id']} initial secret $s must exist');
      }
    }
    for (final s in secrets) {
      for (final k in (s['initially_known_by'] as List? ?? const [])) {
        expect(agentIds, contains(k),
            reason: '${s['id']} knower $k must be a real agent');
      }
    }
  });

  // ==================== speed / spread / 💡 ====================

  test('locomotion scales with timeScale — legs obey the speed chip',
      () async {
    // Same walk, two speeds: the 4× run must cover ~4× the ground.
    final moved = <double, double>{};
    for (final scale in [1.0, 4.0]) {
      final llm = _ScriptedLLM();
      final b = await bootRumor(llm: llm);
      final e = b.engine;
      e.timeScale = scale;
      final a = e.agents['a']!;
      a.x = 624.0;
      a.y = 496.0; // real walkable plaza spot
      a.errand =
          (kind: 'tend', targetId: 'ofrenda', claim: false, subject: null);
      a.lastActedAt = -999;
      llm.forcedDecision = Decision('goto', 'ofrenda', 'to the shrine');
      // wait until the walk actually starts — decisions fire every 12
      // sim-s, so pump in half-second steps until a path is set
      for (var i = 0; i < 120 && a.x == 624.0 && a.y == 496.0; i++) {
        e.tick(0.5);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      final sx = a.x, sy = a.y;
      for (var i = 0; i < 4; i++) {
        e.tick(0.1);
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      moved[scale] = sqrt(pow(a.x - sx, 2) + pow(a.y - sy, 2));
    }
    expect(moved[1.0]!, greaterThan(5),
        reason: 'walk must actually start at 1×');
    expect(moved[4.0]!, greaterThan(moved[1.0]! * 3),
        reason: '4× time must move legs ~4× as far');
  });

  test('a whisper always finds a carrier — best friend if model is silent',
      () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    e.agents['a']!.warmth['b'] = 7; // b is a's closest confidant
    llm.forcedReply =
        '{"say":"oh?","react":"curious","believes":true}'; // no share_with
    e.engage('a');
    await for (final _ in e.sendPlayerMessage('the bridge hums a name')) {}
    final cl = e.claims.values.first;
    final errand = e.agents['a']!.errand;
    expect(errand?.kind, 'tell',
        reason: 'a planted whisper must earn at least one hop');
    expect(errand?.targetId, 'b');
    expect(errand?.subject, cl.id);
    expect(errand?.claim, isTrue);
    e.disengage();
  });

  test('receiving gossip pops a 💡 over the receiver\'s head', () async {
    final llm = _ScriptedLLM();
    final b = await bootRumor(llm: llm);
    final e = b.engine;
    final emotes = <Map<String, Object?>>[];
    e.events.listen((ev) {
      if (ev.type == SimEventType.emote) emotes.add(ev.data);
    });
    final cl = Claim(id: 'claim_9', text: 'the bridge hums', bornTs: 0);
    cl.version['a'] = 'the bridge hums';
    e.claims[cl.id] = cl;
    llm.forcedDecision = Decision('share', 'b', 'psst', subject: 'claim_9');
    e.agents['a']!.lastActedAt = -999;
    var moved = false;
    for (var i = 0; i < 120 && !moved; i++) {
      e.agents['a']!.x = 624.0;
      e.agents['a']!.y = 496.0;
      e.agents['b']!.x = 656.0;
      e.agents['b']!.y = 496.0;
      e.tick(0.5);
      await Future<void>.delayed(const Duration(milliseconds: 3));
      moved = cl.version.containsKey('b');
    }
    expect(moved, isTrue);
    expect(
      emotes.any((d) => d['agent'] == 'b' && d['glyph'] == '💡'),
      isTrue,
      reason: 'the receiver flashes 💡 the moment news lands',
    );
    expect(e.agents['b']!.newsUntil, greaterThan(e.simTs),
        reason: '…and keeps the 💡 marker under their name');
  });
}
