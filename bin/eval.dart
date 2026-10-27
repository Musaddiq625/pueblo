/// P0.5 — headless model proof harness.
/// Exercises the REAL Ollama client with the REAL decision/convo prompts,
/// measuring: JSON validity, action validity, latency (p50/p95), and how
/// throughput scales at 1 / 2 / 4 parallel requests on this M2/8GB.
///
/// Run:
///   dart run bin/eval.dart --model qwen3:4b-instruct-2507-q4_K_M
///   dart run bin/eval.dart --model gemma3:4b --parallel 1,2,4
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../lib/sim/llm.dart';
import '../lib/sim/models.dart';
import '../lib/sim/prompts.dart';

const _actions = {
  'stroll', 'converse', 'inspect', 'offer_secret', 'ask_about',
  'visit_poi', 'buy', 'wander_home', 'idle'
};

// A realistic 2-agent scenario the real prompts get fed.
final _ana = Agent(
  id: 'ana', name: 'Ana Luz', role: 'candlemaker',
  persona: 'warm, nosy, keeps everyone\'s flame',
  stats: const Stats(curiosity: 4, wit: 3, warmth: 5, spiritSight: 2, mischief: 1, grump: 0),
  home: 'plaza', x: 100, y: 100,
);
final _bor = Agent(
  id: 'bor', name: 'Bor Solorio', role: 'gravedigger',
  persona: 'gruff, knows where the bodies are, few words',
  stats: const Stats(curiosity: 1, wit: 2, warmth: 1, spiritSight: 3, mischief: 0, grump: 5),
  home: 'cemetery', x: 400, y: 300,
);

final _secret = Secret(
  id: 'tree_is_hollow', surface: 'the big ceiba creaks',
  truth: 'the ceiba is hollow and hides a locket',
  shareText: 'the old ceiba is hollow — something is hidden inside',
  initiallyKnownBy: const ['bor'],
);

void main(List<String> argv) async {
  final model = _arg(argv, 'model') ?? 'qwen3:4b-instruct-2507-q4_K_M';
  final parallels = (_arg(argv, 'parallel') ?? '1,2,4')
      .split(',').map(int.parse).toList();
  final rounds = int.parse(_arg(argv, 'rounds') ?? '6');

  final llm = OllamaClient(model: model, rng: Random(1));
  final secrets = {for (final s in [_secret]) s.id: s};
  final prompts = PromptBuilder(secrets);
  _ana.knownSecrets.add('tree_is_hollow');
  _bor.knownSecrets.add('tree_is_hollow');
  const legal = ['stroll', 'converse(bor)', 'inspect(ceiba)', 'idle'];

  print('=== pueblo model proof: $model ===');
  print('${llm.name}  (decide/convoTurn, format:json)\n');

  // --- correctness pass: are the JSONs valid + actions legal? ---
  var decideOk = 0, convoOk = 0, actionLegal = 0, decided = 0;
  final decideLat = <int>[], convoLat = <int>[];

  for (var i = 0; i < rounds; i++) {
    // decide — Ana with a visible Bor, legal action menu
    final dp = prompts.decisionPrompt(
      _ana,
      simClock: 'noche 1, hora 2',
      place: 'plaza',
      nearbyEntities: 'Bor Solorio (gravedigger), the ceiba tree',
      memories: const ['lit the plaza candles', 'saw Bor by the fountain'],
      allowedActions: legal,
    );
    final t0 = DateTime.now();
    final d = await llm.decide(dp);
    decideLat.add(DateTime.now().difference(t0).inMilliseconds);
    if (d != null) {
      decided++;
      if (_actions.contains(d.action)) { decideOk++; actionLegal++; }
      if (d.line.trim().isNotEmpty) decideOk++;
    }

    // convo turn — Bor replying to Ana, single speaker, isolated knowledge
    final cp = prompts.convoTurnPrompt(
      _bor, _ana,
      transcript: const ['Ana: the night smells of marigold, no?'],
      context: 'in the plaza, candles burning',
    );
    final t1 = DateTime.now();
    final c = await llm.convoTurn(cp);
    convoLat.add(DateTime.now().difference(t1).inMilliseconds);
    if (c != null && c.line.trim().isNotEmpty) {
      convoOk++;
      // if it shared a secret, it must be one Bor actually knows
      if (c.sharesSecret != null &&
          !['tree_is_hollow'].contains(c.sharesSecret)) convoOk--;
    }
  }

  print('-- single-request correctness ($rounds rounds) --');
  print('decide: $decided/$rounds parsed, $actionLegal legal action, '
      'p50=${_p50(decideLat)}ms p95=${_p95(decideLat)}ms');
  print('convo : $convoOk/$rounds valid turn, '
      'p50=${_p50(convoLat)}ms p95=${_p95(convoLat)}ms\n');

  // --- throughput scaling: N parallel decisions ---
  for (final n in parallels) {
    final t = DateTime.now();
    final results = await Future.wait(List.generate(n, (_) {
      return llm.decide(prompts.decisionPrompt(
        _ana,
        simClock: 'noche 2, hora 1', place: 'plaza',
        nearbyEntities: 'Bor Solorio', memories: const ['walk'],
        allowedActions: legal));
    }));
    final ms = DateTime.now().difference(t).inMilliseconds;
    final ok = results.where((r) => r != null && _actions.contains(r.action)).length;
    print('-- parallel=$n: ${ms}ms wall, $ok/$n legal '
        '(${n > 1 ? (ms / n).toStringAsFixed(0) : ms}ms effective/req) --');
  }

  print('\nverdict: ${decideOk >= rounds * 0.8 && convoOk >= rounds * 0.8
      ? 'PASS — model viable' : 'WEAK — consider fallback'}');
}

int _p50(List<int> l) => (l..sort())[l.length ~/ 2];
int _p95(List<int> l) => (l..sort())[(l.length * 0.95).floor().clamp(0, l.length - 1)];
String? _arg(List<String> a, String k) {
  final i = a.indexOf('--$k');
  return (i >= 0 && i + 1 < a.length) ? a[i + 1] : null;
}
