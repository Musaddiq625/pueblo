/// SimEngine — three layers (world clock / conversation manager / inference
/// broker) driving the town. Emits SimEvents the render layer consumes.
/// Pure Dart + sqflite; no Flame imports.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'world_map.dart';
import 'broker.dart';
import 'llm.dart';
import 'models.dart';
import 'navgrid.dart';
import 'prompts.dart';
import 'store.dart';

// ---------------------------------------------------------------------------

enum SimEventType {
  move, // {agent, path:[[x,y],...]} — render lerps along it
  say, // {agent, line, mood} — bubble over head
  emote, // {agent, glyph} — ? ! etc.
  state, // {agent, faded, engaged, x, y}
  pairStart, // {a, b} — both locked into convo
  pairEnd,
  poiGlow, // {poi, on}
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

  /// Why this conversation exists — (holder, secretId) means the holder is
  /// expected to pass secretId to the partner. Null = small talk.
  final ({String holder, String secretId})? purpose;

  Conversation(this.id, this.aId, this.bId, {this.askedAbout, this.purpose})
    : nextSpeaker = aId;
}

// ---------------------------------------------------------------------------

typedef _Arrival = void Function(SimEngine engine, Agent agent);

class SimEngine {
  final SimStore store;
  final LLMClient llm;
  final Map<String, Agent> agents;
  final Map<String, Secret> secrets;
  final Map<String, Poi> pois;
  final NavGrid nav;
  final Random rng;
  final double timeScale; // 1.0 normal; demo mode higher
  final int dawnAt; // sim_ts of run end

  late final PromptBuilder prompts;
  late final InferenceBroker broker;
  final Map<String, Conversation> conversations = {};

  int simTs = 0;
  double _simAcc = 0; // fractional sim-second accumulator
  int playerPetals = 0;
  final Set<String> playerKnown = {};
  final Map<String, int> playerInventory = {}; // itemId -> count
  final Map<String, int> playerChatCount = {}; // agentId -> msgs (warmth)
  String? engagedId;
  final List<ChatMsg> playerHist = [];

  /// shop catalog — deterministic, zero inference. secret items carry a
  /// warmth gate (seller must have talked to the player already).
  static const shopItems = <String, Map<String, Object?>>{
    'bouquet': {
      'name': 'Marigold Bouquet',
      'price': 15,
      'stall': 'flower_stall',
      'desc': 'A bundle of cempasúchil. Gift it — spirits remember kindness.',
    },
    'agua_fresca': {
      'name': 'Agua Fresca',
      'price': 8,
      'stall': 'cantina',
      'desc': 'Sefa\'s brew. Gift it — loosens a spirit\'s tongue.',
    },
    'grave_37_name': {
      'name': 'A Name for Grave 37',
      'price': 40,
      'stall': 'gravedigger_hut',
      'secret': 'grave_37_name',
      'seller': 'bruno',
      'desc': 'Bruno sells the name only to someone he has spoken with.',
    },
  };

  final _events = StreamController<SimEvent>.broadcast();
  Stream<SimEvent> get events => _events.stream;

  double _decisionTimer = 0;
  double _convoTimer = 0;
  double _batteryTimer = 0;
  double _autosaveTimer = 0;
  double _ambientTimer = 0;
  static const decisionEvery = 12.0; // sim seconds (base tick)
  static const convoEvery = 5.0; // bubble pacing
  static const batteryEvery = 10.0;
  static const autosaveEvery = 30.0;
  static const ambientEvery = 1.0; // real seconds between wander checks

  /// Ambient locomotion layer — deterministic, zero inference. The LLM
  /// steers interesting choices; this layer keeps the town ALIVE between
  /// decisions (generative-agents style: bodies always doing something).
  final Map<String, List<List<double>>> _walks = {};
  final Map<String, double> _nextWanderAt = {}; // agentId -> sim_ts
  final Map<String, _Arrival> _arrivals = {}; // deferred on-arrival actions

  /// Activity-slot reservations — 'poi:tx:ty' -> agentId. A spirit holds
  /// its counter/stand spot until it leaves; nobody double-books a grave.
  final Map<String, String> _slotReserved = {};
  final Map<String, String> _agentSlot = {}; // agentId -> slotKey

  /// 'a:b' sorted pair key -> last sim_ts they conversed. Small talk needs
  /// a cooldown; knowledge-sharing offers never do.
  final Map<String, int> _pairLastTalked = {};

  /// Director state — the storyteller's cadence and the current gathering.
  static const directorEvery = 120.0; // sim seconds between beats
  static const directorFirstAt = 90.0; // let the world settle first
  double _nextDirectorAt = directorFirstAt;
  int _gatherUntil = -1; // sim_ts the gathering beat ends
  String _gatherPoi = 'ofrenda';

  /// An approach deferred because the target was engaged/busy — one retry
  /// at the initiator's next decision slot, then the moment passes (§11.9).
  final Map<String, Decision> _pendingApproach = {};

  String _pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a:$b' : '$b:$a';

  SimEngine({
    required this.store,
    required this.llm,
    required this.agents,
    required this.secrets,
    required this.pois,
    NavGrid? nav,
    Random? rng,
    this.timeScale = 1.0,
    this.dawnAt = 900, // 15 sim-minutes
  }) : nav = nav ?? NavGrid.build(),
       rng = rng ?? Random() {
    prompts = PromptBuilder(secrets);
    broker = InferenceBroker(llm, workers: 1);
    broker.decisions.listen(_onDecision);
    broker.turns.listen(_onTurn);
    broker.reflections.listen(_onReflection);
    broker.beats.listen(_applyBeat);
  }

  // ============================ world clock ================================

  void tick(double dt) {
    _advanceWalks(dt); // real-time locomotion — matches render lerp speed
    for (final a in agents.values) {
      if (a.heldBy != null && simTs >= a.heldUntil) a.heldBy = null;
    }
    _simAcc += dt * timeScale;
    final whole = _simAcc.floor();
    if (whole > 0) {
      simTs += whole;
      _simAcc -= whole;
    }
    _decisionTimer += dt * timeScale;
    _convoTimer += dt * timeScale;
    _batteryTimer += dt * timeScale;
    _autosaveTimer += dt * timeScale;
    _ambientTimer += dt;

    if (_convoTimer >= convoEvery) {
      _convoTimer = 0;
      _advanceConversations();
    }
    if (_ambientTimer >= ambientEvery) {
      _ambientTimer = 0;
      _ambientWander();
    }
    if (_decisionTimer >= decisionEvery) {
      _decisionTimer = 0;
      _scheduleDecision();
    }
    if (simTs >= _nextDirectorAt) {
      _nextDirectorAt = simTs + directorEvery;
      _maybeDirect();
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

  void startConversation(
    String aId,
    String bId, {
    String? askedAbout,
    ({String holder, String secretId})? purpose,
  }) {
    final a = agents[aId], b = agents[bId];
    if (a == null || b == null) return;
    if (a.engaged ||
        b.engaged ||
        a.inConvo ||
        b.inConvo ||
        a.faded ||
        b.faded ||
        a.heldBy != null ||
        (b.heldBy != null && b.heldBy != aId)) {
      return;
    }
    final convo = Conversation(
      'c${simTs}_${aId}_$bId',
      aId,
      bId,
      askedAbout: askedAbout,
      purpose: purpose,
    );
    conversations[convo.id] = convo;
    _pairLastTalked[_pairKey(aId, bId)] = simTs;
    // errand satisfied — the initiator was carrying a reason to reach them
    if (a.errand?.targetId == bId &&
        (a.errand?.kind == 'tell' || a.errand?.kind == 'seek')) {
      a.errand = null;
    }
    // both stand where they are — cancel in-flight walks + release slots
    _walks.remove(aId);
    _walks.remove(bId);
    _arrivals.remove(aId);
    _arrivals.remove(bId);
    _releaseSlot(aId);
    _releaseSlot(bId);
    a.heldBy = b.heldBy = null;
    a.inConvo = b.inConvo = true;
    a.bumpVersion();
    b.bumpVersion();
    // face each other
    _emit(
      a,
      SimEventType.state,
      {'agent': aId, 'fx': (b.x - a.x).sign, 'fy': (b.y - a.y).sign},
    );
    _emit(
      b,
      SimEventType.state,
      {'agent': bId, 'fx': (a.x - b.x).sign, 'fy': (a.y - b.y).sign},
    );
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
      // relationships — every completed convo warms the pair a little
      a.warmth[b.id] = (a.warmth[b.id] ?? 0) + 2;
      b.warmth[a.id] = (b.warmth[a.id] ?? 0) + 2;
      unawaited(store.setWorld('warmth.${a.id}', jsonEncode(a.warmth)));
      unawaited(store.setWorld('warmth.${b.id}', jsonEncode(b.warmth)));
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
    final p = c.purpose;
    final prompt = prompts.convoTurnPrompt(
      speaker,
      partner,
      transcript: c.transcript,
      context: 'near ${nearestPoiName(speaker.x, speaker.y)}',
      askedAbout: c.askedAbout,
      role: p == null
          ? null
          : speaker.id == p.holder
              ? 'tell'
              : speaker.id == c.aId
                  ? 'ask'
                  : 'hear',
      shareText: p == null
          ? null
          : (speaker.id == p.holder
                ? secrets[p.secretId]?.shareText
                : secrets[p.secretId]?.surface),
    );
    broker.push(
      JobKind.convoTurn,
      speaker.id,
      prompt,
      speaker.stateVersion,
      convoId: c.id,
    );
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
    final line = _cleanLine(turn?.line ?? '');
    if (turn == null || line.isEmpty) {
      c.done = true;
      return;
    }

    // Commit rule: a secret moves ONLY if the speaker owns it AND the
    // partner doesn't already know it. Two paths:
    //  1. purpose-bound convo — the holder speaks, engine transfers its
    //     declared secret; the model's flag is unnecessary.
    //  2. organic convo — the model volunteers shares_secret, validated
    //     the same way.
    String? shared;
    final p = c.purpose;
    if (p != null &&
        speaker.id == p.holder &&
        speaker.knownSecrets.contains(p.secretId) &&
        !partner.knownSecrets.contains(p.secretId)) {
      shared = p.secretId;
    } else if (turn.sharesSecret != null &&
        turn.sharesSecret != 'null' &&
        speaker.knownSecrets.contains(turn.sharesSecret) &&
        !partner.knownSecrets.contains(turn.sharesSecret) &&
        secrets.containsKey(turn.sharesSecret)) {
      shared = turn.sharesSecret;
    }

    // Atomic commit: utterance event + memories + transfer in one logical unit.
    final eid = await store.logEvent(simTs, 'utterance', {
      'convo': c.id,
      'speaker': speaker.id,
      'listeners': [partner.id],
      'line': line,
      'secret': shared,
    });
    c.transcript.add('${speaker.name}: $line');
    await store.memory(
      Memory(
        agent: speaker.id,
        simTs: simTs,
        kind: 'said',
        source: 'self',
        text: 'to ${partner.name}: $line',
        importance: 3,
        entities: [partner.id],
      ),
    );
    await store.memory(
      Memory(
        agent: partner.id,
        simTs: simTs,
        kind: 'heard',
        source: 'spirit:${speaker.id}',
        text: '${speaker.name} said: $line',
        importance: 4,
        entities: [speaker.id],
      ),
    );
    if (shared != null) {
      final learned = await store.transferKnowledge(
        partner.id,
        shared,
        'spirit:${speaker.id}',
        simTs,
        eid,
      );
      if (learned) {
        partner.knownSecrets.add(shared);
        partner.bumpVersion();
        // a secret received deepens the bond — more than any small talk
        partner.warmth[speaker.id] = (partner.warmth[speaker.id] ?? 0) + 5;
        await store.simLog(
          simTs,
          partner.id,
          'learn',
          '$shared via ${speaker.id}',
        );
        await store.memory(
          Memory(
            agent: partner.id,
            simTs: simTs,
            kind: 'heard',
            source: 'spirit:${speaker.id}',
            text: 'learned: ${secrets[shared]!.shareText}',
            importance: 8,
            entities: [speaker.id, shared],
          ),
        );
        _checkSolidify();
        _events.add(
          SimEvent(SimEventType.log, {
            'text':
                '${speaker.name} tells ${partner.name}: ${secrets[shared]!.shareText}',
          }),
        );
      }
    }
    // Batteries: social contact recharges; passing real knowledge is the
    // deepest connection the sim knows.
    if (shared != null) {
      speaker.battery = min(100, speaker.battery + 10);
      partner.battery = min(100, partner.battery + 12);
    } else {
      speaker.battery = min(100, speaker.battery + 4);
      partner.battery = min(100, partner.battery + 6);
    }

    _events.add(
      SimEvent(SimEventType.say, {
        'agent': speaker.id,
        'line': line,
        'mood': turn.mood,
      }),
    );

    // Next speaker / done. Purpose convos get two extra turns so the
    // listener can react after the knowledge lands.
    c.nextSpeaker = partner.id;
    if (turn.end || c.transcript.length >= (c.purpose != null ? 6 : 4)) {
      c.done = true;
    }
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
        .where((a) => !a.engaged && !a.inConvo && a.heldBy == null)
        .toList();
    if (free.isEmpty) return;
    free.sort((a, b) => a.lastActedAt.compareTo(b.lastActedAt));
    final agent = free.first;
    agent.lastActedAt = simTs.toDouble();

    // A deferred approach consumes this slot — the agent already chose
    // it; conditions just needed to clear. One retry, then the moment
    // passes (no stalker loop).
    final pending = _pendingApproach.remove(agent.id);
    if (pending != null) {
      _execute(agent, pending, canDefer: false);
      return;
    }

    // Build offered actions (weighted by stats).
    final near = _nearby(agent);
    _ensureErrand(agent);
    final errand = agent.errand;
    final allowed = <String>['stroll', 'idle'];

    // Errand-backed offers — the plan the deterministic brain assigned.
    // 'tell'/'seek' chase a spirit; 'verify'/'tend' chase a place.
    if (errand != null) {
      switch (errand.kind) {
        case 'tell' || 'seek':
          if (!near.agentIds.contains(errand.targetId)) {
            allowed.add('seek(${errand.targetId})');
          }
        case 'verify' || 'tend':
          allowed.add('goto(${errand.targetId})');
      }
    }
    for (final other in near.agents) {
      if (other.inConvo || other.engaged) continue;
      // Faded spirits can't converse — but a name spoken can wake one,
      // so greet stays on the table (that is how Solorio comes back).
      if (other.faded) {
        allowed.add('greet(${other.id})');
        continue;
      }

      // Knowledge the engine can verify is offered as concrete actions —
      // the model picks a purpose, not a vibe. share(who,what) means "tell
      // them a secret they don't know"; ask(who) draws out theirs.
      final shareable = agent.knownSecrets.difference(other.knownSecrets);
      for (final sid in shareable) {
        allowed.add('share(${other.id},$sid)');
      }
      if (other.knownSecrets.difference(agent.knownSecrets).isNotEmpty) {
        allowed.add('ask(${other.id})');
      }

      // Small talk cools down per pair — and when there's real news to
      // pass, converse isn't on the menu at all: that pair's talk IS the
      // share. Grumpy spirits keep their exemption — they mutter anyway.
      final sinceTalk =
          simTs - (_pairLastTalked[_pairKey(agent.id, other.id)] ?? -9999);
      if (sinceTalk > 90) {
        allowed.add('greet(${other.id})');
        if (agent.stats.grump >= 4 || shareable.isEmpty) {
          allowed.add('converse(${other.id})');
        }
      }
      if (agent.goal != null && agent.goal!.startsWith('askAbout:')) {
        allowed.add('askAbout(${other.id})');
      }
    }
    for (final p in near.pois) {
      if (p.anomaly) allowed.add('inspect(${p.id})');
      if (p.isStall) allowed.add('shop(${p.id})');
    }

    // Rescue affordance — a fading spirit whose name the decider holds:
    // the single most important fact on the whole decision sheet.
    String? rescue;
    for (final o in near.agents) {
      if (!o.faded) continue;
      for (final s in secrets.values) {
        if (s.wakesAgent == o.id && agent.knownSecrets.contains(s.id)) {
          rescue =
              '${o.name} is FADING — forgotten. You know their name. '
              'greet(${o.id}) speaks it aloud and saves them. Choose it.';
          break;
        }
      }
      if (rescue != null) break;
    }

    final prompt = prompts.decisionPrompt(
      agent,
      simClock: _clock(),
      place: nearestPoiName(agent.x, agent.y),
      nearbyEntities: near.describe,
      memories: _memCache[agent.id] ?? const [],
      allowedActions: allowed,
      errand: _describeErrand(agent),
      rescue: rescue,
      reflection: _reflCache[agent.id],
    );
    broker.push(JobKind.decision, agent.id, prompt, agent.stateVersion);
    _refreshMemories(agent);
    unawaited(_refreshReflection(agent));
  }

  final Map<String, String?> _reflCache = {};
  Future<void> _refreshReflection(Agent a) async {
    _reflCache[a.id] = await store.latestReflection(a.id);
  }

  // ============================ errands (planning) ==========================
  //
  // The genre trick (Generative Agents / AI Town): believable spirits run on
  // plans, not Brownian motion. The engine assigns ONE errand at a time —
  // verify (hear a secret → go see the POI), tell (carry news to the one who
  /// lacks it), seek (dim battery → find company), tend (role routine). The
  /// LLM still chooses how/when to pursue it; the world supplies the reason.
  void _ensureErrand(Agent a) {
    if (a.faded) {
      a.errand = null;
      return;
    }
    // 0a. self-preservation — dim spirits hunt company before they fade
    if (a.battery < 40) {
      Agent? closest;
      var cd = double.infinity;
      for (final o in agents.values) {
        if (o.id == a.id || o.faded || o.engaged) continue;
        final d = _dist2(a.x, a.y, o.x, o.y);
        if (d < cd) {
          cd = d;
          closest = o;
        }
      }
      if (closest != null) {
        a.errand = (kind: 'seek', targetId: closest.id);
        return;
      }
    }
    // 0b. rescue — a fading spirit whose wake-name I hold outranks any
    // routine. Checked before the stale-errand early-return so learning
    // the name mid-night immediately turns the holder toward them.
    for (final f in agents.values) {
      if (!f.faded || f.id == a.id) continue;
      if (a.knownSecrets.any((s) => secrets[s]?.wakesAgent == f.id)) {
        if (a.errand?.kind != 'seek' || a.errand?.targetId != f.id) {
          a.errand = (kind: 'seek', targetId: f.id);
        }
        return;
      }
    }

    final e = a.errand;
    if (e != null) {
      // staleness — the reason evaporated
      if (e.kind == 'verify' && a.verifiedPois.contains(e.targetId)) {
        a.errand = null;
      } else if (e.kind == 'tell' || e.kind == 'seek') {
        final t = agents[e.targetId];
        if (t == null ||
            t.faded ||
            (e.kind == 'tell' &&
                a.knownSecrets.difference(t.knownSecrets).isEmpty) ||
            (e.kind == 'seek' && a.battery > 55)) {
          a.errand = null;
        }
      }
      if (a.errand != null) return;
    }

    // 1. verify — a held secret unlocks lore at a POI never inspected
    for (final sid in a.knownSecrets) {
      final poiId = secrets[sid]?.unlocksPoiLore;
      if (poiId != null &&
          pois.containsKey(poiId) &&
          !a.verifiedPois.contains(poiId)) {
        a.errand = (kind: 'verify', targetId: poiId);
        return;
      }
    }
    // 2. tell — carry news to whoever lacks the most of what a holds,
    // weighted by distance and how warm the pair already is so nearby
    // friends win over far strangers at equal news-value.
    Agent? bestT;
    var bestScore = 0.0;
    for (final o in agents.values) {
      if (o.id == a.id || o.faded || o.engaged) continue;
      final n = a.knownSecrets.difference(o.knownSecrets).length;
      if (n == 0) continue;
      final score = n -
          sqrt(_dist2(a.x, a.y, o.x, o.y)) / (8 * kTile) +
          (a.warmth[o.id] ?? 0) / 10.0;
      if (score > bestScore) {
        bestScore = score;
        bestT = o;
      }
    }
    if (bestT != null) {
      a.errand = (kind: 'tell', targetId: bestT.id);
      return;
    }
    // 3. gathering — a director-triggered beat, or the scheduled ofrenda
    // moment at 60% of the night. Fires whether or not the player attends
    // (the Majora's Mask rule).
    if (simTs < _gatherUntil) {
      a.errand = (kind: 'tend', targetId: _gatherPoi);
      return;
    }
    if (simTs >= dawnAt * 0.6) {
      a.errand = (kind: 'tend', targetId: 'ofrenda');
      return;
    }
    // 4. schedule — the persona's authored routine for this time of
    // night; falls back to their home patch.
    var schedPoi = a.home;
    for (final s in a.schedule) {
      if (simTs >= s.at) schedPoi = s.poi;
    }
    if (pois.containsKey(schedPoi)) {
      a.errand = (kind: 'tend', targetId: schedPoi);
    }
  }

  String? _describeErrand(Agent a) {
    final e = a.errand;
    if (e == null) return null;
    return switch (e.kind) {
      'verify' =>
        'you heard something about ${pois[e.targetId]?.name ?? e.targetId} — go see for yourself',
      'tell' =>
        'you carry news ${agents[e.targetId]?.name ?? e.targetId} hasn\'t heard — find them',
      'seek' => agents[e.targetId]?.faded == true
          ? '${agents[e.targetId]!.name} is fading and you hold their name — reach them'
          : 'you feel dim — find company before the night takes you',
      _ => 'your routine — check on ${pois[e.targetId]?.name ?? e.targetId}',
    };
  }

  // ============================ director (storyteller) =====================
  //
  // RimWorld's AI Storyteller: a deterministic digest of the whole town in,
  // ONE beat from a fixed palette out — rumor, mood, gathering, curiosity
  // spike. The LLM proposes; the engine validates and applies (§11.8).
  // Paced like RimWorld: no beats while a purpose convo is on stage, and
  // a full-cycle cooldown after every landed beat (tension → release).

  final List<String> _recentNotes = [];

  void _maybeDirect() {
    // tension already on stage — a purpose convo means the story is
    // moving on its own; the director stays quiet.
    if (conversations.values.any((c) => c.purpose != null)) return;
    broker.push(
      JobKind.director,
      'director',
      prompts.directorPrompt(_directorDigest()),
      -1, // no staleness gate — the digest is re-validated at apply time
    );
  }

  String _directorDigest() {
    final parts = agents.values
        .map(
          (a) =>
              '${a.id} ${a.faded ? 'FADING' : a.condition} b${a.battery.round()}@${_nearestPoiId(a.x, a.y)}',
        )
        .join('; ');
    final know = secrets.values
        .map(
          (s) =>
              '${s.id} ${agents.values.where((a) => a.knownSecrets.contains(s.id)).length}/${agents.length}',
        )
        .join(', ');
    final hooks = agents.values
        .where((a) => a.hook != null)
        .map((a) => '${a.id}: ${a.hook}')
        .join('; ');
    return 'Town (night ${_clock()}):\n$parts\n'
        'Secrets spreading: $know\n'
        'Hooks: $hooks\n'
        'Recent: ${_recentNotes.isEmpty ? 'the night is still young' : _recentNotes.join('; ')}';
  }

  void _applyBeat(Map<String, dynamic>? beat) {
    if (beat == null) return;
    final kind = beat['beat']?.toString();
    final agent = _fuzzyId(beat['agent']?.toString(), agents.keys.toSet());
    final poi = _fuzzyId(beat['poi']?.toString(), pois.keys.toSet());
    final line = _cleanLine(beat['line']?.toString() ?? '');
    var landed = false;
    switch (kind) {
      case 'rumor':
        if (poi == null || line.isEmpty) return;
        final p = pois[poi]!;
        // the two nearest unfaded spirits overhear — it enters their
        // memory stream and can surface in later prompts/turns.
        final near = agents.values.where((a) => !a.faded).toList()
          ..sort(
            (x, y) => _dist2(x.x, x.y, p.x, p.y)
                .compareTo(_dist2(y.x, y.y, p.x, p.y)),
          );
        for (final a in near.take(2)) {
          unawaited(
            store.memory(
              Memory(
                agent: a.id,
                simTs: simTs,
                kind: 'observation',
                source: 'rumor',
                text: 'whispered near ${p.name}: "$line"',
                importance: 6,
                entities: [poi],
              ),
            ),
          );
        }
        _note('a whisper spreads near ${p.name}: "$line"');
        landed = true;
      case 'mood':
        if (agent == null || line.isEmpty) return;
        final a = agents[agent]!;
        a.mood = line.split(' ').take(5).join(' ');
        _note('${a.name} feels $line');
        landed = true;
      case 'gathering':
        if (poi == null) return;
        _gatherPoi = poi;
        _gatherUntil = simTs + 60;
        _note('the spirits drift toward ${pois[poi]!.name}');
        landed = true;
      case 'curiosity_spike':
        if (agent == null || poi == null) return;
        final a = agents[agent]!;
        if (!a.faded && !a.verifiedPois.contains(poi)) {
          a.errand = (kind: 'verify', targetId: poi);
          _note('${a.name} can\'t stop thinking about ${pois[poi]!.name}');
          landed = true;
        }
      default:
        return; // 'none' or anything unrecognized — the night breathes
    }
    if (landed) {
      unawaited(store.simLog(simTs, 'director', 'beat', kind ?? '?'));
      // tension → release: a full quiet cycle after every landed beat.
      _nextDirectorAt = simTs + directorEvery;
    }
  }

  void _note(String text) {
    _recentNotes.add(text);
    if (_recentNotes.length > 6) _recentNotes.removeAt(0);
    _events.add(SimEvent(SimEventType.log, {'text': text}));
  }

  final Map<String, List<String>> _memCache = {};
  Future<void> _refreshMemories(Agent a) async {
    final ms = await store.recall(
      a,
      simTs,
      contextEntities: _nearby(a).agentIds,
    );
    _memCache[a.id] = ms.map((m) => m.text).toList();
    final st = await store.memoryStats(a.id);
    if (st.count > 40 || st.importanceSum > 60) {
      final old = await store.archiveOldest(a.id, 20);
      broker.push(
        JobKind.reflection,
        a.id,
        prompts.reflectionPrompt(a, old),
        a.stateVersion,
      );
    }
  }

  Future<void> _onReflection((Job, String?) rec) async {
    final (job, summary) = rec;
    final a = agents[job.agentId];
    if (a == null || summary == null || summary.isEmpty) return;
    if (job.stateVersion != a.stateVersion) return;
    await store.memory(
      Memory(
        agent: a.id,
        simTs: simTs,
        kind: 'reflection',
        source: 'self',
        text: summary,
        importance: 7,
      ),
    );
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

  void _execute(Agent a, Decision d, {bool canDefer = true}) {
    // Small models echo offered actions verbatim ("share(bruno,x)") —
    // normalize name(args) into action/target/subject before dispatch.
    var action = d.action.trim();
    var target = d.target;
    var subject = d.subject;
    final m = RegExp(r'^(\w+)\(([^),]+)(?:,([^)]+))?\)$').firstMatch(action);
    if (m != null) {
      action = m.group(1)!;
      target ??= m.group(2)?.trim();
      subject ??= m.group(3)?.trim();
    }
    if (target == 'null' || target == '') target = null;
    if (subject == 'null' || subject == '') subject = null;
    // Small models typo ids ("Solors", "solor_01") — resolve them before
    // dispatch so intent survives a misspelling.
    final allIds = {...agents.keys, ...pois.keys};
    target = _fuzzyId(target, allIds);
    subject = _fuzzyId(subject, {...allIds, ...secrets.keys});
    // The model often picks the errand action without filling the
    // destination — the deterministic plan supplies what it meant.
    if (target == null &&
        (action == 'goto' || action == 'seek') &&
        a.errand?.targetId != null) {
      target = a.errand!.targetId;
    }
    unawaited(
      store.simLog(
        simTs,
        a.id,
        'decide',
        jsonEncode({'action': action, 'target': target, 'subject': subject}),
      ),
    );
    switch (action) {
      case 'converse':
      case 'greet':
        final t = agents[target];
        if (t != null && !t.engaged && !t.inConvo) {
          // faded spirits can't be conversed with but CAN be greeted —
          // exclusion is from initiating, not from being approached.
          if (action == 'greet' || t.faded) {
            _approachForConvo(a, t, onNear: (ag, tt) => _greet(ag, tt, d));
          } else {
            _approachForConvo(
              a,
              t,
              onNear: (ag, tt) => startConversation(ag.id, tt.id),
            );
          }
          return;
        }
        if (t != null && canDefer) {
          _pendingApproach[a.id] = d;
          return;
        }
        _fallbackStroll(a);
      case 'askAbout':
        final t = agents[target];
        final subj = a.goal?.split(':').last ?? subject;
        if (t != null && !t.engaged && !t.inConvo && subj != null) {
          _approachForConvo(
            a,
            t,
            onNear: (ag, tt) {
              startConversation(ag.id, tt.id, askedAbout: subj);
              ag.goal = null;
            },
          );
          return;
        }
        if (t != null && canDefer) {
          _pendingApproach[a.id] = d;
          return;
        }
        _fallbackStroll(a);
      case 'inspect':
        var p = pois[target];
        p ??= _nearestOf(a, (q) => q.anomaly);
        if (p == null) {
          _fallbackStroll(a);
          return;
        }
        // walk to a free stand-slot at the POI, then inspect visibly
        _visitSlot(
          a,
          p.id,
          onArrive: _doInspect(p, d.line),
          onFail: _fallbackStroll,
        );
      case 'shop':
        // browsing a stall — the POI is the target, not a spirit
        var p = pois[target];
        p ??= _nearestOf(a, (q) => q.isStall);
        if (p != null) {
          _visitSlot(
            a,
            p.id,
            onArrive: _browse(p, line: d.line),
            onFail: _fallbackStroll,
          );
          return;
        }
        _fallbackStroll(a);
      case 'share':
      case 'offerSecret': // legacy — same thing
        final t = agents[target];
        if (t == null || t.engaged || t.inConvo || t.faded) {
          if (t != null && !t.faded && canDefer) {
            _pendingApproach[a.id] = d;
            return;
          }
          _fallbackStroll(a);
          return;
        }
        _approachForConvo(
          a,
          t,
          onNear: (ag, tt) {
            // Recompute at arrival — secret sets can shift mid-walk.
            var sid = subject;
            if (sid == null ||
                !ag.knownSecrets.contains(sid) ||
                tt.knownSecrets.contains(sid)) {
              final diff = ag.knownSecrets.difference(tt.knownSecrets);
              sid = diff.isEmpty ? null : diff.first;
            }
            startConversation(
              ag.id,
              tt.id,
              purpose:
                  sid == null ? null : (holder: ag.id, secretId: sid),
            );
          },
        );
        return;
      case 'ask':
        final t = agents[target];
        if (t == null || t.engaged || t.inConvo || t.faded) {
          if (t != null && !t.faded && canDefer) {
            _pendingApproach[a.id] = d;
            return;
          }
          _fallbackStroll(a);
          return;
        }
        _approachForConvo(
          a,
          t,
          onNear: (ag, tt) {
            final diff = tt.knownSecrets.difference(ag.knownSecrets);
            startConversation(
              ag.id,
              tt.id,
              purpose: diff.isEmpty
                  ? null
                  : (holder: tt.id, secretId: diff.first),
            );
          },
        );
        return;
      case 'seek':
        // walk to the errand's person — the talk happens on a later
        // decision. A faded spirit is approachable when we carry their
        // wake-name (the rescue-seek errand).
        final t = agents[target];
        final canWake = t != null &&
            t.faded &&
            a.knownSecrets.any((s) => secrets[s]?.wakesAgent == t.id);
        if (t == null || (t.faded && !canWake) || t.inConvo || t.engaged) {
          if (t != null && !t.faded && canDefer) {
            _pendingApproach[a.id] = d;
            return;
          }
          _fallbackStroll(a);
          return;
        }
        _approachForConvo(
          a,
          t,
          onNear: (ag, tt) {
            ag.errand = null; // arrived — next decision decides what to say
            _nextWanderAt[ag.id] = simTs + 1;
          },
          onFail: _fallbackStroll,
        );
        return;
      case 'goto':
        final p = pois[target];
        if (p != null) {
          _visitSlot(
            a,
            p.id,
            onArrive: (e, ag) {
              if (ag.errand?.targetId == p.id) {
                // arriving IS seeing — the verify errand is satisfied
                ag.verifiedPois.add(p.id);
                ag.errand = null;
                unawaited(
                  store.memory(
                    Memory(
                      agent: ag.id,
                      simTs: e.simTs,
                      kind: 'observation',
                      source: 'self',
                      text: 'went to see ${p.name} — the rumor was true',
                      importance: 6,
                      entities: [p.id],
                    ),
                  ),
                );
              }
              _nextWanderAt[ag.id] = e.simTs + 5 + e.rng.nextDouble() * 5;
            },
            onFail: _fallbackStroll,
          );
          return;
        }
        _fallbackStroll(a);
      case 'stroll':
        _fallbackStroll(a);
      case 'idle':
      default:
        _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '·'});
        _sayOrNote(a, d.line, d.mood);
    }
  }

  /// Standing at a POI → observe it. Curiosity payoff → goal to ask around.
  _Arrival _doInspect(Poi p, String line) => (e, a) {
    _sayOrNote(a, line.isEmpty ? p.surfaceText : line, 'curious');
    a.verifiedPois.add(p.id);
    if (a.errand?.targetId == p.id) {
      a.errand = null;
      unawaited(
        store.memory(
          Memory(
            agent: a.id,
            simTs: simTs,
            kind: 'observation',
            source: 'self',
            text: 'went to see ${p.name} — the rumor was true',
            importance: 6,
            entities: [p.id],
          ),
        ),
      );
    }
    _emit(a, SimEventType.poiGlow, {'poi': p.id, 'on': true});
    unawaited(
      Future.delayed(
        const Duration(seconds: 4),
        () => _emit(a, SimEventType.poiGlow, {'poi': p.id, 'on': false}),
      ),
    );
    unawaited(
      store.memory(
        Memory(
          agent: a.id,
          simTs: simTs,
          kind: 'observation',
          source: 'world',
          text: 'noticed: ${p.surfaceText}',
          importance: 6,
          entities: [p.id],
        ),
      ),
    );
    if (rng.nextDouble() < a.stats.curiosity / 5) {
      a.goal = 'askAbout:${p.id}';
    }
    _nextWanderAt[a.id] = e.simTs + 5 + e.rng.nextDouble() * 4;
  };

  /// Greeting — the named greeting is the resurrection mechanic: if the
  /// greeter holds a secret that names the target (wakes_agent), speaking
  /// the name recharges them hard. Otherwise a normal small recharge.
  void _greet(Agent a, Agent t, Decision d) {
    Secret? wakeSecret;
    for (final s in secrets.values) {
      if (s.wakesAgent == t.id && a.knownSecrets.contains(s.id)) {
        wakeSecret = s;
        break;
      }
    }
    if (wakeSecret != null) {
      _say(a, d.line.isEmpty ? '¡${t.name.split(' ').first}! Still with us?' : _cleanLine(d.line), 'warm');
      t.battery = min(100, t.battery + 25);
      unawaited(
        store.memory(
          Memory(
            agent: t.id,
            simTs: simTs,
            kind: 'heard',
            source: 'spirit:${a.id}',
            text: '${a.name} spoke their name — remembered aloud',
            importance: 9,
            entities: [a.id, wakeSecret.id],
          ),
        ),
      );
      _emit(t, SimEventType.emote, {'agent': t.id, 'glyph': '✨'});
    } else {
      _say(a, d.line.isEmpty ? 'evening.' : d.line, d.mood);
      t.battery = min(100, t.battery + 5);
    }
    if (t.faded && t.battery > 8) {
      t.faded = false;
      t.bumpVersion();
      _events.add(
        SimEvent(SimEventType.state, {'agent': t.id, 'faded': false}),
      );
    }
  }

  // ============================ locomotion =================================

  /// Renderer-side stop — sim walks and visual lerps are separate; when
  /// the sim cancels a path the component must be told to stand down.
  void _stopVisual(Agent a) {
    _events.add(
      SimEvent(SimEventType.move, {'agent': a.id, 'path': const []}),
    );
  }

  /// Walk to a spirit, then run [onNear]. The target is "held" — stops
  /// wandering while the initiator approaches (they see it coming) — so
  /// conversations always happen face to face, never across the plaza.
  void _approachForConvo(
    Agent a,
    Agent t, {
    required void Function(Agent, Agent) onNear,
    void Function(Agent)? onFail,
  }) {
    void fail() {
      if (onFail != null) {
        onFail(a);
      } else {
        _fallbackStroll(a);
      }
    }
    if (t.heldBy != null || t.engaged || t.inConvo) {
      fail();
      return;
    }
    t.heldBy = a.id;
    t.heldUntil = simTs + 14;
    _walks.remove(t.id); // pause mid-path — someone is coming to talk
    _arrivals.remove(t.id);
    _releaseSlot(t.id);
    _stopVisual(t);

    // stand on a walkable tile adjacent to the target
    final tx = (t.x / kTile).floor(), ty = (t.y / kTile).floor();
    (int, int)? best;
    var bd = double.infinity;
    for (final d in const [
      (0, -1), (0, 1), (-1, 0), (1, 0),
      (-1, -1), (1, -1), (-1, 1), (1, 1),
    ]) {
      final nx = tx + d.$1, ny = ty + d.$2;
      if (!nav.walkable(nx, ny)) continue;
      final dd = _dist2(a.x, a.y, tileX(nx), tileY(ny));
      if (dd < bd) {
        bd = dd;
        best = (nx, ny);
      }
    }
    if (best == null) {
      t.heldBy = null;
      fail();
      return;
    }
    _routeTo(
      a,
      best.$1,
      best.$2,
      onArrive: (e, ag) {
        if (t.heldBy != ag.id || t.engaged || t.inConvo) return;
        t.heldBy = null;
        // face each other
        _emit(ag, SimEventType.state, {
          'agent': ag.id,
          'fx': (t.x - ag.x).sign,
          'fy': (t.y - ag.y).sign,
        });
        _emit(t, SimEventType.state, {
          'agent': t.id,
          'fx': (ag.x - t.x).sign,
          'fy': (ag.y - t.y).sign,
        });
        onNear(ag, t);
      },
    );
  }

  /// Deferred action fired when an agent's path completes at a target.
  void _fallbackStroll(Agent a) {
    _releaseSlot(a.id); // leaving wherever they were standing
    // stroll = hop to a nearby street/plaza tile (spirits favor roads)
    final tx = (a.x / kTile).floor(), ty = (a.y / kTile).floor();
    final cands = <(int, int)>[];
    for (var dy = -6; dy <= 6; dy++) {
      for (var dx = -6; dx <= 6; dx++) {
        final nx = tx + dx, ny = ty + dy;
        if (nx < 0 || nx >= kMapTilesW || ny < 0 || ny >= kMapTilesH) continue;
        final ch = villageAscii[ny][nx];
        if ((ch == 'd' || ch == 's' || ch == 'p') && nav.walkable(nx, ny)) {
          cands.add((nx, ny));
        }
      }
    }
    if (cands.isEmpty) return;
    final t = cands[rng.nextInt(cands.length)];
    _routeTo(a, t.$1, t.$2);
  }

  /// A* route on the walkable grid to a tile. Spirits stay on streets and
  /// path around buildings — the waypoint graph is gone.
  void _routeTo(Agent a, int tx, int ty, {_Arrival? onArrive}) {
    final pts = nav.route(a.x, a.y, tx, ty);
    final path = [
      for (final p in pts) [p.x, p.y],
    ];
    _setPath(a, path, onArrive: onArrive);
  }

  // ------------------------- activity slots -------------------------------

  String _slotKey(ActivitySlot s) => '${s.poiId}:${s.tx}:${s.ty}';

  /// Free slot for a POI nearest the agent, or null if all taken.
  ActivitySlot? _freeSlot(String poiId, Agent a) {
    ActivitySlot? best;
    var bd = double.infinity;
    for (final s in villageSlots) {
      if (s.poiId != poiId) continue;
      if (_slotReserved.containsKey(_slotKey(s))) continue;
      final d = _dist2(a.x, a.y, tileX(s.tx), tileY(s.ty));
      if (d < bd) {
        bd = d;
        best = s;
      }
    }
    return best;
  }

  void _releaseSlot(String agentId) {
    final key = _agentSlot.remove(agentId);
    if (key != null) _slotReserved.remove(key);
  }

  /// Reserve + route to a POI slot. On arrival the spirit faces the
  /// counter/grave and dwells before wandering on.
  void _visitSlot(
    Agent a,
    String poiId, {
    required _Arrival onArrive,
    void Function(Agent)? onFail,
  }) {
    final s = _freeSlot(poiId, a);
    if (s == null) {
      onFail?.call(a);
      return;
    }
    final key = _slotKey(s);
    _releaseSlot(a.id);
    _slotReserved[key] = a.id;
    _agentSlot[a.id] = key;
    _routeTo(
      a,
      s.tx,
      s.ty,
      onArrive: (e, ag) {
        _emit(ag, SimEventType.state, {'agent': ag.id, 'fx': s.fx, 'fy': s.fy});
        onArrive(e, ag);
      },
    );
  }

  void _setPath(Agent a, List<List<double>> pts, {_Arrival? onArrive}) {
    // Drop the first leg if the agent is already essentially on it.
    if (pts.length > 1 && _dist2(a.x, a.y, pts[0][0], pts[0][1]) < 400) {
      pts = pts.sublist(1);
    }
    if (pts.isEmpty) {
      onArrive?.call(this, a);
      return;
    }
    _walks[a.id] = pts;
    if (onArrive != null) _arrivals[a.id] = onArrive;
    _events.add(SimEvent(SimEventType.move, {'agent': a.id, 'path': pts}));
  }

  /// Advance every walking agent along its path at the SAME rate the
  /// renderer lerps (real dt × kSpiritSpeed) — sim and pixels stay in sync.
  void _advanceWalks(double dt) {
    for (final id in _walks.keys.toList()) {
      final a = agents[id];
      final path = _walks[id];
      if (a == null || path == null || a.engaged) {
        _walks.remove(id);
        continue;
      }
      var budget = kSpiritSpeed * dt;
      while (budget > 0 && path.isNotEmpty) {
        final t = path.first;
        final dx = t[0] - a.x, dy = t[1] - a.y;
        final dist = sqrt(dx * dx + dy * dy);
        if (dist <= budget) {
          a.x = t[0];
          a.y = t[1];
          path.removeAt(0);
          budget -= dist;
        } else {
          a.x += dx / dist * budget;
          a.y += dy / dist * budget;
          budget = 0;
        }
      }
      if (path.isEmpty) {
        _walks.remove(id);
        final arrive = _arrivals.remove(id);
        if (arrive != null) {
          arrive(this, a);
        } else {
          // dwell a beat, then the ambient brain picks the next hop
          _nextWanderAt[id] = simTs + 2.5 + rng.nextDouble() * 5;
        }
      }
    }
  }

  /// Deterministic ambient life — keeps every unfaded, unengaged spirit
  /// doing something between LLM decisions. ~2/3 of trips route to a POI
  /// activity slot (browse a stall, pay respects at a grave, sit at the
  /// fountain) so spirits visibly DO things on their own.
  void _ambientWander() {
    for (final a in agents.values) {
      if (a.engaged || a.inConvo || a.faded || a.heldBy != null) continue;
      if (_walks.containsKey(a.id)) continue;
      if (simTs < (_nextWanderAt[a.id] ?? 0)) continue;
      final r = rng.nextDouble();
      // An active errand steers the ambient hop — the walk has a reason.
      final e = a.errand;
      final errandPoi = e != null &&
              (e.kind == 'verify' || e.kind == 'tend') &&
              pois[e.targetId] != null
          ? pois[e.targetId]
          : null;
      if (errandPoi != null && r < 0.8) {
        _visitSlot(a, errandPoi.id, onArrive: _browse(errandPoi),
            onFail: _fallbackStroll);
      } else if (r < 0.65) {
        // visit a POI — weight stalls & anomalies, but any POI qualifies
        final targets = pois.values
            .where((p) => villageSlots.any((s) => s.poiId == p.id))
            .toList();
        if (targets.isEmpty) {
          _fallbackStroll(a);
          continue;
        }
        // persona bias: home POI draws them back occasionally
        var p = targets[rng.nextInt(targets.length)];
        if (r < 0.18) {
          final homePoi = pois[a.home];
          if (homePoi != null) p = homePoi;
        }
        _visitSlot(a, p.id, onArrive: _browse(p), onFail: _fallbackStroll);
      } else {
        _fallbackStroll(a);
      }
    }
  }

  /// Reached a POI slot — face it, linger, glow the marker, remember it.
  _Arrival _browse(Poi p, {String line = ''}) => (e, a) {
    _sayOrNote(a, line, 'warm');
    if (a.errand?.targetId == p.id &&
        (a.errand?.kind == 'tend' || a.errand?.kind == 'verify')) {
      a.verifiedPois.add(p.id);
      a.errand = null;
    }
    _emit(a, SimEventType.poiGlow, {'poi': p.id, 'on': true});
    unawaited(
      Future.delayed(
        const Duration(seconds: 3),
        () => _emit(a, SimEventType.poiGlow, {'poi': p.id, 'on': false}),
      ),
    );
    _nextWanderAt[a.id] = e.simTs + 7 + e.rng.nextDouble() * 7;
    unawaited(
      store.memory(
        Memory(
          agent: a.id,
          simTs: simTs,
          kind: 'observation',
          source: 'world',
          text: 'stopped by ${p.name}',
          importance: 2,
          entities: [p.id],
        ),
      ),
    );
  };

  /// Small models leak JSON edge punctuation into their lines
  /// ("How's the night?\",") — strip wrapper quotes/stray commas at the
  /// ends only; mid-line apostrophes are sacred.
  static String _cleanLine(String s) =>
      s.trim().replaceAll(RegExp('^[\'"]+|[\'",]+\$'), '').trim();

  void _say(Agent a, String line, String mood) {
    _emit(a, SimEventType.say, {'agent': a.id, 'line': line, 'mood': mood});
  }

  /// Talking to yourself is narration, not speech. A line only becomes a
  /// spoken `say` when another spirit is actually within earshot — or the
  /// speaker is grumpy enough to mutter at the world. Otherwise it lands
  /// in the town log as a quiet note: no bubble, no "random talking".
  void _sayOrNote(Agent a, String line, String mood) {
    line = _cleanLine(line);
    if (line.isEmpty) return;
    final heard = agents.values.any(
      (o) =>
          o.id != a.id &&
          !o.faded &&
          _dist2(a.x, a.y, o.x, o.y) < 120 * 120,
    );
    if (heard || a.stats.grump >= 3) {
      _say(a, line, mood);
    } else {
      _emit(a, SimEventType.log, {'text': '${a.name}: $line'});
    }
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
      if (a.solidified) a.battery = max(a.battery, 20);
      final wasFaded = a.faded;
      a.faded = !a.solidified && a.battery <= 8;
      if (a.faded != wasFaded) {
        a.bumpVersion();
        _events.add(
          SimEvent(SimEventType.state, {'agent': a.id, 'faded': a.faded}),
        );
        if (a.faded) {
          _abortConvoWith(a.id);
          _releaseSlot(a.id);
        }
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
    _walks.remove(agentId); // freeze mid-path at current position
    _arrivals.remove(agentId);
    _releaseSlot(agentId);
    a.heldBy = null; // being held no longer applies — the player wins
    for (final o in agents.values) {
      if (o.heldBy == agentId) o.heldBy = null; // drop any approach hold
    }
    a.engaged = true;
    a.bumpVersion();
    a.battery = min(100, a.battery + 15); // attention revives
    if (a.faded && a.battery > 8) {
      a.faded = false;
    }
    engagedId = agentId;
    playerHist.clear();
    _events.add(
      SimEvent(SimEventType.state, {
        'agent': agentId,
        'engaged': true,
        'faded': a.faded,
      }),
    );
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
      _nextWanderAt[id] = simTs + 3; // resume strolling shortly after release
      _events.add(
        SimEvent(SimEventType.state, {'agent': id, 'engaged': false}),
      );
    }
  }

  /// Player message → streamed reply. Grump shapes tone in the prompt;
  /// the spirit never controls the UI.
  Stream<String> sendPlayerMessage(String text) async* {
    final a = agents[engagedId];
    if (a == null) return;
    playerHist.add(ChatMsg(true, text));
    playerChatCount[a.id] = (playerChatCount[a.id] ?? 0) + 1;
    // Player teaching a name: if the player knows `grave_37_name` and speaks
    // "solorio", the engaged spirit learns it. Saying it TO Solorio revives.
    if (playerKnown.contains('grave_37_name') &&
        text.toLowerCase().contains('solorio')) {
      if (a.id == 'solorio') {
        a.battery = min(100, a.battery + 40);
        if (a.faded && a.battery > 8) {
          a.faded = false;
          a.bumpVersion();
          _events.add(
            SimEvent(SimEventType.state, {'agent': a.id, 'faded': false}),
          );
        }
      } else if (a.knownSecrets.add('grave_37_name')) {
        final eid = await store.logEvent(simTs, 'utterance', {
          'speaker': 'player',
          'listeners': [a.id],
          'line': text,
          'secret': 'grave_37_name',
        });
        unawaited(
          store.transferKnowledge(a.id, 'grave_37_name', 'player', simTs, eid),
        );
        a.bumpVersion();
        _checkSolidify();
      }
    }
    final memories = await store.recall(a, simTs, contextEntities: {'player'});
    final prompt = prompts.playerChatPrompt(
      a,
      history: playerHist.length > 8
          ? playerHist.sublist(playerHist.length - 8)
          : playerHist,
      memories: memories.map((m) => m.text).toList(),
    );
    // Player claim → memory as claim, not fact.
    unawaited(
      store.memory(
        Memory(
          agent: a.id,
          simTs: simTs,
          kind: 'heard',
          source: 'player_claim',
          text: 'the living one said: $text',
          importance: 5,
          entities: ['player'],
        ),
      ),
    );
    final buf = StringBuffer();
    await for (final chunk in llm.playerChat(prompt)) {
      buf.write(chunk);
      yield chunk;
    }
    playerHist.add(ChatMsg(false, buf.toString()));
    unawaited(
      store.memory(
        Memory(
          agent: a.id,
          simTs: simTs,
          kind: 'said',
          source: 'self',
          text: 'to the living one: ${buf.toString()}',
          importance: 4,
          entities: ['player'],
        ),
      ),
    );
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
      unawaited(
        store.logEvent(simTs, 'transfer', {
          'to': 'player',
          'secret': secretId,
          'via': via,
        }),
      );
    }
  }

  // ============================ shop / gifts ===============================

  /// Items a stall offers the player. `grave_37_name` is warmth-gated:
  /// Bruno must have spoken with the player at least once.
  List<Map<String, Object?>> stallItems(String stallId) {
    return shopItems.entries
        .where((e) => e.value['stall'] == stallId)
        .map(
          (e) => {
            'id': e.key,
            'name': e.value['name'],
            'price': e.value['price'],
            'desc': e.value['desc'],
            'locked':
                e.value['seller'] != null &&
                (playerChatCount[e.value['seller']] ?? 0) == 0,
            'secret': e.value['secret'],
          },
        )
        .toList();
  }

  /// Atomic purchase via store.transaction. Returns true on commit.
  Future<bool> buyItem(String itemId) async {
    final item = shopItems[itemId];
    if (item == null) return false;
    if (item['seller'] != null && (playerChatCount[item['seller']] ?? 0) == 0) {
      return false; // warmth gate — seller doesn't trust the player yet
    }
    final ok = await store.purchase(
      'player',
      itemId,
      item['price'] as int,
      simTs,
      secretId: item['secret'] as String?,
      secretFrom: 'purchase',
    );
    if (ok) {
      playerPetals -= item['price'] as int;
      playerInventory[itemId] = (playerInventory[itemId] ?? 0) + 1;
      final s = item['secret'] as String?;
      if (s != null) learnSecretAsPlayer(s, 'purchase');
      _events.add(
        SimEvent(SimEventType.log, {
          'text': 'bought ${item['name']} for ${item['price']} petals',
        }),
      );
    }
    return ok;
  }

  /// Give an inventory item to the engaged/nearby spirit — battery + warmth.
  Future<bool> giveGift(String agentId, String itemId) async {
    if ((playerInventory[itemId] ?? 0) <= 0) return false;
    final a = agents[agentId];
    if (a == null) return false;
    playerInventory[itemId] = playerInventory[itemId]! - 1;
    final boost = itemId == 'bouquet' ? 25.0 : 12.0;
    a.battery = min(100, a.battery + boost);
    if (a.faded && a.battery > 8) {
      a.faded = false;
      a.bumpVersion();
      _events.add(
        SimEvent(SimEventType.state, {'agent': a.id, 'faded': false}),
      );
    }
    _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '🌼'});
    await store.logEvent(simTs, 'gift', {
      'from': 'player',
      'to': agentId,
      'item': itemId,
    });
    await store.memory(
      Memory(
        agent: a.id,
        simTs: simTs,
        kind: 'heard',
        source: 'player_claim',
        text: 'the living one gave me ${shopItems[itemId]?['name']}',
        importance: 7,
        entities: ['player'],
      ),
    );
    return true;
  }

  /// Solorio solidifies once 3+ spirits know his name — memory = resurrection.
  void _checkSolidify() {
    final solorio = agents['solorio'];
    if (solorio == null || solorio.solidified) return;
    final knowers = agents.values
        .where(
          (a) => a.id != 'solorio' && a.knownSecrets.contains('grave_37_name'),
        )
        .length;
    if (knowers >= 3) {
      solorio.solidified = true;
      solorio.faded = false;
      solorio.battery = max(solorio.battery, 60);
      solorio.bumpVersion();
      _events.add(
        SimEvent(SimEventType.state, {'agent': 'solorio', 'faded': false}),
      );
      _events.add(
        SimEvent(SimEventType.log, {
          'text': 'Solorio solidifies — the town says his name again.',
        }),
      );
      unawaited(
        store.logEvent(simTs, 'solidify', {
          'agent': 'solorio',
          'knowers': knowers,
        }),
      );
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

  /// Resolve a possibly-misspelled id: exact → normalized → prefix →
  /// Levenshtein≤1. Returns null when nothing is close enough to trust.
  String? _fuzzyId(String? raw, Set<String> ids) {
    if (raw == null) return null;
    if (ids.contains(raw)) return raw;
    final norm = _normId(raw);
    for (final id in ids) {
      if (_normId(id) == norm) return id;
    }
    for (final id in ids) {
      if (_normId(id).startsWith(norm) || norm.startsWith(_normId(id))) {
        return id;
      }
    }
    String? best;
    var bd = 2;
    for (final id in ids) {
      final d = _lev(_normId(id), norm);
      if (d < bd) {
        bd = d;
        best = id;
      }
    }
    return best;
  }

  static String _normId(String s) => s
      .toLowerCase()
      .replaceAll('á', 'a')
      .replaceAll('é', 'e')
      .replaceAll('í', 'i')
      .replaceAll('ó', 'o')
      .replaceAll('ú', 'u')
      .replaceAll('ñ', 'n')
      .replaceAll(RegExp('[^a-z0-9_]'), '');

  static int _lev(String a, String b) {
    var prev = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final cur = <int>[i];
      for (var j = 1; j <= b.length; j++) {
        cur.add(
          min(
            min(cur[j - 1] + 1, prev[j] + 1),
            prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
          ),
        );
      }
      prev = cur;
    }
    return prev[b.length];
  }

  /// The model often picks an action without filling its target — the
  /// deterministic world supplies the nearest valid destination.
  Poi? _nearestOf(Agent a, bool Function(Poi) predicate) {
    Poi? best;
    var bd = double.infinity;
    for (final q in pois.values) {
      if (!predicate(q)) continue;
      final d = _dist2(a.x, a.y, q.x, q.y);
      if (d < bd) {
        bd = d;
        best = q;
      }
    }
    return best;
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

  String _nearestPoiId(double x, double y) {
    Poi? best;
    var bd = double.infinity;
    for (final p in pois.values) {
      final d = _dist2(x, y, p.x, p.y);
      if (d < bd) {
        bd = d;
        best = p;
      }
    }
    return best?.id ?? 'road';
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
    _events.add(
      SimEvent(SimEventType.endRun, {
        'remembered': remembered,
        'faded': agents.length - remembered,
      }),
    );
  }
}
