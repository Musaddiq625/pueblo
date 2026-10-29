/// LLM client abstraction + Ollama impl + deterministic mock.
/// Pure Dart — usable from the app and the headless eval harness (bin/eval.dart).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:http/http.dart' as http;

/// One validated decision from the model.
class Decision {
  final String? thought;
  final String action;
  final String? target;
  final String? subject;
  final String line;
  final String mood;
  const Decision(this.action, this.target, this.line,
      {this.thought, this.subject, this.mood = 'neutral'});
}

/// One generated turn inside an NPC↔NPC conversation (single speaker).
class ConvoTurn {
  final String line;
  final String? sharesSecret;
  final bool end;
  final String mood;
  const ConvoTurn(this.line, {this.sharesSecret, this.end = false, this.mood = 'neutral'});
}

/// The spirit's answer to a player message — richer than a line of text.
/// The model decides whether it SPEAKS ([say]) or just REACTS ([react]),
/// whether it believes a claim enough to carry it onward ([believes]),
/// who it means to tell ([shareWith]), and — for the mischievous — how it
/// will retell it ([twist]). Engine validates every field; a plain-text
/// response parses as [say] so simple/mock clients keep working.
class PlayerReply {
  final String? say; // spoken line; null = the spirit just takes it in
  final String react; // shock|curious|warm|wary|amused|none
  final bool? believes; // takes the claim as true (null = unstated)
  final String? shareWith; // agent id they mean to tell
  final String? twist; // their embellished version of the claim

  const PlayerReply({
    this.say,
    this.react = 'none',
    this.believes,
    this.shareWith,
    this.twist,
  });

  static String? _str(Map<String, dynamic> j, String k) {
    final v = j[k];
    if (v == null) return null;
    final s = v.toString().trim();
    return s.isEmpty || s == 'null' ? null : s;
  }

  static PlayerReply parse(String raw) {
    final t = raw.trim();
    final a = t.indexOf('{'), b = t.lastIndexOf('}');
    if (a >= 0 && b > a) {
      try {
        final j = jsonDecode(t.substring(a, b + 1));
        if (j is Map<String, dynamic>) {
          final believe = j['believes'];
          return PlayerReply(
            say: _str(j, 'say') ?? _str(j, 'line') ?? _str(j, 'reply'),
            react: _str(j, 'react') ?? _str(j, 'mood') ?? 'none',
            believes: believe is bool ? believe : null,
            shareWith: _str(j, 'share_with') ?? _str(j, 'shareWith'),
            twist: _str(j, 'twist'),
          );
        }
      } catch (_) {/* fall through — treat the whole thing as a line */}
    }
    return PlayerReply(say: t.isEmpty ? null : t);
  }
}

abstract class LLMClient {
  String get name;
  Future<Decision?> decide(String prompt);
  Future<ConvoTurn?> convoTurn(String prompt);
  Stream<String> playerChat(String prompt);
  Future<String?> reflect(String prompt);

  /// The storyteller — a town-state digest in, one validated beat JSON out
  /// (or null). Engine owns all application.
  Future<Map<String, dynamic>?> direct(String prompt);
}

// ---------------------------------------------------------------------------

class OllamaClient implements LLMClient {
  final String model;
  final Uri base;
  final http.Client _http = http.Client();
  final Random rng;

  OllamaClient({this.model = 'qwen3:4b-instruct-2507-q4_K_M', Uri? base, Random? rng})
      : base = base ?? Uri.parse('http://localhost:11434'),
        rng = rng ?? Random(42);

  @override
  String get name => 'ollama:$model';

  Future<String?> _chat(String prompt,
      {double temperature = 0.7,
      int numCtx = 2048,
      int numPredict = 160,
      bool think = false,
      Duration timeout = const Duration(seconds: 60)}) async {
    try {
      final res = await _http
          .post(
            base.resolve('/api/chat'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'user', 'content': prompt}
              ],
              'stream': false,
              'format': 'json',
              'think': think,
              'keep_alive': '30m',
              'options': {
                'temperature': temperature,
                'num_ctx': numCtx,
                'num_predict': numPredict,
              },
            }),
          )
          .timeout(timeout);
      if (res.statusCode != 200) return null;
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final content = (j['message']?['content'] ?? j['response']) as String?;
      if (content == null || content.trim().isEmpty) return null;
      return content;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _json(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    final a = s.indexOf('{'), b = s.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    s = s.substring(a, b + 1);
    try {
      final j = jsonDecode(s);
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Decision?> decide(String prompt) async {
    final j = _json(await _chat(prompt, temperature: 0.7, numPredict: 140));
    if (j == null) return null;
    return Decision(
      (j['action'] ?? '').toString(),
      j['target']?.toString(),
      (j['line'] ?? '').toString(),
      thought: j['thought']?.toString(),
      subject: j['subject']?.toString(),
      mood: (j['mood'] ?? 'neutral').toString(),
    );
  }

  @override
  Future<ConvoTurn?> convoTurn(String prompt) async {
    final j = _json(await _chat(prompt, temperature: 0.85, numPredict: 90));
    if (j == null) return null;
    return ConvoTurn(
      (j['line'] ?? '').toString(),
      sharesSecret: j['shares_secret']?.toString(),
      end: j['end'] == true,
      mood: (j['mood'] ?? 'neutral').toString(),
    );
  }

  @override
  Stream<String> playerChat(String prompt) async* {
    // Non-streaming for simplicity; chunked yield keeps the same API.
    // Returns the raw JSON/text — the engine parses PlayerReply itself.
    final content = await _chat(prompt, temperature: 0.85, numPredict: 220);
    final line = content ?? '...';
    for (var i = 0; i < line.length; i += 12) {
      yield line.substring(i, min(i + 12, line.length));
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  Future<String?> reflect(String prompt) async {
    final j = _json(await _chat(prompt, temperature: 0.5, numPredict: 200));
    return j?['summary']?.toString() ?? j?['line']?.toString();
  }

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async =>
      _json(await _chat(prompt, temperature: 0.6, numPredict: 120));
}

// ---------------------------------------------------------------------------

/// Deterministic canned client — town stays alive without a model; also the
/// test double. Replies are persona-aware via small token substitutions.
class MockLLMClient implements LLMClient {
  final Random rng;
  MockLLMClient({int seed = 7}) : rng = Random(seed);

  @override
  String get name => 'mock';

  static const _idleLines = [
    'the candles keep me company.',
    'another night, another walk.',
    'the marigolds smell like home.',
    'quiet tonight, compadre.',
    'someone left pan de muerto at the ofrenda.',
    'the fountain remembers every coin, you know.',
    'i keep meaning to visit the old ceiba.',
  ];

  @override
  Future<Decision?> decide(String prompt) async {
    // Cheap intent inference from the offered action list in the prompt.
    final r = rng.nextDouble();
    // Purpose first — the point of the sim is knowledge moving.
    if (prompt.contains('share(') && r < 0.5) {
      final m = RegExp(r'share\((\w+),(\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('share', m.group(1), _pick(_idleLines),
            subject: m.group(2), thought: 'they haven\'t heard', mood: 'warm');
      }
    }
    if (prompt.contains('converse') && r < 0.45) {
      final m = RegExp(r'converse\((\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('converse', m.group(1), _pick(_idleLines),
            thought: 'someone to talk to', mood: 'warm');
      }
    }
    if (prompt.contains('inspect') && r < 0.25) {
      final m = RegExp(r'inspect\((\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('inspect', m.group(1), 'something feels off here…',
            thought: 'that thing looks odd', mood: 'curious');
      }
    }
    return Decision('stroll', null, _pick(_idleLines), thought: 'wander', mood: 'neutral');
  }

  @override
  Future<ConvoTurn?> convoTurn(String prompt) async {
    // If the prompt offers a shareable secret id, sometimes take it.
    final m = RegExp(r'Secrets you know: \[(\w+):').firstMatch(prompt);
    final share = (m != null && rng.nextDouble() < 0.4) ? m.group(1) : null;
    final end = rng.nextDouble() < 0.3;
    return ConvoTurn(
      _pick(const [
        'you heard anything new tonight?',
        'the dead talk slower than the living think.',
        'i saw the strangest thing near the fountain.',
        'keep your candle lit, friend.',
        'the market was busier when i was alive.',
        'someone on grave lane hums an old song.',
      ]),
      sharesSecret: share,
      end: end,
      mood: 'warm',
    );
  }

  @override
  Stream<String> playerChat(String prompt) async* {
    yield _pick(const [
      'the living ask such urgent questions.',
      'you smell of sunlight, mijo.',
      'ask the gravedigger — he keeps every story.',
      'i remember more than the town thinks.',
    ]);
  }

  @override
  Future<String?> reflect(String prompt) async =>
      'the town keeps turning; i keep watching.';

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async {
    // Alternate a gentle rumor with silence — the night breathes.
    if (rng.nextDouble() < 0.4) {
      final m = RegExp('@([a-z_0-9]+)').allMatches(prompt);
      final poi = m.isEmpty ? 'fountain' : m.first.group(1);
      return {
        'beat': 'rumor',
        'agent': null,
        'poi': poi,
        'line': 'the water remembers what the night forgets',
        'why': 'a whisper for the listeners',
      };
    }
    return {'beat': 'none'};
  }

  String _pick(List<String> l) => l[rng.nextInt(l.length)];
}
