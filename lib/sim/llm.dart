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
    // Small models emit "Null", "None", "N/A" for absent fields — a
    // case-sensitive 'null' check lets the literal word reach the screen.
    final low = s.toLowerCase();
    return s.isEmpty ||
            low == 'null' ||
            low == 'none' ||
            low == 'nil' ||
            low == 'n/a' ||
            low == '-'
        ? null
        : s;
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
    final low = t.toLowerCase();
    return PlayerReply(
        say: t.isEmpty || low == 'null' || low == 'none' ? null : t);
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

  /// Is the server reachable? Lightweight ping used by the HUD's
  /// offline badge — better to show "offline" than have every spirit
  /// answer with silence for no visible reason.
  Future<bool> probe() async {
    try {
      final res = await _http
          .get(base.resolve('/api/tags'))
          .timeout(const Duration(seconds: 3));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

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
    final j = _json(await _chat(prompt, temperature: 0.45, numPredict: 140));
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
    // Cooler than the old 0.85 — small models at high temperature go
    // poetic; the village needs plain speech, not verse.
    final j = _json(await _chat(prompt, temperature: 0.5, numPredict: 90));
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
    // Empty on failure → the spirit silently listens rather than literally
    // saying '...' at the player.
    final content = await _chat(prompt, temperature: 0.55, numPredict: 220);
    final line = content ?? '';
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

/// Tries the real model first; while the server is unreachable every call
/// silently falls back to the mock so the town never goes dead. Re-probes at
/// most every 8s — when Ollama comes back the real model resumes on its own.
/// The game must always open playable.
class FailoverLLMClient implements LLMClient {
  final OllamaClient primary;
  final LLMClient fallback;
  bool _alive = false;
  DateTime _probedAt = DateTime.fromMillisecondsSinceEpoch(0);
  Future<bool>? _probing;

  FailoverLLMClient({required this.primary, required this.fallback});

  @override
  String get name => _alive ? primary.name : '${primary.name}→mock';

  /// Engine's health probe — reports what the failover is actually serving.
  Future<bool> probe() => _available();

  Future<bool> _available() async {
    if (DateTime.now().difference(_probedAt).inSeconds < 8) return _alive;
    _probing ??= primary.probe().whenComplete(() => _probing = null);
    _alive = await _probing!;
    _probedAt = DateTime.now();
    return _alive;
  }

  Future<LLMClient> _pick() async => (await _available()) ? primary : fallback;

  @override
  Future<Decision?> decide(String prompt) async => (await _pick()).decide(prompt);

  @override
  Future<ConvoTurn?> convoTurn(String prompt) async =>
      (await _pick()).convoTurn(prompt);

  @override
  Stream<String> playerChat(String prompt) async* {
    yield* (await _pick()).playerChat(prompt);
  }

  @override
  Future<String?> reflect(String prompt) async =>
      (await _pick()).reflect(prompt);

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async =>
      (await _pick()).direct(prompt);
}

// ---------------------------------------------------------------------------

/// Deterministic canned client — town stays alive without a model; also the
/// test double. Replies are persona-aware via small token substitutions.
class MockLLMClient implements LLMClient {
  final Random rng;
  MockLLMClient({int seed = 7}) : rng = Random(seed);

  @override
  String get name => 'mock';

  /// Persona-keyed line pools — every spirit wonders about the case in
  /// their own voice, so no two mouths carry the same sentence. Keyed by
  /// the name the prompt opens with ("You are NAME.").
  static const _voiceLines = {
    'Tía Luz': [
      'someone took her picture — who would do that?',
      'i keep thinking about that flash of silver i saw.',
      'the ofrenda looks wrong with her frame bare.',
      'tell me if you hear who touched the altar.',
    ],
    'Bruno el Sepulturero': [
      'i was digging a grave — ask Carmen, she knows.',
      'a sack? i carry tools, not pictures.',
      'everyone stares at me like i did it.',
      'the dead are honest. it is the living who lie.',
    ],
    'Doña Sefa': [
      'wax on a sleeve does not lie, my friend.',
      'half the town blames the other half today.',
      'her portrait was gold — someone envied that light.',
      'who profits from a stolen picture? answer me that.',
    ],
    'Ramón el Trovador': [
      'Bruno carried a sack past the altar — i saw it.',
      'Carmen collects photos for her nameless graves.',
      'sad about the portrait. La Golondrina deserved better.',
      'i? i was tuning my guitar all evening.',
    ],
    'Abuela Inés': [
      'La Golondrina sang for us fifty years, and this?',
      'her candle still burns though her picture is gone.',
      'a name remembered lives; a picture stolen wounds.',
      'i knew her voice when it was young. ask me.',
    ],
    'Solorio': [
      'i saw someone at the frames at dusk… or did i dream it?',
      'the edges of me keep drifting away today.',
      'say my name — it helps me remember who i was.',
      'there was humming near the ofrenda. i think.',
    ],
    'Violeta': [
      'someone was humming her tune by the big frames.',
      'i keep the marigolds fresh — the altar feels wrong.',
      'a missing portrait… it scares me a little.',
      'who steals from the dead? that is what i ask.',
    ],
    'Padre Aurelio': [
      'i was saying mass — many souls can vouch for me.',
      'theft from an ofrenda is a wound on the whole town.',
      'pray with me that her picture finds its way home.',
      'the culprit carries a heavy conscience tonight.',
    ],
    'La Viuda Carmen': [
      'i collect photos only for graves that have none.',
      'someone says it was me? let them say it to my face.',
      'her frame is bare — i noticed it first thing.',
      'we owe the dead their faces. someone broke that debt.',
    ],
  };

  static const _genericLines = [
    'the ofrenda is missing a portrait — did you hear?',
    'everyone keeps asking who touched the altar.',
    'a picture does not walk off by itself.',
    'someone in this village is lying about that frame.',
  ];

  /// Inner-voice lines for `thought` — tied to the case, never "wander".
  static const _thoughtLines = [
    'who took her picture?',
    'the altar looked wrong',
    'someone is lying',
    'i should ask around',
    'keep your eyes open',
    'the frame was bare',
  ];

  static String _speakerName(String prompt) {
    final m = RegExp(r'You are ([^\.\n]+)\.').firstMatch(prompt);
    return m?.group(1)?.trim() ?? '';
  }

  String _voiceFor(String prompt) =>
      _pick(_voiceLines[_speakerName(prompt)] ?? _genericLines);

  @override
  Future<Decision?> decide(String prompt) async {
    // Cheap intent inference from the offered action list in the prompt.
    final r = rng.nextDouble();
    // Purpose first — the point of the sim is knowledge moving.
    if (prompt.contains('share(') && r < 0.5) {
      final m = RegExp(r'share\((\w+),(\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('share', m.group(1), _voiceFor(prompt),
            subject: m.group(2), thought: 'they haven\'t heard', mood: 'warm');
      }
    }
    if (prompt.contains('converse') && r < 0.45) {
      final m = RegExp(r'converse\((\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('converse', m.group(1), _voiceFor(prompt),
            thought: _pick(_thoughtLines), mood: 'warm');
      }
    }
    if (prompt.contains('inspect') && r < 0.25) {
      final m = RegExp(r'inspect\((\w+)\)').firstMatch(prompt);
      if (m != null) {
        return Decision('inspect', m.group(1), 'something feels off here…',
            thought: 'that thing looks odd', mood: 'curious');
      }
    }
    return Decision('stroll', null, _voiceFor(prompt),
        thought: _pick(_thoughtLines), mood: 'neutral');
  }

  @override
  Future<ConvoTurn?> convoTurn(String prompt) async {
    // If the prompt offers a shareable secret id, sometimes take it.
    final m = RegExp(r'Secrets you know: \[(\w+):').firstMatch(prompt);
    final share = (m != null && rng.nextDouble() < 0.4) ? m.group(1) : null;
    final end = rng.nextDouble() < 0.3;
    return ConvoTurn(
      _voiceFor(prompt),
      sharesSecret: share,
      end: end,
      mood: 'warm',
    );
  }

  @override
  Stream<String> playerChat(String prompt) async* {
    // The mock reads the last "the living one:" line and acknowledges its
    // content — naming spirits/places it mentions — so the offline path
    // answers like the real model instead of reciting a fixed list.
    final lastMsg = RegExp(r'the living one: (.+)')
        .allMatches(prompt)
        .map((m) => m.group(1)!.trim())
        .lastOrNull;
    final heard = _mockAnswer(lastMsg);
    // Emit PlayerReply JSON ~60% of the time so the offline claim loop
    // exercises the same parse/validate path as the real model — believes,
    // share_with, and the occasional mischievous twist all get exercised.
    if (rng.nextDouble() < 0.6) {
      final souls = RegExp(r'\((\w+) —')
          .allMatches(prompt)
          .map((m) => m.group(1)!)
          .toList();
      souls.shuffle(rng);
      yield jsonEncode({
        'say': heard,
        'react': _pick(const ['warm', 'curious', 'amused', 'wary']),
        'believes': rng.nextBool(),
        'share_with': souls.isEmpty ? null : souls.first,
        'twist': rng.nextDouble() < 0.25
            ? _pick(const [
                'the living one swears the candles spoke',
                'they say the ofrenda wept marigolds',
              ])
            : null,
      });
      return;
    }
    yield heard;
  }

  /// A reply that references what was actually said — the offline path
  /// should answer, not recite.
  String _mockAnswer(String? msg) {
    if (msg == null || msg.isEmpty) {
      return _pick(const [
        'the living ask such urgent questions.',
        'you smell of sunlight, mijo.',
      ]);
    }
    final m = msg.toLowerCase();
    const souls = [
      'bruno', 'sefa', 'ramon', 'ines', 'solorio', 'violeta', 'aurelio',
      'carmen', 'luz', 'abuela', 'dona', 'padre', 'genero',
    ];
    for (final s in souls) {
      if (m.contains(s)) {
        return _pick([
          '$s keeps that under their hat — i can ask.',
          'you want $s to hear this? say so plainly.',
          'careful with $s\'s name, mijo — names carry weight here.',
        ]);
      }
    }
    const places = [
      'fountain', 'tree', 'grave', 'cantina', 'plaza', 'bridge', 'candle',
      'ofrenda', 'stall', 'cemetery',
    ];
    for (final p in places) {
      if (m.contains(p)) {
        return _pick([
          'the $p? i have seen things there, living one.',
          'word of the $p travels faster than feet here.',
          'ask about the $p and half the town leans in.',
        ]);
      }
    }
    if (m.contains('?') || m.startsWith('who') || m.startsWith('what')) {
      return _pick(const [
        'ask it plainly and the dead may answer.',
        'a question for a question — what do you offer?',
      ]);
    }
    final words = m.split(' ').where((w) => w.length > 3).take(3).join(' ');
    return words.isEmpty
        ? 'go on, living one — the dead listen well.'
        : '“$words” — say more, and i may believe it.';
  }

  @override
  Future<String?> reflect(String prompt) async =>
      'the town keeps turning; i keep watching.';

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async {
    // Alternate a gentle rumor with silence — the festival breathes.
    if (rng.nextDouble() < 0.4) {
      final m = RegExp('@([a-z_0-9]+)').allMatches(prompt);
      final poi = m.isEmpty ? 'fountain' : m.first.group(1);
      return {
        'beat': 'rumor',
        'agent': null,
        'poi': poi,
        'line': 'the water remembers what the day forgets',
        'why': 'a whisper for the listeners',
      };
    }
    return {'beat': 'none'};
  }

  String _pick(List<String> l) => l[rng.nextInt(l.length)];
}
