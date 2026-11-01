/// sqlite persistence — memories, knowledge, event log, agent state, world kv.
/// Pure Dart (sqflite). Every domain write is an idempotent events row.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import 'models.dart';

class SimStore {
  final Database db;
  int _eventSeq = 0;
  final Random _rng = Random();

  SimStore._(this.db);

  /// The live store per path — a fresh `open` retires its predecessor so
  /// the old world's stragglers stop issuing sqlite calls against a file
  /// that's about to be deleted underneath them.
  static final Map<String, SimStore> _live = {};

  static Future<SimStore> open({String path = 'pueblo_sim.db', bool fresh = false}) async {
    if (fresh) {
      _live.remove(path)?.dispose();
      await deleteDatabase(path);
    }
    // singleInstance: false — the default cache hands back the SAME
    // Database object for a repeat open on this path, which after a
    // deleteDatabase is the old dead handle. A world reset would boot a
    // store that can never write.
    final db = await openDatabase(path,
        version: 1, singleInstance: false, onCreate: (d, v) async {
      await d.execute('''CREATE TABLE memories(
        id INTEGER PRIMARY KEY, agent TEXT, sim_ts INTEGER,
        kind TEXT, source TEXT, text TEXT, importance INTEGER, entities TEXT)''');
      await d.execute('''CREATE TABLE knowledge(agent TEXT, secret TEXT,
        learned_via TEXT, sim_ts INTEGER, event_id TEXT UNIQUE,
        PRIMARY KEY(agent, secret))''');
      await d.execute('''CREATE TABLE events(id TEXT PRIMARY KEY, sim_ts INTEGER,
        kind TEXT, payload TEXT)''');
      await d.execute('''CREATE TABLE agents(id TEXT PRIMARY KEY, stats TEXT,
        battery REAL, x REAL, y REAL, state_version INTEGER)''');
      await d.execute('''CREATE TABLE world(key TEXT PRIMARY KEY, value TEXT)''');
      await d.execute('''CREATE TABLE sim_log(id INTEGER PRIMARY KEY, sim_ts INTEGER,
        agent TEXT, kind TEXT, payload TEXT)''');
    });
    // A second app instance holding the file must not instantly error reads —
    // waiting a few seconds beats a wedged send button or a dead spirit chat.
    // (rawQuery, not execute: PRAGMA returns a row, which execute rejects.)
    await db.rawQuery('PRAGMA busy_timeout = 5000');
    return _live[path] = SimStore._(db);
  }

  /// Closed by a world reset or app teardown — `deleteDatabase` on a fresh
  /// open closes this handle under us (and `db.isOpen` still reports true,
  /// so the only reliable signal is catching the exception once).
  bool _dead = false;
  bool get _closed => _dead || !db.isOpen;

  /// True once the underlying handle has been killed (world reset, fresh
  /// reopen, app teardown) — the engine checks this to stop queueing work.
  bool get isDead => _closed;

  /// Mark dead without waiting for the first failing op — called when the
  /// owner is torn down so nothing new is issued against a doomed handle.
  /// Also releases the native handle so a later open on this path can't
  /// inherit it from sqflite's cache.
  void dispose() {
    _dead = true;
    unawaited(db.close().catchError((_) {}));
  }

  /// Guard every db call: the first `database_closed` error marks the
  /// handle dead and all later ops no-op quietly — the old engine's
  /// in-flight futures shouldn't spam the console on a world reset or a
  /// second app instance racing the same file.
  Future<T?> _g<T>(Future<T> Function() op) async {
    if (_closed) return null;
    try {
      return await op();
    } on DatabaseException catch (e) {
      if (e.isDatabaseClosedError() ||
          e.toString().contains('database_closed')) {
        // The known teardown case — old world writing into a deleted
        // file. Mark dead, stay quiet.
        _dead = true;
        return null;
      }
      rethrow;
    }
  }

  String _eid() => 'e${DateTime.now().microsecondsSinceEpoch}_${_eventSeq++}_${_rng.nextInt(999)}';

  /// Append a domain event; returns its id. Idempotent apply = callers write
  /// effects with INSERT OR IGNORE keyed on this id where applicable.
  Future<String> logEvent(int simTs, String kind, Map<String, dynamic> payload) async {
    final id = _eid();
    await _g(() => db.insert('events',
        {'id': id, 'sim_ts': simTs, 'kind': kind, 'payload': jsonEncode(payload)}));
    return id;
  }

  Future<void> memory(Memory m) async {
    await _g(() => db.insert('memories', {
      'agent': m.agent,
      'sim_ts': m.simTs,
      'kind': m.kind,
      'source': m.source,
      'text': m.text,
      'importance': m.importance,
      'entities': jsonEncode(m.entities),
    }));
  }

  /// Atomic knowledge transfer — the utterance IS the proof. Caller passes the
  /// utterance's event id so replay is a no-op.
  Future<bool> transferKnowledge(String agent, String secret, String learnedVia,
      int simTs, String eventId) async {
    final n = await _g(() => db.insert(
        'knowledge',
        {
          'agent': agent,
          'secret': secret,
          'learned_via': learnedVia,
          'sim_ts': simTs,
          'event_id': 'k_$eventId',
        },
        conflictAlgorithm: ConflictAlgorithm.ignore));
    return (n ?? 0) > 0;
  }

  /// Atomic purchase: petals -= price, item → inventory (world kv), optional
  /// secret → knowledge, in ONE transaction. [balance] is the caller's live
  /// petal count — the world kv is a mirror written here, never the source.
  Future<bool> purchase(String agent, String itemId, int price, int simTs,
      {required int balance, String? secretId, String? secretFrom}) async {
    final ok = await _g(() => db.transaction((txn) async {
      if (balance < price) return false;
      final eid = _eid();
      await txn.insert('events',
          {'id': eid, 'sim_ts': simTs, 'kind': 'purchase', 'payload': jsonEncode({
            'agent': agent, 'item': itemId, 'price': price,
          })});
      await txn.insert('world', {'key': 'petals', 'value': '${balance - price}'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('world', {'key': 'inv_$itemId', 'value': '1'},
          conflictAlgorithm: ConflictAlgorithm.replace);
      if (secretId != null) {
        await txn.insert(
            'knowledge',
            {
              'agent': agent,
              'secret': secretId,
              'learned_via': secretFrom ?? 'purchase',
              'sim_ts': simTs,
              'event_id': 'k_$eid',
            },
            conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      return true;
    }));
    return ok ?? false;
  }

  Future<void> simLog(int simTs, String agent, String kind, String payload) async {
    await _g(() => db.insert('sim_log',
        {'sim_ts': simTs, 'agent': agent, 'kind': kind, 'payload': payload}));
  }

  /// Tail of the sim log — the audit trail: decides, learns, errands,
  /// rumors, replies, directives. Newest first.
  Future<List<Map<String, Object?>>> tailLog(int n) async =>
      (await _g(() => db.query('sim_log', orderBy: 'id DESC', limit: n))) ??
      const [];

  Future<void> saveAgent(Agent a) async {
    await _g(() => db.insert(
        'agents',
        {
          'id': a.id,
          'stats': jsonEncode({
            'curiosity': a.stats.curiosity, 'wit': a.stats.wit,
            'warmth': a.stats.warmth, 'spirit_sight': a.stats.spiritSight,
            'mischief': a.stats.mischief, 'grump': a.stats.grump,
          }),
          'battery': a.battery,
          'x': a.x,
          'y': a.y,
          'state_version': a.stateVersion,
        },
        conflictAlgorithm: ConflictAlgorithm.replace));
  }

  Future<void> setWorld(String key, String value) async {
    await _g(() => db.insert('world', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace));
  }

  Future<String?> getWorld(String key) async {
    final r = await _g(() =>
        db.query('world', where: 'key = ?', whereArgs: [key]));
    if (r == null || r.isEmpty) return null;
    return r.first['value'] as String;
  }

  /// The agent's secrets freshest-first — the "new info" the 💡 cue
  /// points at when the player comes asking.
  Future<List<String>> recentSecrets(String agent) async {
    final r = await _g(() => db.query('knowledge',
        columns: ['secret'],
        where: 'agent = ?',
        whereArgs: [agent],
        orderBy: 'sim_ts DESC'));
    return [for (final row in r ?? const []) row['secret'] as String];
  }

  /// The agent's newest reflection — surfaced in prompts as its own line
  /// so the synthesis doesn't lose the recall race to fresh observations.
  Future<String?> latestReflection(String agent) async {
    final r = await _g(() => db.query('memories',
        columns: ['text'],
        where: 'agent = ? AND kind = ?',
        whereArgs: [agent, 'reflection'],
        orderBy: 'sim_ts DESC',
        limit: 1));
    if (r == null || r.isEmpty) return null;
    return r.first['text'] as String;
  }

  Future<List<Memory>> recall(Agent a, int nowTs, {int limit = 5,
      Set<String> contextEntities = const {}}) async {
    final rows = await _g(() => db.query('memories',
        where: 'agent = ?', whereArgs: [a.id], orderBy: 'sim_ts DESC', limit: 60));
    if (rows == null) return const [];
    final tau = 600.0; // sim-seconds decay constant
    final scored = <({double s, Memory m})>[];
    for (final r in rows) {
      final ents = List<String>.from(jsonDecode(r['entities'] as String));
      final shared = ents.where(contextEntities.contains).length;
      final imp = (r['importance'] as int).toDouble();
      final age = (nowTs - (r['sim_ts'] as int)).clamp(0, 1 << 30).toDouble();
      final s = 0.5 * imp + 0.3 * 10 * exp(-age / tau) + 0.2 * 10 * shared;
      scored.add((s: s, m: Memory(
        agent: a.id, simTs: r['sim_ts'] as int, kind: r['kind'] as String,
        source: r['source'] as String, text: r['text'] as String,
        importance: r['importance'] as int, entities: ents)));
    }
    scored.sort((x, y) => y.s.compareTo(x.s));
    return scored.take(limit).map((e) => e.m).toList();
  }

  Future<({int count, int importanceSum})> memoryStats(String agent) async {
    final r = await _g(() => db.rawQuery(
        'SELECT COUNT(*) c, COALESCE(SUM(importance),0) s FROM memories WHERE agent = ?',
        [agent]));
    if (r == null) return (count: 0, importanceSum: 0);
    return (count: r.first['c'] as int, importanceSum: (r.first['s'] as num).toInt());
  }

  /// Archive oldest `n` memories into `archive`, return their texts.
  Future<List<String>> archiveOldest(String agent, int n) async {
    final rows = await _g(() => db.query('memories',
        where: 'agent = ?', whereArgs: [agent],
        orderBy: 'sim_ts ASC', limit: n));
    if (rows == null || rows.isEmpty) return const [];
    final texts = rows.map((r) => r['text'] as String).toList();
    final ids = rows.map((r) => r['id'] as int).toList();
    await _g(() => db.delete('memories',
        where: 'id IN (${List.filled(ids.length, '?').join(',')})',
        whereArgs: ids));
    return texts;
  }
}
