/// InferenceBroker — priority queue over the single (or N) inference worker(s).
/// Every job carries {agentId, convoId, stateVersion}; results are validated
/// against CURRENT state before commit — stale results drop silently.
library;

import 'dart:async';

import 'llm.dart';

enum JobKind { player, convoTurn, decision, reflection, director }

int _prio(JobKind k) => switch (k) {
      JobKind.player => 0,
      JobKind.convoTurn => 1,
      JobKind.decision => 2,
      JobKind.reflection => 3,
      JobKind.director => 4, // storyteller waits for everyone else
    };

class Job {
  final JobKind kind;
  final String agentId;
  final String? convoId;
  final int stateVersion; // agent version at enqueue
  final String prompt;
  final int enqSeq;
  Job(this.kind, this.agentId, this.prompt, this.stateVersion,
      {this.convoId, required this.enqSeq});
}

class InferenceBroker {
  final LLMClient llm;
  final int workers;
  final PriorityQueue<Job> _q = PriorityQueue<Job>(
      (a, b) => _prio(a.kind) != _prio(b.kind)
          ? _prio(a.kind) - _prio(b.kind)
          : a.enqSeq - b.enqSeq);
  int _seq = 0;
  int _busy = 0;

  // Results routed back to the engine via these streams.
  final _decisions = StreamController<(Job, Decision?)>.broadcast();
  final _turns = StreamController<(Job, ConvoTurn?)>.broadcast();
  final _reflections = StreamController<(Job, String?)>.broadcast();
  final _beats = StreamController<Map<String, dynamic>?>.broadcast();

  Stream<(Job, Decision?)> get decisions => _decisions.stream;
  Stream<(Job, ConvoTurn?)> get turns => _turns.stream;
  Stream<(Job, String?)> get reflections => _reflections.stream;
  Stream<Map<String, dynamic>?> get beats => _beats.stream;

  int get queueLength => _q.length;

  InferenceBroker(this.llm, {this.workers = 1});

  /// Player chat bypasses the queue entirely — the engine calls
  /// llm.playerChat directly so the living one's reply never waits behind
  /// sim work. JobKind.player exists only as the lowest-effort priority tag.
  void push(JobKind kind, String agentId, String prompt, int stateVersion,
      {String? convoId}) {
    _q.add(Job(kind, agentId, prompt, stateVersion, convoId: convoId, enqSeq: _seq++));
    _pump();
  }

  void _pump() {
    while (_busy < workers && _q.isNotEmpty) {
      final job = _q.removeFirst();
      _busy++;
      unawaited(_run(job));
    }
  }

  Future<void> _run(Job job) async {
    try {
      switch (job.kind) {
        case JobKind.decision:
          _decisions.add((job, await llm.decide(job.prompt)));
        case JobKind.convoTurn:
          _turns.add((job, await llm.convoTurn(job.prompt)));
        case JobKind.reflection:
          _reflections.add((job, await llm.reflect(job.prompt)));
        case JobKind.director:
          _beats.add(await llm.direct(job.prompt));
        case JobKind.player:
          break; // player chat goes through llm.playerChat directly
      }
    } finally {
      _busy--;
      _pump();
    }
  }
}

/// Minimal priority queue on a sorted list — small N, no heap needed.
class PriorityQueue<T> {
  final List<T> _items = [];
  final int Function(T, T) _cmp;
  PriorityQueue(this._cmp);
  bool get isEmpty => _items.isEmpty;
  bool get isNotEmpty => _items.isNotEmpty;
  int get length => _items.length;
  void add(T item) {
    var i = _items.length;
    while (i > 0 && _cmp(_items[i - 1], item) > 0) {
      i--;
    }
    _items.insert(i, item);
  }

  T removeFirst() => _items.removeAt(0);
}
