/// Bootstrap — loads personas/secrets JSON, builds agents, opens the store,
/// returns a ready SimEngine. Usable from app and headless eval.
library;

import 'dart:convert';
import 'dart:math';

import 'engine.dart';
import 'llm.dart';
import 'models.dart';
import 'store.dart';

class SimBundle {
  final SimEngine engine;
  final SimStore store;
  final Map<String, String> sprites;
  final Map<String, int> tints; // agentId -> 0xAARRGGBB aura ring color
  final Map<String, int> dyes; // agentId -> 0xAARRGGBB sprite palette swap
  SimBundle(this.engine, this.store, this.sprites, this.tints, this.dyes);
}

Future<SimBundle> bootstrap({
  required String personasJson,
  required String secretsJson,
  String whispersJson = '[]',
  required List<Poi> pois,
  required Map<String, List<double>> homePos,
  LLMClient? llm,
  Random? rng,
  double timeScale = 1.0,
  int festivalAt = 900,
  bool freshDb = true,
  String dbPath = 'pueblo_sim.db',
  String culpritId = 'ramon',
}) async {
  final r = rng ?? Random(7);
  final personas = jsonDecode(personasJson) as List<dynamic>;
  final secretsList = jsonDecode(secretsJson) as List<dynamic>;
  final whispersList = jsonDecode(whispersJson) as List<dynamic>;

  final whisperBeats = [
    for (final w in whispersList)
      (
        id: '${w['id']}',
        speaker: '${w['speaker']}',
        to: w['to'] == null ? null : '${w['to']}',
        line: '${w['line']}',
        grants: w['grants'] == null ? null : '${w['grants']}',
        canon: [
          for (final c in (w['canon'] as List? ?? const [])) '$c',
        ],
        at: w['at'] is int ? w['at'] as int : 0,
      ),
  ];

  final secrets = <String, Secret>{
    for (final s in secretsList) (s['id'] as String): Secret.fromJson(s),
  };

  // Authoritative starting knowledge comes from secrets.json
  // (`initially_known_by`) — persona initial_secrets is redundant/ignored.
  final known = <String, Set<String>>{};
  for (final s in secrets.values) {
    for (final id in s.initiallyKnownBy) {
      known.putIfAbsent(id, () => {}).add(s.id);
    }
  }

  final agents = <String, Agent>{};
  final sprites = <String, String>{};
  final tints = <String, int>{};
  final dyes = <String, int>{};
  for (final p in personas) {
    final a = Agent(
      id: p['id'],
      name: p['name'],
      role: p['role'],
      persona: p['persona'],
      stats: Stats.fromJson(p['stats']),
      home: p['home'],
      battery: p['id'] == 'solorio' ? 6 : 70 + r.nextDouble() * 20,
    );
    a.hook = p['hook'] as String?;
    a.schedule = [
      for (final s in (p['schedule'] as List? ?? const []))
        (at: s['at'] as int, poi: s['poi'] as String),
    ];
    final home = homePos[a.home] ?? [704.0, 336.0];
    a.x = home[0];
    a.y = home[1];
    a.knownSecrets.addAll(known[a.id] ?? const {});
    if (a.battery <= 8) a.faded = true;
    agents[a.id] = a;
    sprites[a.id] = p['sprite'] ?? 'sk_base';
    final hex = (p['tint'] as String?)?.replaceFirst('#', '');
    if (hex != null) tints[a.id] = int.parse('FF$hex', radix: 16);
    final dye = (p['dye'] as String?)?.replaceFirst('#', '');
    if (dye != null) dyes[a.id] = int.parse('FF$dye', radix: 16);
  }

  final store = await SimStore.open(path: dbPath, fresh: freshDb);
  final engine = SimEngine(
    store: store,
    llm: llm ?? MockLLMClient(),
    agents: agents,
    secrets: secrets,
    pois: {for (final p in pois) p.id: p},
    rng: r,
    timeScale: timeScale,
    festivalAt: festivalAt,
    culpritId: culpritId,
    whispers: whisperBeats,
  );
  // Resume path — planted rumors survive a restart (freshDb wipes them,
  // which is correct: a new day, new whispers).
  if (!freshDb) {
    final raw = await store.getWorld('claims');
    if (raw != null) {
      for (final j in jsonDecode(raw) as List) {
        final cl = Claim.fromJson(j as Map<String, dynamic>);
        engine.claims[cl.id] = cl;
        final n = int.tryParse(cl.id.replaceFirst('claim_', ''));
        if (n != null && n > engine.claimSeq) engine.claimSeq = n;
      }
    }
  }
  return SimBundle(engine, store, sprites, tints, dyes);
}
