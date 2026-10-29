/// GemmaLocalClient — the on-device LLMClient for the Pixel build.
/// Gemma 3n E2B-it (.task) via flutter_gemma / LiteRT.
///
/// Generation is SERIALIZED on-device (MediaPipe has no parallel sessions) —
/// a turn chain is kept here as a second line of defense, though the sim's
/// InferenceBroker already feeds us one job at a time. One session per call;
/// durable agent memory lives in sqlite, not native session state.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter_gemma/flutter_gemma.dart';

import 'llm.dart';

class GemmaLocalClient implements LLMClient {
  InferenceModel? _model;
  Future<InferenceModel>? _init;
  final Random rng;

  /// Every inference takes a turn on this chain — a second addQueryChunk
  /// mid-prediction crashes natively (week3: PredictDone RET_CHECK).
  Future<void> _turn = Future.value();

  GemmaLocalClient({Random? rng}) : rng = rng ?? Random(7);

  @override
  String get name => 'gemma3n:e2b-local';

  Future<InferenceModel> _ensure() {
    return _init ??= () async {
      _model = await FlutterGemma.getActiveModel(
        preferredBackend: PreferredBackend.gpu,
        maxTokens: 512,
      );
      return _model!;
    }();
  }

  Future<T> _serialized<T>(Future<T> Function() job) {
    final prev = _turn;
    final c = Completer<void>();
    _turn = c.future;
    return prev.then((_) => job()).whenComplete(c.complete);
  }

  /// One shot: fresh session → query → response → close.
  Future<String?> _chat(String prompt,
      {double temperature = 0.8, int maxTokens = 160}) {
    return _serialized(() async {
      InferenceModelSession? session;
      try {
        final model = await _ensure();
        session = await model.createSession(
          temperature: temperature,
          topK: 40,
          topP: 0.95,
          // Gemma 3n has no grammar-constrained decoding, so the prompt's
          // JSON-only instruction does the work; we parse tolerantly below.
          systemInstruction:
              'Reply with ONLY a single JSON object. No prose, no markdown.',
        );
        await session.addQueryChunk(
            Message.text(text: prompt, isUser: true));
        return await session.getResponse();
      } catch (_) {
        return null;
      } finally {
        try {
          await session?.close();
        } catch (_) {}
      }
    });
  }

  static Map<String, dynamic>? _json(String? raw) {
    if (raw == null) return null;
    var s = raw.trim();
    final a = s.indexOf('{'), b = s.lastIndexOf('}');
    if (a < 0 || b <= a) return null;
    try {
      final j = jsonDecode(s.substring(a, b + 1));
      return j is Map<String, dynamic> ? j : null;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<Decision?> decide(String prompt) async {
    final j = _json(await _chat(prompt, temperature: 0.7));
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
    final j = _json(await _chat(prompt, temperature: 0.85));
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
    // Raw JSON/text — the engine parses PlayerReply itself.
    final content = await _chat(prompt, temperature: 0.85);
    final line = content ?? '...';
    for (var i = 0; i < line.length; i += 12) {
      yield line.substring(i, min(i + 12, line.length));
      await Future.delayed(const Duration(milliseconds: 25));
    }
  }

  @override
  Future<String?> reflect(String prompt) async {
    final j = _json(await _chat(prompt, temperature: 0.5, maxTokens: 120));
    return j?['summary']?.toString() ?? j?['line']?.toString();
  }

  @override
  Future<Map<String, dynamic>?> direct(String prompt) async =>
      _json(await _chat(prompt, temperature: 0.6, maxTokens: 100));
}
