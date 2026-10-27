/// SimEngine — three layers (world clock / conversation manager / inference
/// broker) driving the town. Emits SimEvents the render layer consumes.
/// Pure Dart + sqflite; no Flame imports.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'broker.dart';
import 'llm.dart';
import 'models.dart';
import 'prompts.dart';
import 'store.dart';

// ---------------------------------------------------------------------------

enum SimEventType {
  move,      // {agent, path:[[x,y],...]} — render lerps along it
  say,       // {agent, line, mood} — bubble over head
  emote,     // {agent, glyph} — ? ! etc.
  state,     // {agent, faded, engaged, x, y}
  pairStart, // {a, b} — both locked into convo
  pairEnd,
  poiGlow,   // {poi, on}
  petalSpawn,
  dawn,
  endRun,
  log,
}

class SimEvent {
  final SimEventType type;
  final Map<String, dynamic> data;
  const SimEvent(this.type, this.data);
}

// ---------------------------------------------------------------------------

class Conversation {
  final String id;
  final String aId, bId;
  final List<String> transcript = []; // "name: line"
  String nextSpeaker;
  bool pendingJob = false;
  bool done = false;
  String? askedAbout; // subject when convo was initiated via askAbout

  Conversation(this.id, this.aId, this.bId, {this.askedAbout})
      : nextSpeaker = aId;
}

// ---------------------------------------------------------------------------

class SimEngine {
  final SimStore store;
  final LLMClient llm;
  final Map<String, Agent> agents;
  final Map<String, Secret> secrets;
  final Map<String, Poi> pois;
  final List<List<int>> waypoints; // adjacency: waypoint i -> neighbors
  final List<List<double>> waypointPos;
  final Random rng;
  final double timeScale; // 1.0 normal; demo mode higher
  final int dawnAt; // sim_ts of run end

  late final PromptBuilder prompts;
  late final InferenceBroker broker;
  final Map<String, Conversation> conversations = {};

  int simTs = 0;
  int playerPetals = 0;
  final Set<String> playerKnown = {};
  String? engagedId;
  final List<ChatMsg> playerHist = [];

  final _events = StreamController<SimEvent>.broadcast();
  Stream<SimEvent> get events => _events.stream;

  double _decisionTimer = 0;
  double _convoTimer = 0;
  double _batteryTimer = 0;
  double _autosaveTimer = 0;
  static const decisionEvery = 20.0; // sim seconds (base tick)
  static const convoEvery = 5.0; // bubble pacing
  static const batteryEvery = 10.0;
  static const autosaveEvery = 30.0;

  SimEngine({
    required this.store,
    required this.llm,
    required this.agents,
    required this.secrets,
    required this.pois,
    required this.waypoints,
    required this.waypointPos,
    Random? rng,
    this.timeScale = 1.0,
    this.dawnAt = 900, // 15 sim-minutes
  }) : rng = rng ?? Random() {
    prompts = PromptBuilder(secrets);
    broker = InferenceBroker(llm, workers: 1);
    broker.decisions.listen(_onDecision);
    broker.turns.listen(_onTurn);
    broker.reflections.listen(_onReflection);
  }

  // ============================ world clock ================================

  void tick(double dt) {
    simTs += (dt * timeScale).round().clamp(1, 999);
    _decisionTimer += dt * timeScale;
    _convoTimer += dt * timeScale;
    _batteryTimer += dt * timeScale;
    _autosaveTimer += dt * timeScale;

    if (_convoTimer >= convoEvery) {
      _convoTimer = 0;
      _advanceConversations();
    }
    if (_decisionTimer >= decisionEvery) {
      _decisionTimer = 0;
      _scheduleDecision();
    }
    if (_batteryTimer >= batteryEvery) {
      _batteryTimer = 0;
      _drainBatteries();
    }
    if (_autosaveTimer >= autosaveEvery) {
      _autosaveTimer = 0;
      _autosave();
    }
    if (simTs >= dawnAt) _endRun();
  }

  // ============================ conversations ==============================

  void startConversation(String aId, String bId, {String? askedAbout}) {
    final a = agents[aId], b = agents[bId];
    if (a == null || b == null) return;
    if (a.engaged || b.engaged || a.inConvo || b.inConvo || a.faded || b.faded) {
      return;
    }
    final convo = Conversation('c${simTs}_${aId}_$bId', aId, bId,
        askedAbout: askedAbout);
    conversations[convo.id] = convo;
    a.inConvo = b.inConvo = true;
    a.bumpVersion();
    b.bumpVersion();
    _events.add(SimEvent(SimEventType.pairStart, {'a': aId, 'b': bId}));
    _requestTurn(convo);
  }

  void _advanceConversations() {
    final finished = <Conversation>[];
    for (final c in conversations.values) {
      if (c.done) {
        finished.add(c);
        continue;
      }
      if (!c.pendingJob) _requestTurn(c);
    }
    for (final c in finished) {
      conversations.remove(c.id);
      final a = agents[c.aId]!, b = agents[c.bId]!;
      a.inConvo = b.inConvo = false;
      a.bumpVersion();
      b.bumpVersion();
      _events.add(SimEvent(SimEventType.pairEnd, {'a': c.aId, 'b': c.bId}));
    }
  }

  void _requestTurn(Conversation c) {
    final speaker = agents[c.nextSpeaker]!;
    final partner = agents[c.nextSpeaker == c.aId ? c.bId : c.aId]!;
    if (speaker.engaged || speaker.faded) {
      c.done = true;
      return;
    }
    c.pendingJob = true;
    final prompt = prompts.convoTurnPrompt(speaker, partner,
        transcript: c.transcript,
        context: 'near ${nearestPoiName(speaker.x, speaker.y)}',
        askedAbout: c.askedAbout);
    broker.push(JobKind.convoTurn, speaker.id, prompt, speaker.stateVersion,
        convoId: c.id);
  }

  Future<void> _onTurn((Job, ConvoTurn?) rec) async {
    final (job, turn) = rec;
    final c = conversations[job.convoId];
    if (c == null || c.done) return;
    c.pendingJob = false;
    final speaker = agents[job.agentId]!;
    // Stale check: speaker's state changed since job was enqueued (e.g. player
    // engaged them) → drop silently, partner is released via done flag.
    if (job.stateVersion != speaker.stateVersion) {
      c.done = true;
      return;
    }
    final partner = agents[c.nextSpeaker == c.aId ? c.bId : c.aId]!;
    final line = (turn?.line ?? '').trim();
    if (turn == null || line.isEmpty) {
      c.done = true;
      return;
    }

    // Commit rule: shares_secret applies ONLY if the speaker actually owns it.
    String? shared;
    if (turn.sharesSecret != null &&
        speaker.knownSecrets.contains(turn.sharesSecret) &&
        secrets.containsKey(turn.sharesSecret)) {
      shared = turn.sharesSecret;
    }

    // Atomic commit: utterance event + memories + transfer in one logical unit.
    final eid = await store.logEvent(simTs, 'utterance', {
      'convo': c.id, 'speaker': speaker.id, 'listeners': [partner.id],
      'line': line, 'secret': shared,
    });
    c.transcript.add('${speaker.name}: $line');
    await store.memory(Memory(
        agent: speaker.id, simTs: simTs, kind: 'said', source: 'self',
        text: 'to ${partner.name}: $line', importance: 3,
        entities: [partner.id]));
    await store.memory(Memory(
        agent: partner.id, simTs: simTs, kind: 'heard',
        source: 'spirit:${speaker.id}',
        text: '${speaker.name} said: $line', importance: 4,
        entities: [speaker.id]));
    if (shared != null) {
      final learned = await store.transferKnowledge(
          partner.id, shared, 'spirit:${speaker.id}', simTs, eid);
      if (learned) {
        partner.knownSecrets.add(shared);
        partner.bumpVersion();
        await store.simLog(simTs, partner.id, 'learn',
            '$shared via ${speaker.id}');
        await store.memory(Memory(
            agent: partner.id, simTs: simTs, kind: 'heard',
            source: 'spirit:${speaker.id}',
            text: 'learned: ${secrets[shared]!.shareText}', importance: 8,
            entities: [speaker.id, shared]));
      }
    }
    // Batteries: any social contact recharges.
    speaker.battery = min(100, speaker.battery + 4);
    partner.battery = min(100, partner.battery + 6);

    _events.add(SimEvent(SimEventType.say,
        {'agent': speaker.id, 'line': line, 'mood': turn.mood}));

    // Next speaker / done.
    c.nextSpeaker = partner.id;
    if (turn.end || c.transcript.length >= 4) c.done = true;
  }

  /// Player engaged a spirit that was mid-conversation — release the partner.
  void _abortConvoWith(String agentId) {
    for (final c in conversations.values) {
      if (c.aId == agentId || c.bId == agentId) {
        c.done = true;
      }
    }
  }

  // ============================ decisions ==================================

  void _scheduleDecision() {
    final free = agents.values
        .where((a) => !a.engaged && !a.inConvo)
        .toList();
    if (free.isEmpty) return;
    free.sort((a, b) => a.lastActedAt.compareTo(b.lastActedAt));
    final agent = free.first;
    agent.lastActedAt = simTs.toDouble();

    // Build offered actions (weighted by stats).
    final near = _nearby(agent);
    final allowed = <String>['stroll', 'idle'];
    for (final other in near.agents) {
      if (!other.inConvo && !other.engaged) {
        allowed.add('greet(${other.id})');
        allowed.add('converse(${other.id})');
        if (agent.goal != null && agent.goal!.startsWith('askAbout:')) {
          allowed.add('askAbout(${other.id})');
        }
      }
    }
    for (final p in near.pois) {
      if (p.anomaly) allowed.add('inspect(${p.id})');
      if (p.isStall) allowed.add('shop(${p.id})');
    }
    if (agent.knownSecrets.isNotEmpty && near.agents.isNotEmpty) {
      allowed.add('offerSecret(${near.agents.first.id})');
    }

    final prompt = prompts.decisionPrompt(
      agent,
      simClock: _clock(),
      place: nearestPoiName(agent.x, agent.y),
      nearbyEntities: near.describe,
      memories: _memCache[agent.id] ?? const [],
      allowedActions: allowed,
    );
    broker.push(JobKind.decision, agent.id, prompt, agent.stateVersion);
    _refreshMemories(agent);
  }

  final Map<String, List<String>> _memCache = {};
  Future<void> _refreshMemories(Agent a) async {
    final ms = await store.recall(a, simTs,
        contextEntities: _nearby(a).agentIds);
    _memCache[a.id] = ms.map((m) => m.text).toList();
    final st = await store.memoryStats(a.id);
    if (st.count > 40 || st.importanceSum > 60) {
      final old = await store.archiveOldest(a.id, 20);
      broker.push(JobKind.reflection, a.id,
          prompts.reflectionPrompt(a, old), a.stateVersion);
    }
  }

  Future<void> _onReflection((Job, String?) rec) async {
    final (job, summary) = rec;
    final a = agents[job.agentId];
    if (a == null || summary == null || summary.isEmpty) return;
    if (job.stateVersion != a.stateVersion) return;
    await store.memory(Memory(
        agent: a.id, simTs: simTs, kind: 'reflection', source: 'self',
        text: summary, importance: 7));
  }

  void _onDecision((Job, Decision?) rec) {
    final (job, d) = rec;
    final a = agents[job.agentId];
    if (a == null) return;
    // Stale check — drop if the agent's state moved on.
    if (job.stateVersion != a.stateVersion || a.engaged || a.inConvo) return;
    if (d == null) {
      _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '·'});
      return;
    }
    _execute(a, d);
  }

  void _execute(Agent a, Decision d) {
    switch (d.action) {
      case 'converse':
      case 'greet':
        final t = agents[d.target];
        if (t != null && !t.engaged && !t.inConvo && !t.faded) {
          if (d.action == 'greet') {
            _say(a, d.line.isEmpty ? 'evening.' : d.line, d.mood);
            t.battery = min(100, t.battery + 5);
          } else {
            startConversation(a.id, t.id);
          }
          return;
        }
        _fallbackStroll(a);
      case 'askAbout':
        final t = agents[d.target];
        final subject = a.goal?.split(':').last ?? d.subject;
        if (t != null && !t.engaged && !t.inConvo && subject != null) {
          startConversation(a.id, t.id, askedAbout: subject);
          a.goal = null;
          return;
        }
        _fallbackStroll(a);
      case 'inspect':
        final p = pois[d.target];
        if (p != null && _dist2(a.x, a.y, p.x, p.y) < p.radius * p.radius * 4) {
          _say(a, d.line.isEmpty ? p.surfaceText : d.line,
              'curious');
          _emit(a, SimEventType.poiGlow, {'poi': p.id, 'on': true});
          unawaited(store.memory(Memory(
              agent: a.id, simTs: simTs, kind: 'observation', source: 'world',
              text: 'noticed: ${p.surfaceText}', importance: 6,
              entities: [p.id])));
          // Curiosity payoff → goal to ask around.
          if (rng.nextDouble() < a.stats.curiosity / 5) {
            a.goal = 'askAbout:${p.id}';
          }
          return;
        }
        _fallbackStroll(a);
      case 'shop':
      case 'offerSecret':
        final t = agents[d.target];
        if (t != null && !t.engaged && !t.inConvo) {
          startConversation(a.id, t.id,
              askedAbout: d.action == 'shop' ? 'wares' : null);
          return;
        }
        _fallbackStroll(a);
      case 'goto':
        final p = pois[d.target];
        if (p != null) {
          _walkTo(a, p.x, p.y);
          return;
        }
        _fallbackStroll(a);
      case 'stroll':
        _fallbackStroll(a);
      case 'idle':
      default:
        _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '·'});
        if (d.line.isNotEmpty) _say(a, d.line, d.mood);
    }
  }

  void _fallbackStroll(Agent a) {
    // Nearest waypoint → random neighbor.
    var best = 0;
    var bd = double.infinity;
    for (var i = 0; i < waypointPos.length; i++) {
      final d = _dist2(a.x, a.y, waypointPos[i][0], waypointPos[i][1]);
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    final next = waypoints[best][rng.nextInt(waypoints[best].length)];
    _events.add(SimEvent(SimEventType.move, {
      'agent': a.id,
      'path': [waypointPos[best], waypointPos[next]],
    }));
    // Move sim position instantly (render lerps to it).
    a.x = waypointPos[next][0];
    a.y = waypointPos[next][1];
  }

  void _walkTo(Agent a, double x, double y) {
    _events.add(SimEvent(SimEventType.move, {
      'agent': a.id,
      'path': [
        [x, y]
      ],
    }));
    a.x = x;
    a.y = y;
  }

  void _say(Agent a, String line, String mood) {
    _emit(a, SimEventType.say, {'agent': a.id, 'line': line, 'mood': mood});
  }

  void _emit(Agent a, SimEventType t, Map<String, dynamic> data) {
    _events.add(SimEvent(t, data));
    unawaited(store.simLog(simTs, a.id, t.name, jsonEncode(data)));
  }

  // ============================ batteries / fade ===========================

  void _drainBatteries() {
    for (final a in agents.values) {
      if (a.engaged) continue; // player's attention recharges, doesn't drain
      a.battery = max(0, a.battery - 0.6);
      final wasFaded = a.faded;
      a.faded = a.battery <= 8;
      if (a.faded != wasFaded) {
        a.bumpVersion();
        _events.add(SimEvent(SimEventType.state,
            {'agent': a.id, 'faded': a.faded}));
        if (a.faded) _abortConvoWith(a.id);
      }
    }
  }

  // ============================ player API =================================

  /// Engage: exclusive lock on THAT spirit only — town keeps thinking.
  void engage(String agentId) {
    if (engagedId == agentId) return;
    if (engagedId != null) disengage();
    final a = agents[agentId];
    if (a == null) return;
    _abortConvoWith(agentId); // releases partner with a memory below
    a.engaged = true;
    a.bumpVersion();
    a.battery = min(100, a.battery + 15); // attention revives
    if (a.faded && a.battery > 8) {
      a.faded = false;
    }
    engagedId = agentId;
    playerHist.clear();
    _events.add(SimEvent(
        SimEventType.state, {'agent': agentId, 'engaged': true, 'faded': a.faded}));
  }

  /// Release — user-driven only (End / engage another spirit).
  void disengage() {
    final id = engagedId;
    if (id == null) return;
    final a = agents[id];
    engagedId = null;
    if (a != null) {
      a.engaged = false;
      a.bumpVersion();
      a.lastActedAt = simTs.toDouble() - 5; // back into rotation soon
      _events
          .add(SimEvent(SimEventType.state, {'agent': id, 'engaged': false}));
    }
  }

  /// Player message → streamed reply. Grump shapes tone in the prompt;
  /// the spirit never controls the UI.
  Stream<String> sendPlayerMessage(String text) async* {
    final a = agents[engagedId];
    if (a == null) return;
    playerHist.add(ChatMsg(true, text));
    final memories = await store.recall(a, simTs,
        contextEntities: {'player'});
    final prompt = prompts.playerChatPrompt(a,
        history: playerHist.length > 8
            ? playerHist.sublist(playerHist.length - 8)
            : playerHist,
        memories: memories.map((m) => m.text).toList());
    // Player claim → memory as claim, not fact.
    unawaited(store.memory(Memory(
        agent: a.id, simTs: simTs, kind: 'heard', source: 'player_claim',
        text: 'the living one said: $text', importance: 5,
        entities: ['player'])));
    final buf = StringBuffer();
    await for (final chunk in llm.playerChat(prompt)) {
      buf.write(chunk);
      yield chunk;
    }
    playerHist.add(ChatMsg(false, buf.toString()));
    unawaited(store.memory(Memory(
        agent: a.id, simTs: simTs, kind: 'said', source: 'self',
        text: 'to the living one: ${buf.toString()}', importance: 4,
        entities: ['player'])));
    a.battery = min(100, a.battery + 10);
  }

  /// POI inspect — deep lore iff player knows the unlocking secret.
  String inspectPoi(String poiId) {
    final p = pois[poiId];
    if (p == null) return '';
    final secret = secrets.values
        .where((s) => s.unlocksPoiLore == poiId)
        .firstOrNull;
    if (secret != null && playerKnown.contains(secret.id)) return secret.truth;
    return p.surfaceText;
  }

  void learnSecretAsPlayer(String secretId, String via) {
    if (playerKnown.add(secretId)) {
      unawaited(store.logEvent(
          simTs, 'transfer', {'to': 'player', 'secret': secretId, 'via': via}));
    }
  }

  // ============================ misc =======================================

  ({List<Agent> agents, List<Poi> pois, Set<String> agentIds, String describe})
      _nearby(Agent a, {double radius = 220}) {
    final ag = <Agent>[];
    final ps = <Poi>[];
    for (final o in agents.values) {
      if (o.id != a.id && _dist2(a.x, a.y, o.x, o.y) < radius * radius) {
        ag.add(o);
      }
    }
    for (final p in pois.values) {
      if (_dist2(a.x, a.y, p.x, p.y) < radius * radius) ps.add(p);
    }
    final describe = [
      ...ag.map((o) => '${o.name} (${o.condition})'),
      ...ps.map((p) => p.name),
    ].join(', ');
    return (
      agents: ag,
      pois: ps,
      agentIds: ag.map((o) => o.id).toSet(),
      describe: describe.isEmpty ? 'nobody' : describe,
    );
  }

  double _dist2(double x1, double y1, double x2, double y2) {
    final dx = x1 - x2, dy = y1 - y2;
    return dx * dx + dy * dy;
  }

  String nearestPoiName(double x, double y) {
    Poi? best;
    var bd = double.infinity;
    for (final p in pois.values) {
      final d = _dist2(x, y, p.x, p.y);
      if (d < bd) {
        bd = d;
        best = p;
      }
    }
    return best?.name ?? 'the road';
  }

  String _clock() {
    final m = simTs ~/ 60, s = simTs % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  void _autosave() {
    for (final a in agents.values) {
      unawaited(store.saveAgent(a));
    }
    unawaited(store.setWorld('sim_ts', '$simTs'));
    unawaited(store.setWorld('petals', '$playerPetals'));
  }

  bool _ended = false;
  void _endRun() {
    if (_ended) return;
    _ended = true;
    final remembered = agents.values.where((a) => !a.faded).length;
    _events.add(SimEvent(SimEventType.endRun, {
      'remembered': remembered,
      'faded': agents.length - remembered,
    }));
  }
}
