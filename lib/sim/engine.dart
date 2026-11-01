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
  endRun, // {remembered, faded, verdict} — the one-shot resolution report
  verdict, // {culprit, passed, text} — the case's deterministic resolution
  thought, // {agent, text} — Decision.thought, a fading float over the head
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

  /// Why this conversation exists — (holder, subject, isClaim) means the
  /// holder is expected to pass that knowledge to the partner: a Secret id
  /// when [isClaim] is false, a Claim id (player-planted rumor) when true.
  /// Null = small talk.
  final ({String holder, String subject, bool isClaim})? purpose;

  /// In a purpose convo the holder must get a turn before 'end' is honored —
  /// an asker who ends their opening line would otherwise kill the declared
  /// transfer before the holder ever speaks.
  bool holderSpoke = false;

  /// A proof-holder cornered the culprit — the prompt tells him to deny
  /// and deflect; when the convo ends he counter-accuses.
  bool deny = false;

  /// sim_ts the pair is actually released — a done convo lingers a few
  /// sim-seconds so the last spoken line lands before anyone walks off.
  int? releaseAt;

  /// Normalized lines already spoken this convo — small models loop on long
  /// transcripts ("I saw the same person too." ×5); a repeat ends the convo.
  final Set<String> linesSeen = {};

  Conversation(this.id, this.aId, this.bId, {this.askedAbout, this.purpose})
    : nextSpeaker = aId;
}

// ---------------------------------------------------------------------------

typedef _Arrival = void Function(SimEngine engine, Agent agent);

/// One scripted whisper beat — a private mutter (to: null) or a
/// friend-only confidence (to: confidant). `canon` tokens are what the
/// living one's relay must hit for the whisper to become admissible
/// proof; `grants` is the canonical secret it unlocks.
typedef WhisperBeat = ({
  String id,
  String speaker,
  String? to,
  String line,
  String? grants,
  List<String> canon,
  int at,

  /// sim_ts the confidence stops being a secret even if the living one
  /// never carried it — the village mutters to itself, and eventually a
  /// mutter is overheard. The living one is the shortcut, not the lock.
  int leak,
});

class SimEngine {
  final SimStore store;
  final LLMClient llm;
  final Map<String, Agent> agents;
  final Map<String, Secret> secrets;
  final Map<String, Poi> pois;
  final NavGrid nav;
  final Random rng;
  double timeScale; // 1.0 normal; demo mode higher — HUD-adjustable
  final int festivalAt; // sim_ts of run end

  /// The authored culprit — fixed in v1 (La Golondrina case: 'ramon').
  /// Tests override with a fixture id.
  final String culpritId;

  /// Authored private whispers (assets/data/whispers.json) — beats the
  /// player can overhear but the ledger never sees. A beat fires when
  /// its speaker is free at `at` sim-s, and proof beats re-fire until
  /// the living one relays them into circulation.
  final List<WhisperBeat> whispers;

  /// Beat id -> last sim_ts it was emitted (loop-until-relayed spacing).
  final Map<String, int> _whisperFiredAt = {};

  /// Beat ids the player has overheard — the case-file's job board.
  final Set<String> overheardWhispers = {};

  /// sim_ts of the last player message — drives the stall nudges and
  /// which "whisper died" epilogue the case closes on.
  int lastPlayerMsgTs = -1;

  /// Per-agent stall-nudge cooldown, plus a global throttle so the
  /// village doesn't chorus "give me a thought" at once.
  final Map<String, int> _lastNudgeAt = {};
  int _lastNudgeAny = -999;

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
  /// Per-spirit chat history with the living one — a spirit remembers its
  /// own conversations across engagements (Sefa never sees what you told
  /// Luz). Capped so a long festival doesn't grow a transcript without
  /// end; the durable gist lives in the memory store regardless.
  final Map<String, List<ChatMsg>> _playerHists = {};
  static const _playerHistCap = 30;

  List<ChatMsg> _hist(String id) => _playerHists.putIfAbsent(id, () => []);

  /// The transcript for a spirit — the inspect card restores it on
  /// reopen so a returned conversation picks up where it left off.
  List<ChatMsg> playerHistoryFor(String agentId) =>
      List.unmodifiable(_playerHists[agentId] ?? const []);

  /// Spirits who received a gift from the player — counts as rapport for
  /// the rumor gate (a kindness bought, remembered).
  final Set<String> giftedAgents = {};
  bool _playerBusy = false; // one player chat in flight at a time

  /// Backend reachability — probed on a real-time timer (not sim-scaled:
  /// the server is down in wall-clock time). The HUD badges it so an
  /// unreachable model reads as "offline", not silent spirits.
  bool llmAlive = true;
  double _probeTimer = 0;

  /// Player-planted rumors — free-text claims that circulate mouth-to-mouth
  /// through the same purpose-convo machinery as secrets, but in their own
  /// ledger: they never unlock POI lore, never touch the verdict, and the
  /// telephone-versions each holder carries let the story mutate in transit.
  final Map<String, Claim> claims = {};
  int claimSeq = 0;

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
  double _petalTimer = 0;
  static const decisionEvery = 12.0; // sim seconds (base tick)
  static const convoEvery = 5.0; // bubble pacing
  static const batteryEvery = 10.0;
  static const autosaveEvery = 30.0;
  static const ambientEvery = 1.0; // real seconds between wander checks
  static const petalEvery = 45.0; // sim seconds between petal spawns
  static const pairCooldown = 90.0; // sim seconds between a pair's small talk
  static const holdFor = 14.0; // sim seconds an approach hold lasts

  /// Ambient locomotion layer — deterministic, zero inference. The LLM
  /// steers interesting choices; this layer keeps the town ALIVE between
  /// decisions (generative-agents style: bodies always doing something).
  final Map<String, List<List<double>>> _walks = {};
  final Map<String, double> _nextWanderAt = {}; // agentId -> sim_ts
  final Map<String, _Arrival> _arrivals = {}; // deferred on-arrival actions

  /// Walks parked while the agent's speech bubble is still on screen —
  /// flushed by tick() once the pin's own expiry passes. `until` is a
  /// snapshot: later lines re-pin `bubbleUntil`, but a parked walk still
  /// releases on schedule (a story beat can't wait for total silence).
  final _deferredWalks =
      <String, ({List<List<double>> pts, _Arrival? onArrive, double until})>{};

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

  /// Player-issued directive retries — a queued order gets up to 6 shots at
  /// a busy target, spaced by [_directiveBackoff] so a long convo doesn't
  /// burn them all in consecutive ticks (and the drop is logged).
  final Map<String, int> _directiveRetries = {};
  final Map<String, double> _directiveBackoff = {};

  /// A player order that found legs — an arrival walk is in flight. If an
  /// outside interruption kills the walk (another spirit pulls them into
  /// a convo, or the living one grabs them), the order re-queues from
  /// here instead of vanishing. Cleared when the arrival actually fires.
  final Map<String, Decision> _directiveWalks = {};

  String _pairKey(String a, String b) => a.compareTo(b) < 0 ? '$a:$b' : '$b:$a';

  SimEngine({
    required this.store,
    required this.llm,
    required this.agents,
    required this.secrets,
    required this.pois,
    NavGrid? nav,
    Random? rng,
    this.timeScale = 1.0,
    this.festivalAt = 900, // 15 sim-minutes
    this.culpritId = 'ramon',
    this.whispers = const [],
  }) : nav = nav ?? NavGrid.build(),
       rng = rng ?? Random() {
    prompts = PromptBuilder(secrets)..cast = _buildCast();
    broker = InferenceBroker(llm, workers: 1);
    broker.decisions.listen(_onDecision);
    broker.turns.listen(_onTurn);
    broker.reflections.listen(_onReflection);
    broker.beats.listen(_applyBeat);
  }

  // ============================ world clock ================================

  /// Set when the world is torn down (Play again / app teardown) — the old
  /// engine goes inert so a surviving pump or pending future can't keep a
  /// ghost simulation writing into the next world's store.
  bool disposed = false;
  void dispose() {
    disposed = true;
    store.dispose();
  }

  void tick(double dt) {
    if (disposed) return;
    _advanceWalks(dt); // real-time locomotion — matches render lerp speed
    for (final a in agents.values) {
      if (a.heldBy != null && simTs >= a.heldUntil) {
        // The hold renews while the chaser still walks — a spirit held
        // for someone who is genuinely on the way waits; one held for a
        // dead walk (diverted, engaged, convo-pulled) is free to go.
        final holder = agents[a.heldBy];
        if (holder != null &&
            (_walks.containsKey(holder.id) ||
                _deferredWalks.containsKey(holder.id))) {
          a.heldUntil = simTs + holdFor;
        } else {
          a.heldBy = null;
        }
      }
    }
    // A spoken bubble pins its speaker — walks issued while the line was
    // on screen were parked, not dropped. Held/engaged/convo'd speakers
    // keep their walk waiting rather than losing it; the force-clear
    // sites (engage, convo start) own true cancellation.
    for (final id in _deferredWalks.keys.toList()) {
      final a = agents[id];
      final d = _deferredWalks[id];
      if (a == null || d == null) {
        _deferredWalks.remove(id);
        continue;
      }
      if (a.engaged || a.inConvo || a.heldBy != null) continue;
      if (simTs < d.until) continue;
      _deferredWalks.remove(id);
      _issuePath(a, d.pts, d.onArrive);
    }
    // Prune dead marches — a marcher with no walk pending is done
    // (arrived, faded, doorstep lost). Free the culprit's doorstep hold
    // too if it points at the dead march, then let the retry refire.
    for (final id in _marchers.toList()) {
      final enRoute =
          _walks.containsKey(id) || _deferredWalks.containsKey(id);
      if (enRoute) continue;
      _marchers.remove(id);
      final c = agents[culpritId];
      if (c?.heldBy == id) c!.heldBy = null;
    }
    _simAcc += dt * timeScale;
    final whole = _simAcc.floor();
    if (whole > 0) {
      simTs += whole;
      _simAcc -= whole;
    }
    // The festival never ends — the resolution card is a report, not a
    // halt. Walks, decisions, convos, and inference run continuously.
    _decisionTimer += dt * timeScale;
    _convoTimer += dt * timeScale;
    _batteryTimer += dt * timeScale;
    _autosaveTimer += dt * timeScale;
    _petalTimer += dt * timeScale;
    _ambientTimer += dt * timeScale;
    _probeTimer += dt; // real seconds — server health isn't a sim concept
    if (_probeTimer >= 8) {
      _probeTimer = 0;
      _probeLlm();
    }
    // staged beats — the confession's second voice lands a beat later
    for (var i = _queuedSays.length - 1; i >= 0; i--) {
      if (simTs >= _queuedSays[i].at) {
        final q = _queuedSays.removeAt(i);
        _say(q.a, q.line, q.mood);
      }
    }
    // The card follows the scene — accusation, confession, witnesses,
    // then the verdict popup (the festival keeps running either way).
    if (_resolutionAt != null && simTs >= _resolutionAt!) {
      _resolutionAt = null;
      _resolution();
    }
    // The staged gather — between visits she resumes when her mark's
    // reply lands; a doorstep fumbled in silence (teller tapped away,
    // poached) must not freeze the scene, so an idle sleuth retries.
    final gacc = _gatherAcc;
    if (gacc != null) {
      if (gacc.faded || gacc.engaged || gacc.inConvo || _caseResolved) {
        _endGather();
      } else if (_gatherResumeAt >= 0 && simTs >= _gatherResumeAt) {
        _gatherResumeAt = -1;
        _gatherNext();
      } else if (_gatherResumeAt < 0 &&
          !_walks.containsKey(gacc.id) &&
          !_deferredWalks.containsKey(gacc.id)) {
        if (++_gatherStall > 30) _gatherNext();
      } else {
        _gatherStall = 0;
      }
    }

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
    // Soft fail: the festival moment arrives with the case still cold —
    // the epilogue names whether a living voice ever tried.
    if (simTs >= festivalAt && !_caseResolved) {
      _whisperDied();
    }
    _tickWhispers();
    _tickCaseCuriosity();
    _maybeConfront();
    _tickNudge();
    if (_batteryTimer >= batteryEvery) {
      _batteryTimer = 0;
      _drainBatteries();
    }
    if (_autosaveTimer >= autosaveEvery) {
      _autosaveTimer = 0;
      _autosave();
    }
    if (_petalTimer >= petalEvery) {
      _petalTimer = 0;
      _events.add(SimEvent(SimEventType.petalSpawn, {}));
    }
  }

  // ============================ conversations ==============================

  void startConversation(
    String aId,
    String bId, {
    String? askedAbout,
    ({String holder, String subject, bool isClaim})? purpose,
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
    // The case: someone came to face the culprit. An established ledger
    // means he breaks instead of talking; below that, a proof in the
    // confronter's hand makes this an accusation — deny, then deflect.
    if (bId == culpritId && !_caseResolved && caseProgress >= 3) {
      _confess(b, accuser: a);
      return;
    }
    // A marcher only talks to the culprit — anything else waits until the
    // charge lands or dies. Ambient pair-ups fail quietly and retry later.
    if ((_marchers.contains(aId) && bId != culpritId) ||
        (_marchers.contains(bId) && aId != culpritId)) {
      return;
    }
    final convo = Conversation(
      'c${simTs}_${aId}_$bId',
      aId,
      bId,
      askedAbout: askedAbout,
      purpose: purpose,
    );
    convo.deny =
        bId == culpritId &&
        a.knownSecrets.any((sid) => secrets[sid]?.proofFor == culpritId);
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
    _deferredWalks.remove(aId);
    _deferredWalks.remove(bId);
    _arrivals.remove(aId);
    _arrivals.remove(bId);
    // sim and renderer are separate walkers — clear the components'
    // residual paths too, or a pulled-in spirit keeps lerping mid-popup
    _stopVisual(a);
    _stopVisual(b);
    // A convo just stole their legs — if either was carrying out the
    // living one's order, queue it back so it survives the small talk.
    for (final id in [aId, bId]) {
      final lost = _directiveWalks.remove(id);
      if (lost != null) _pendingApproach[id] = lost;
    }
    _releaseSlot(aId);
    _releaseSlot(bId);
    a.heldBy = b.heldBy = null;
    a.inConvo = b.inConvo = true;
    a.bumpVersion();
    b.bumpVersion();
    // face each other
    _emit(a, SimEventType.state, {
      'agent': aId,
      'fx': (b.x - a.x).sign,
      'fy': (b.y - a.y).sign,
    });
    _emit(b, SimEventType.state, {
      'agent': bId,
      'fx': (a.x - b.x).sign,
      'fy': (a.y - b.y).sign,
    });
    _events.add(
      SimEvent(SimEventType.pairStart, {
        'a': aId,
        'b': bId,
        'purpose': purpose != null,
      }),
    );
    // The call lands — the callee's small authored ack shows they heard
    // it while the model composes the real first line.
    _say(b, _ackFor(b), 'neutral');
    _requestTurn(convo);
  }

  /// The called spirit's first reaction — persona-shaped, instant, and
  /// deterministic so the call always visibly lands.
  static const _acks = <String, String>{
    'luz': 'mm? tell me.',
    'bruno': '…what is it?',
    'sefa': "I'm listening.",
    'ramon': 'ah — speak, friend.',
    'ines': 'go on, mijo.',
    'solorio': '…you see me?',
    'violeta': 'ooh — what?',
    'aurelio': 'speak.',
    'carmen': '…yes?',
  };
  String _ackFor(Agent a) => _acks[a.id] ?? 'mm?';

  void _advanceConversations() {
    final finished = <Conversation>[];
    for (final c in conversations.values) {
      if (c.done) {
        if (c.releaseAt == null) {
          // The words are out — bookkeeping lands now even though the
          // pair lingers for the last bubble's real-time life (~3.6s).
          // Bubbles live in real seconds, the sweep in sim seconds —
          // scale by timeScale so 8× doesn't release mid-sentence.
          c.releaseAt =
              simTs + ((kBubbleLifeSay + 0.4) * timeScale).ceil();
          _endConversation(c);
        }
        if (simTs >= c.releaseAt!) finished.add(c);
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
    }
  }

  // End-of-convo consequences — run once, when the last turn lands.
  // The pair itself stays parked until releaseAt (the linger above).
  void _endConversation(Conversation c) {
    final a = agents[c.aId]!, b = agents[c.bId]!;
    // relationships — every completed convo warms the pair a little
    a.warmth[b.id] = (a.warmth[b.id] ?? 0) + 2;
    b.warmth[a.id] = (b.warmth[a.id] ?? 0) + 2;
    unawaited(store.setWorld('warmth.${a.id}', jsonEncode(a.warmth)));
    unawaited(store.setWorld('warmth.${b.id}', jsonEncode(b.warmth)));
    _events.add(SimEvent(SimEventType.pairEnd, {'a': c.aId, 'b': c.bId}));
    // Cornered but not caught — the culprit answers an accusation by
    // planting a fresh lie in the accuser's ear. Deterministic: the
    // lie is an authored accusation secret, never invented on the fly.
    if (c.deny) {
      final confronter = agents[c.aId]!;
      final lie = secrets.values
          .where(
            (s) =>
                s.accuses != null &&
                !confronter.knownSecrets.contains(s.id),
          )
          .firstOrNull;
      if (lie != null) {
        confronter.knownSecrets.add(lie.id);
        confronter.bumpVersion();
        unawaited(
          store.simLog(
            simTs,
            c.bId,
            'counter-accuse',
            '${lie.id} -> ${confronter.id}',
          ),
        );
      }
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
      context:
          'near ${nearestPoiName(speaker.x, speaker.y)}'
          '${c.deny && speaker.id == culpritId ? ' — cornered about the stolen portrait: DENY it, stay in voice, deflect onto someone else' : ''}',
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
                ? (p.isClaim
                      ? claims[p.subject]?.heardBy(speaker.id)
                      : secrets[p.subject]?.shareText)
                : (p.isClaim
                      ? 'a rumor going around'
                      : secrets[p.subject]?.surface)),
      rumors: _heldRumors(speaker),
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
    // pendingJob stays true through the whole commit — clearing it at entry
    // let the scheduler enqueue the next turn while this one still awaited
    // sqlite, and two racing turns both passed the version guard → the same
    // rumor logged 4× at one sim_ts. Dead convos are swept regardless.
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
    // Echo detection: a repeated line still commits (a purpose-bound share
    // must not be lost to model degeneration) but flags the convo to end.
    final norm = line.toLowerCase().replaceAll(RegExp(r'[^a-z0-9 ]'), '');
    final echo = !c.linesSeen.add(norm);

    // Commit rule: a secret moves ONLY if the speaker owns it AND the
    // partner doesn't already know it. Two paths:
    //  1. purpose-bound convo — the holder speaks, engine transfers its
    //     declared secret; the model's flag is unnecessary.
    //  2. organic convo — the model volunteers shares_secret, validated
    //     the same way.
    String? shared;
    String? sharedClaim;
    final p = c.purpose;
    if (p != null &&
        speaker.id == p.holder &&
        !p.isClaim &&
        speaker.knownSecrets.contains(p.subject) &&
        !partner.knownSecrets.contains(p.subject) &&
        _canShareRumor(speaker, partner, secrets[p.subject])) {
      shared = p.subject;
    } else if (p != null &&
        speaker.id == p.holder &&
        p.isClaim &&
        claims[p.subject]?.version.containsKey(speaker.id) == true &&
        claims[p.subject]!.version.containsKey(partner.id) != true &&
        _canPassClaim(speaker, partner, claims[p.subject]!)) {
      sharedClaim = p.subject;
    } else if (turn.sharesSecret != null &&
        turn.sharesSecret != 'null' &&
        speaker.knownSecrets.contains(turn.sharesSecret) &&
        !partner.knownSecrets.contains(turn.sharesSecret) &&
        secrets.containsKey(turn.sharesSecret) &&
        _canShareRumor(speaker, partner, secrets[turn.sharesSecret])) {
      // A mischievous teller embellishes — the variant commits, not the
      // truth they know.
      shared = _distorted(speaker, partner, turn.sharesSecret!);
    } else if (turn.sharesSecret != null &&
        claims[turn.sharesSecret] != null &&
        claims[turn.sharesSecret]!.version.containsKey(speaker.id) &&
        claims[turn.sharesSecret]!.version.containsKey(partner.id) != true &&
        _canPassClaim(speaker, partner, claims[turn.sharesSecret]!)) {
      sharedClaim = turn.sharesSecret;
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
        // …and leaves a 💡 over their head so the player can spot news
        partner.newsUntil = simTs + 90;
        _emit(partner, SimEventType.emote, {
          'agent': partner.id,
          'glyph': '💡',
        });
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
    // A player-planted rumor changes mouths — telephone rules: the receiver
    // carries the version the speaker HEARD (which may already be twisted).
    // The claim ledger never touches secrets, POI lore, or the verdict.
    if (sharedClaim != null &&
        !claims[sharedClaim]!.version.containsKey(partner.id)) {
      final cl = claims[sharedClaim]!;
      final heard = cl.heardBy(speaker.id);
      cl.version[partner.id] = heard;
      partner.newsUntil = simTs + 90; // the 💡 cue — fresh gossip to follow
      _emit(partner, SimEventType.emote, {'agent': partner.id, 'glyph': '💡'});
      partner.bumpVersion();
      // A relayed proof carries its canonical secret into every new
      // mouth — the living one's whisper becomes real evidence.
      final gs = cl.grantsSecret;
      if (gs != null &&
          !partner.knownSecrets.contains(gs) &&
          secrets.containsKey(gs)) {
        partner.knownSecrets.add(gs);
        unawaited(
          store.simLog(simTs, partner.id, 'proof', '$gs via claim $sharedClaim'),
        );
      }
      final aboutYou = cl.about.contains(partner.id);
      unawaited(
        store.simLog(
          simTs,
          partner.id,
          'rumor',
          '$sharedClaim via ${speaker.id}${aboutYou ? ' (about them)' : ''}',
        ),
      );
      await store.memory(
        Memory(
          agent: partner.id,
          simTs: simTs,
          kind: 'heard',
          source: 'spirit:${speaker.id}',
          text: aboutYou
              ? 'the rumor going around is about ME: $heard'
              : 'rumor from ${speaker.name}: $heard',
          importance: aboutYou ? 8 : 6,
          entities: [speaker.id, sharedClaim],
        ),
      );
      if (aboutYou) {
        // hearing your own name in a stranger's mouth — a jolt
        partner.mood = 'shaken';
        _emit(partner, SimEventType.emote, {'agent': partner.id, 'glyph': '!'});
      }
      _persistClaims();
      _events.add(
        SimEvent(SimEventType.log, {
          'text': '${speaker.name} passes a rumor to ${partner.name}: $heard',
        }),
      );
    }
    // Batteries: social contact recharges; passing real knowledge is the
    // deepest connection the sim knows.
    if (shared != null || sharedClaim != null) {
      speaker.battery = min(100, speaker.battery + 10);
      partner.battery = min(100, partner.battery + 12);
    } else {
      speaker.battery = min(100, speaker.battery + 4);
      partner.battery = min(100, partner.battery + 6);
    }

    _emit(speaker, SimEventType.say, {
      'agent': speaker.id,
      'line': line,
      'mood': turn.mood,
    });

    // Next speaker / done. Purpose convos get two extra turns so the
    // listener can react after the knowledge lands — and 'end' is honored
    // only once the holder has actually had a turn (B9).
    if (p != null && speaker.id == p.holder) c.holderSpoke = true;
    c.nextSpeaker = partner.id;
    if ((turn.end && (p == null || c.holderSpoke)) ||
        echo ||
        c.transcript.length >= (c.purpose != null ? 8 : 6)) {
      c.done = true;
    }
    // The slot opens only once the commit is fully landed — the next turn
    // is enqueued on a following tick, after nextSpeaker/version are final.
    c.pendingJob = false;
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
    // A deferred approach is a committed intent — it consumes the slot
    // regardless of the decision cache cooldown.
    final Agent agent;
    final pendingIds = _pendingApproach.keys.where((id) {
      final a = agents[id];
      return a != null &&
          !a.engaged &&
          !a.inConvo &&
          a.heldBy == null &&
          simTs >= (_directiveBackoff[id] ?? 0);
    });
    if (pendingIds.isNotEmpty) {
      agent = agents[pendingIds.first]!;
    } else {
      // Decision cache — an agent that acted within ~30 sim-s keeps its
      // plan; re-prompting that fast just burns tokens re-deciding walks.
      final free = agents.values
          .where(
            (a) =>
                !a.engaged &&
                !a.inConvo &&
                a.heldBy == null &&
                simTs - a.lastActedAt >= 30,
          )
          .toList();
      if (free.isEmpty) return;
      free.sort((a, b) => a.lastActedAt.compareTo(b.lastActedAt));
      agent = free.first;
    }
    agent.lastActedAt = simTs.toDouble();

    // The agent already chose; conditions just needed to clear. Ambient
    // intents get one shot (no stalker loop); player-issued orders get a
    // bounded retry — a dropped directive reads as "they ignored me".
    final pending = _pendingApproach.remove(agent.id);
    if (pending != null) {
      _directiveBackoff.remove(agent.id);
      _execute(agent, pending, canDefer: false);
      // Success = an arrival walk or a convo in flight; anything else means
      // the target was busy and the intent fell to _fallbackStroll.
      final inFlight = _arrivals.containsKey(agent.id) ||
          agent.inConvo ||
          _pendingApproach.containsKey(agent.id);
      final isOrder = pending.thought == 'the living one sent me';
      if (!inFlight && isOrder) {
        // Busy target — re-try on an 8-sim-s backoff so a long convo
        // doesn't eat all three retries inside three ticks.
        final tries = (_directiveRetries[agent.id] ?? 0) + 1;
        if (tries <= 6) {
          _directiveRetries[agent.id] = tries;
          _directiveBackoff[agent.id] = simTs + 8;
          _pendingApproach[agent.id] = pending;
          unawaited(
            store.simLog(
              simTs,
              agent.id,
              'directive',
              'retry $tries — ${pending.target} busy',
            ),
          );
        } else {
          _directiveRetries.remove(agent.id);
          unawaited(
            store.simLog(
              simTs,
              agent.id,
              'directive',
              'dropped — ${pending.target} stayed busy',
            ),
          );
        }
      } else {
        _directiveRetries.remove(agent.id);
        // A real walk in flight — track it: if an outside convo (or the
        // living one grabbing them) kills the legs, the order re-queues
        // instead of vanishing.
        if (isOrder && _arrivals.containsKey(agent.id)) {
          _directiveWalks[agent.id] = pending;
        }
      }
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
      // Rumor-tier secrets only appear where the persona would tell:
      // gossips leak (mischief), warm souls confide (bonds), and nobody
      // confesses their own scandal to a stranger.
      // Player-planted rumors lead the menu — the scandal du jour beats
      // old lore. Same mouth-to-ear machinery, looser gate: gossip travels
      // easier than confession.
      var claimOffers = 0;
      for (final cl in claims.values) {
        if (cl.version.containsKey(agent.id) &&
            !cl.version.containsKey(other.id) &&
            _canPassClaim(agent, other, cl)) {
          allowed.add('share(${other.id},${cl.id})');
          claimOffers++;
        }
      }
      final shareable = agent.knownSecrets
          .difference(other.knownSecrets)
          .where((sid) => _canShareRumor(agent, other, secrets[sid]))
          .toList();
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
      if (sinceTalk > pairCooldown) {
        allowed.add('greet(${other.id})');
        if (agent.stats.grump >= 4 || (shareable.isEmpty && claimOffers == 0)) {
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

    // Curiosity bias — while knowledge could actually move between two
    // nearby spirits, idling/drifting isn't on the menu. The spirit
    // engages, visits a POI, or pursues its errand.
    if (allowed.any((x) => x.startsWith('share(') || x.startsWith('ask('))) {
      allowed
        ..remove('idle')
        ..remove('stroll');
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
      rumors: _heldRumors(agent),
    );
    broker.push(JobKind.decision, agent.id, prompt, agent.stateVersion);
    _refreshMemories(agent);
    unawaited(_refreshReflection(agent));
  }

  final Map<String, String?> _reflCache = {};
  Future<void> _refreshReflection(Agent a) async {
    _reflCache[a.id] = await store.latestReflection(a.id);
  }

  /// Any LLM work in flight — decision jobs, convo turns, reflections,
  /// director beats, or the player's own chat stream. The HUD pulses
  /// beside the model badge while this is true.
  bool get aiBusy => broker.inFlight > 0 || _playerBusy;

  /// Ping the model server (Ollama only) — flips [llmAlive] so the HUD can
  /// show "offline" instead of spirits going mute for no visible reason.
  Future<void> _probeLlm() async {
    final c = llm;
    if (c is OllamaClient) {
      llmAlive = await c.probe();
    } else if (c is FailoverLLMClient) {
      llmAlive = await c.probe();
    } else {
      llmAlive = true;
    }
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
        a.errand = (
          kind: 'seek',
          targetId: closest.id,
          claim: false,
          subject: null,
        );
        return;
      }
    }
    // 0b. rescue — a fading spirit whose wake-name I hold outranks any
    // routine. Checked before the stale-errand early-return so learning
    // the name mid-festival immediately turns the holder toward them.
    for (final f in agents.values) {
      if (!f.faded || f.id == a.id) continue;
      if (a.knownSecrets.any((s) => secrets[s]?.wakesAgent == f.id)) {
        if (a.errand?.kind != 'seek' || a.errand?.targetId != f.id) {
          a.errand = (
            kind: 'seek',
            targetId: f.id,
            claim: false,
            subject: null,
          );
        }
        return;
      }
    }

    final e = a.errand;
    if (e != null) {
      // staleness — the reason evaporated
      if (e.kind == 'verify' && a.verifiedPois.contains(e.targetId)) {
        a.errand = null;
      } else if (e.kind == 'tell' && e.subject != null) {
        // carrying the living one's words to a named ear — stale when the
        // rumor's gone, reached them already, or slipped from my mouth
        final t = agents[e.targetId];
        final cl = claims[e.subject];
        if (t == null ||
            t.faded ||
            cl == null ||
            !cl.version.containsKey(a.id) ||
            cl.version.containsKey(t.id)) {
          a.errand = null;
        }
      } else if (e.kind == 'tell' || e.kind == 'seek') {
        final t = agents[e.targetId];
        if (t == null ||
            t.faded ||
            (e.kind == 'tell' &&
                a.knownSecrets
                    .difference(t.knownSecrets)
                    .where((sid) => _canShareRumor(a, t, secrets[sid]))
                    .isEmpty &&
                !claims.values.any(
                  (cl) =>
                      cl.version.containsKey(a.id) &&
                      !cl.version.containsKey(t.id) &&
                      _canPassClaim(a, t, cl),
                )) ||
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
        a.errand = (
          kind: 'verify',
          targetId: poiId,
          claim: false,
          subject: null,
        );
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
      final n = a.knownSecrets
          .difference(o.knownSecrets)
          .where((sid) => _canShareRumor(a, o, secrets[sid]))
          .length;
      if (n == 0) continue;
      final score =
          n -
          sqrt(_dist2(a.x, a.y, o.x, o.y)) / (8 * kTile) +
          (a.warmth[o.id] ?? 0) / 10.0;
      if (score > bestScore) {
        bestScore = score;
        bestT = o;
      }
    }
    if (bestT != null) {
      a.errand = (
        kind: 'tell',
        targetId: bestT.id,
        claim: false,
        subject: null,
      );
      return;
    }
    // 3. gathering — a director-triggered beat, or the scheduled ofrenda
    // moment late in the festival. Fires whether or not the player attends
    // (the Majora's Mask rule).
    if (simTs < _gatherUntil) {
      a.errand = (
        kind: 'tend',
        targetId: _gatherPoi,
        claim: false,
        subject: null,
      );
      return;
    }
    if (simTs >= festivalAt * 0.6) {
      a.errand = (
        kind: 'tend',
        targetId: 'ofrenda',
        claim: false,
        subject: null,
      );
      return;
    }
    // 4. schedule — the persona's authored routine for this hour
    // festival; falls back to their home patch.
    var schedPoi = a.home;
    for (final s in a.schedule) {
      if (simTs >= s.at) schedPoi = s.poi;
    }
    if (pois.containsKey(schedPoi)) {
      a.errand = (
        kind: 'tend',
        targetId: schedPoi,
        claim: false,
        subject: null,
      );
    }
  }

  String? _describeErrand(Agent a) {
    final e = a.errand;
    if (e == null) return null;
    return switch (e.kind) {
      'verify' =>
        'you heard something about ${pois[e.targetId]?.name ?? e.targetId} — go see for yourself',
      'tell' =>
        e.subject != null
            ? 'the living one\'s words burn in you — carry them to ${agents[e.targetId]?.name ?? e.targetId}'
            : 'you carry news ${agents[e.targetId]?.name ?? e.targetId} hasn\'t heard — find them',
      'seek' =>
        _pendingApproach[a.id]?.thought == 'the living one sent me'
            ? 'the living one asked you to reach ${agents[e.targetId]?.name ?? e.targetId} — go'
            : agents[e.targetId]?.faded == true
            ? '${agents[e.targetId]!.name} is fading and you hold their name — reach them'
            : 'you feel dim — find company before you fade away',
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

  /// The festival's headline rumor and its spread, so the storyteller paces
  /// around the authored arc instead of improvising over it.
  String _headlineDigest() {
    final rumor = secrets.values.where((s) => s.tier == 'rumor');
    if (rumor.isEmpty) return '';
    final line = rumor
        .map(
          (s) =>
              '${s.id}: ${agents.values.where((a) => a.knownSecrets.contains(s.id)).length}/${agents.length}',
        )
        .join(', ');
    return 'Headline rumor — the ofrenda scandal: $line\n';
  }

  /// The authored consequence — deterministic, never LLM. The La
  /// Golondrina case closes by PROOF, not by spread: when three distinct
  /// proofs naming the culprit are each held by ≥2 different spirits,
  /// the next spirit to confront him hears a confession. Confidences
  /// (`private`) never count until the living one carries them into
  /// circulation — the village can suspect; only the player completes
  /// the ledger.
  bool _caseResolved = false;
  String? _caseNote; // surfaced in the resolution card (endRun event)

  /// Proof ids the living one personally carried into the world — the
  /// flag that makes a confidence admissible as evidence.
  final _relayedSecrets = <String>{};

  /// Proof ids that leaked on their own — a mutter overheard, a
  /// confidence the holder couldn't keep. Same effect as a player
  /// relay; the living one speeds this up but isn't required.
  final _leakedSecrets = <String>{};

  /// The town's accuser — last sim_ts a march was dispatched. Retried on
  /// a spacing until someone actually lands the confrontation.
  int _confrontAt = -999;

  /// Distinct established proofs fingering [culpritId]: each held by ≥2
  /// non-culprit mouths (one mouth is just a rumor) and — for private
  /// confidences — relayed by the player first.
  int get caseProgress {
    var n = 0;
    for (final s in secrets.values) {
      if (s.proofFor != culpritId) continue;
      if (s.private &&
          !_relayedSecrets.contains(s.id) &&
          !_leakedSecrets.contains(s.id)) {
        continue;
      }
      final holders = agents.values
          .where((a) => a.id != culpritId && a.knownSecrets.contains(s.id))
          .length;
      if (holders >= 2) n++;
    }
    return n;
  }

  bool get caseResolved => _caseResolved;

  /// The thief breaks — an established ledger plus a voice in his face.
  /// Deterministic: the LLM gets no vote on whether the proof held. The
  /// confession is authored, not generated — accusation, then his own
  /// words a beat later, so the reveal reads cleanly on camera.
  void _confess(Agent culprit, {Agent? accuser}) {
    _caseResolved = true;
    final name = culprit.name.split(' ').first;
    if (accuser != null) {
      _say(
        accuser,
        'It was you, $name — the pick beneath her frame, the wax on your sleeve.',
        'certain',
      );
    }
    _queuedSays.add((
      a: culprit,
      line: '…I only wanted them to remember my voice.',
      mood: 'broken',
      at: simTs + 3,
    ));
    // The why, said out loud — the scene carries the motive, not just
    // the card: her light outshone his, and Bruno took the blame.
    if (accuser != null) {
      _queuedSays.add((
        a: accuser,
        line: 'Her light grew — yours dimmed. And you let us blame Bruno.',
        mood: 'certain',
        at: simTs + 6,
      ));
    }
    // The town heard it too — the two nearest spirits gasp a beat after
    // his words, so the reveal plays as a scene, not a silent card.
    final witnesses = agents.values
        .where(
          (o) => o.id != culpritId && o.id != accuser?.id && !o.faded,
        )
        .toList()
      ..sort(
        (x, y) => _dist2(
          x.x,
          x.y,
          culprit.x,
          culprit.y,
        ).compareTo(_dist2(y.x, y.y, culprit.x, culprit.y)),
      );
    const gasps = [
      'Ramón… all this time.',
      'Her candle — he stole her candle.',
    ];
    for (var i = 0; i < gasps.length && i < witnesses.length; i++) {
      _queuedSays.add((
        a: witnesses[i],
        line: gasps[i],
        mood: 'shaken',
        at: simTs + 8 + i * 2,
      ));
    }
    final text =
        '$name stole La Golondrina\'s portrait and pointed the town at '
        'Bruno — her candle burned brighter every year while his name dimmed.';
    _note(text);
    _caseNote = text;
    _emit(culprit, SimEventType.thought, {
      'agent': culprit.id,
      'text': 'they know. they all know — it was me.',
    });
    _events.add(
      SimEvent(SimEventType.verdict, {
        'culprit': culpritId,
        'passed': true,
        'text': text,
        // Where the camera should look — the confession IS the ending
        // scene, so the game zooms into the confrontation.
        'x': culprit.x,
        'y': culprit.y,
      }),
    );
    _events.add(SimEvent(SimEventType.poiGlow, {'poi': 'ofrenda', 'on': true}));
    // The card waits for the scene to breathe — accusation, confession,
    // the why, the witnesses — instead of slamming over the dialogue.
    _resolutionAt = simTs + 12;
    _marchers.clear();
  }

  /// Staged beats — authored speech queued for a sim-second. Used for
  /// the confession exchange so lines land in order instead of at once.
  final _queuedSays = <({Agent a, String line, String mood, int at})>[];

  /// The resolution card's cue — set when the confession scene starts so
  /// the popup lands after the dialogue, not on top of it.
  int? _resolutionAt;

  /// DRIVER-ONLY director cut — stages the evidence-gathering so the
  /// march is earned on camera: the sleuth walks to the witnesses,
  /// hears their statements aloud, collects the proofs one by one —
  /// THEN the ledger fills and the confrontation launches the usual
  /// way. "She just knew" never appears in the footage.
  String directorSolve() {
    if (_caseResolved) return 'already resolved';
    if (_gatherAcc != null) return 'the gathering is already walking';
    final acc = agents['luz']; // the town's natural sleuth
    if (acc == null || acc.faded || acc.engaged || acc.inConvo) {
      _seedLedger();
      _maybeConfront();
      return 'accuser unavailable — ledger seeded; caseProgress=$caseProgress';
    }
    // (witness, the proof she swears, her statement, the sleuth's reply)
    const interviews = [
      (
        'sefa',
        'wax_on_sleeve',
        'melted candle wax — on HIS sleeve. i saw it with my own eyes.',
        'wax that should not be there. one piece of the night.',
      ),
      (
        'solorio',
        'humming_heard',
        'someone was humming her tune by the frames… i swear it.',
        'her song on another\'s lips. thank you, old friend.',
      ),
      (
        'ines',
        'guitar_pick',
        'a guitar pick beneath her frame — his initials on the back.',
        'the strings remember who played that night.',
      ),
    ];
    _gatherQ.clear();
    for (final iv in interviews) {
      final t = agents[iv.$1];
      if (t == null || t.faded || t.id == culpritId) continue;
      _gatherQ.add((
        tellerId: iv.$1,
        secretId: iv.$2,
        tellerLine: iv.$3,
        accLine: iv.$4,
      ));
      if (_gatherQ.length == 2) break;
    }
    if (_gatherQ.isEmpty) {
      _seedLedger();
      _maybeConfront();
      return 'no witnesses left — ledger seeded; caseProgress=$caseProgress';
    }
    _gatherAcc = acc;
    _marchers.add(acc.id); // staged — as unpoachable as the charge itself
    _emit(acc, SimEventType.emote, {'agent': acc.id, 'glyph': '🕯'});
    _say(acc, 'The pieces are out there. Time to gather them.', 'certain');
    unawaited(
      store.simLog(simTs, acc.id, 'case', 'begins gathering the ledger'),
    );
    final n = _gatherQ.length;
    _gatherNext();
    return 'gathering staged — ${acc.name} collects $n statements';
  }

  /// Plants the full ledger instantly — used when the staged gathering
  /// can't run (sleuth gone, no witnesses). The film path's fallback.
  void _seedLedger() {
    const seed = {
      'guitar_pick': ['ines', 'violeta', 'sefa'],
      'wax_on_sleeve': ['sefa', 'carmen'],
      'silver_flash': ['luz', 'violeta'],
      'frame_crack_slip': ['aurelio', 'ines'],
      'humming_heard': ['violeta', 'luz'],
    };
    for (final e in seed.entries) {
      for (final id in e.value) {
        final a = agents[id];
        if (a == null || a.faded || a.id == culpritId) continue;
        a.knownSecrets.add(e.key);
        a.bumpVersion();
      }
      // private proofs count only once they leak — the director's cut
      // says they leaked off-camera.
      _relayedSecrets.add(e.key);
      _leakedSecrets.add(e.key);
    }
  }

  /// The staged walk — the sleuth visiting witnesses one by one.
  /// [_gatherAcc] rides in [_marchers] so ambient gossip can't poach
  /// her mid-scene; [_gatherTeller] is the one doorway she's allowed.
  Agent? _gatherAcc;
  Agent? _gatherTeller;
  final _gatherQ =
      <({String tellerId, String secretId, String tellerLine, String accLine})>[];
  int _gatherResumeAt = -1;
  int _gatherStall = 0;

  void _gatherNext() {
    final acc = _gatherAcc;
    if (acc == null || acc.faded) {
      _endGather();
      return;
    }
    if (_gatherQ.isEmpty) {
      _endGather();
      return;
    }
    final iv = _gatherQ.removeAt(0);
    final teller = agents[iv.tellerId];
    if (teller == null || teller.faded) {
      _gatherNext();
      return;
    }
    _gatherTeller = teller;
    unawaited(
      store.simLog(simTs, acc.id, 'case', 'goes to hear ${teller.id}'),
    );
    _approachForConvo(
      acc,
      teller,
      onNear: (ag, tt) {
        // The statement lands, the sleuth marks it — proof in hand and
        // on camera, one exchange per witness.
        _say(tt, iv.tellerLine, 'earnest');
        _queuedSays.add((
          a: ag,
          line: iv.accLine,
          mood: 'certain',
          at: simTs + 3,
        ));
        if (!ag.knownSecrets.contains(iv.secretId)) {
          ag.knownSecrets.add(iv.secretId);
          ag.bumpVersion();
          _emit(ag, SimEventType.emote, {'agent': ag.id, 'glyph': '💡'});
          unawaited(
            store.simLog(
              simTs,
              ag.id,
              'proof',
              '${iv.secretId} sworn by ${tt.id}',
            ),
          );
        }
        _gatherResumeAt = simTs + 6;
      },
      onFail: (_) => _gatherNext(), // witness unreachable — try the next
    );
  }

  void _endGather() {
    _marchers.remove(_gatherAcc?.id ?? '');
    _gatherAcc = null;
    _gatherTeller = null;
    _gatherQ.clear();
    _gatherResumeAt = -1;
    _seedLedger();
    // The ledger is full — the announced march to the culprit launches
    // on this tick, the same as an organically-solved case.
    _maybeConfront();
  }

  /// Soft fail — the festival's moment passed with the case still cold.
  /// The epilogue names why: no living voice carried the whispers.
  void _whisperDied() {
    _caseResolved = true;
    final text = lastPlayerMsgTs < 0
        ? 'The whisper died in the dark — no living voice ever carried it.'
        : 'The whisper died in the dark — the proofs never met.';
    _note(text);
    _caseNote = text;
    _events.add(
      SimEvent(SimEventType.verdict, {
        'culprit': culpritId,
        'passed': false,
        'text': text,
      }),
    );
    _resolution();
  }

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
    return 'Town (t=${_clock()}):\n$parts\n'
        'Secrets spreading: $know\n'
        '${_headlineDigest()}'
        'Hooks: $hooks\n'
        'Recent: ${_recentNotes.isEmpty ? 'the night is still young' : _recentNotes.join('; ')}';
  }

  void _applyBeat(Map<String, dynamic>? beat) {
    if (beat == null) return;
    final kind = beat['beat']?.toString();
    final agent = _fuzzyId(beat['agent']?.toString(), agents.keys.toSet());
    final agent2 = _fuzzyId(beat['agent2']?.toString(), agents.keys.toSet());
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
            (x, y) => _dist2(
              x.x,
              x.y,
              p.x,
              p.y,
            ).compareTo(_dist2(y.x, y.y, p.x, p.y)),
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
      case 'leak':
        // The storyteller nudges a rumor along: holder → receiver, but only
        // through the normal channels — engine validates a legal shareable
        // secret exists, then schedules the tell errand.
        final h = agent == null ? null : agents[agent];
        final r = agent2 == null ? null : agents[agent2];
        if (h == null ||
            r == null ||
            h.faded ||
            r.faded ||
            h.engaged ||
            r.engaged) {
          return;
        }
        if (h.knownSecrets
            .difference(r.knownSecrets)
            .where((sid) => _canShareRumor(h, r, secrets[sid]))
            .isEmpty) {
          return;
        }
        h.errand = (kind: 'tell', targetId: r.id, claim: false, subject: null);
        _note('${h.name} has something to tell ${r.name}…');
        landed = true;
      case 'curiosity_spike':
        if (agent == null || poi == null) return;
        final a = agents[agent]!;
        if (!a.faded && !a.verifiedPois.contains(poi)) {
          a.errand = (
            kind: 'verify',
            targetId: poi,
            claim: false,
            subject: null,
          );
          _note('${a.name} can\'t stop thinking about ${pois[poi]!.name}');
          landed = true;
        }
      default:
        return; // 'none' or anything unrecognized — the festival breathes
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
    // Stale check — drop if the agent's state moved on. Marchers and the
    // staged gather's sleuth answer only to the case, never to a fresh
    // decide that would retask their legs mid-scene.
    if (job.stateVersion != a.stateVersion ||
        a.engaged ||
        a.inConvo ||
        _marchers.contains(a.id) ||
        a.id == _gatherAcc?.id) {
      return;
    }
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
    // dispatch so intent survives a misspelling. Claims are legal subjects
    // too — share(x, claim_N) is how planted rumors travel.
    final allIds = {...agents.keys, ...pois.keys};
    target = _fuzzyId(target, allIds);
    subject = _fuzzyId(subject, {...allIds, ...secrets.keys, ...claims.keys});
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
    // inZOI's trick — the inner voice floats briefly over the head; the
    // cheapest believability in the genre.
    final th = d.thought;
    if (th != null && th.isNotEmpty) {
      _events.add(SimEvent(SimEventType.thought, {'agent': a.id, 'text': th}));
    }
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
            // Recompute at arrival — knowledge sets can shift mid-walk.
            var sid = subject;
            ({String holder, String subject, bool isClaim})? purp;
            if (sid != null && claims.containsKey(sid)) {
              // a player-planted rumor — valid only while the teller still
              // holds a version the partner lacks
              final cl = claims[sid]!;
              if (cl.version.containsKey(ag.id) &&
                  !cl.version.containsKey(tt.id) &&
                  _canPassClaim(ag, tt, cl)) {
                purp = (holder: ag.id, subject: sid, isClaim: true);
              }
            } else {
              if (sid == null ||
                  !ag.knownSecrets.contains(sid) ||
                  tt.knownSecrets.contains(sid)) {
                final diff = ag.knownSecrets.difference(tt.knownSecrets);
                sid = diff.isEmpty ? null : diff.first;
              }
              if (sid != null) sid = _distorted(ag, tt, sid);
              if (sid != null) {
                purp = (holder: ag.id, subject: sid, isClaim: false);
              }
            }
            startConversation(ag.id, tt.id, purpose: purp);
          },
          order: d.thought == 'the living one sent me' ? d : null,
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
            // The ask is ABOUT something — the living one's seeded claim
            // (subject) or a held askAbout goal. Interrogate on topic:
            // prefer a secret that answers the question, fall back to
            // whatever they hold. Without this the convo recites an
            // arbitrary secret while the named topic goes ignored.
            final aboutClaim = claims[subject];
            final aboutGoal = ag.goal?.startsWith('askAbout:') == true
                ? ag.goal!.split(':').last
                : null;
            final askedAbout = aboutClaim != null
                ? aboutClaim.heardBy(ag.id)
                : aboutGoal;
            final diff = tt.knownSecrets.difference(ag.knownSecrets);
            String? sid;
            if (aboutGoal != null) {
              for (final s in diff) {
                final sec = secrets[s];
                if (sec != null &&
                    (sec.unlocksPoiLore == aboutGoal ||
                        sec.aboutAgent == aboutGoal)) {
                  sid = s;
                  break;
                }
              }
            }
            sid ??= diff.isEmpty ? null : diff.first;
            if (sid != null) sid = _distorted(tt, ag, sid);
            startConversation(
              ag.id,
              tt.id,
              askedAbout: askedAbout,
              purpose: sid == null
                  ? null
                  : (holder: tt.id, subject: sid, isClaim: false),
            );
            if (askedAbout != null) {
              _emit(ag, SimEventType.emote, {'agent': ag.id, 'glyph': '❓'});
            }
            if (aboutGoal != null) ag.goal = null; // the question was asked
          },
          order: d.thought == 'the living one sent me' ? d : null,
        );
        return;
      case 'seek':
        // walk to the errand's person — the talk happens on a later
        // decision. A faded spirit is approachable when we carry their
        // wake-name (the rescue-seek errand).
        final t = agents[target];
        final canWake =
            t != null &&
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
              _sayOrNote(ag, d.line, d.mood); // the flavor they meant to mutter
              _arrivalMusing(
                ag,
                p,
                errandHere: ag.errand?.targetId == p.id,
              );
              if (ag.errand?.targetId == p.id) {
                // arriving IS seeing — the verify errand is satisfied
                final wasClaim = ag.errand?.claim == true;
                ag.verifiedPois.add(p.id);
                ag.errand = null;
                unawaited(
                  store.memory(
                    Memory(
                      agent: ag.id,
                      simTs: e.simTs,
                      kind: 'observation',
                      source: 'self',
                      text: wasClaim
                          ? 'went to see ${p.name} — the living one\'s words echo'
                          : 'went to see ${p.name} — the rumor was true',
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

  /// The first spirit to reach the bare altar says it out loud — the
  /// discovery beat the intro promised. Everyone after them reacts to a
  /// fact already known: the frame is still empty.
  bool _ofrendaAnnounced = false;

  /// Standing at a POI → observe it. Curiosity payoff → goal to ask around.
  _Arrival _doInspect(Poi p, String line) => (e, a) {
    if (p.id == 'ofrenda') {
      if (!_ofrendaAnnounced) {
        _ofrendaAnnounced = true;
        _say(a, "Oh! La Golondrina's portrait is missing from the ofrenda!",
            'shock');
        // whoever stands close enough to hear flinches with them
        for (final o in agents.values) {
          if (o.id == a.id || o.faded || o.id == culpritId) continue;
          if (_dist2(o.x, o.y, a.x, a.y) < 150 * 150) {
            _emit(o, SimEventType.emote, {'agent': o.id, 'glyph': '❗'});
          }
        }
      } else {
        _say(a, line.isEmpty ? 'her frame is still bare…' : line, 'sad');
      }
    } else {
      _sayOrNote(a, line.isEmpty ? p.surfaceText : line, 'curious');
    }
    a.verifiedPois.add(p.id);
    // Physical evidence — looking closely uncovers whatever was left
    // behind here (a pick under a frame), no whisper required.
    for (final s in secrets.values) {
      if (s.foundAt == p.id && !a.knownSecrets.contains(s.id)) {
        a.knownSecrets.add(s.id);
        a.bumpVersion();
        unawaited(
          store.simLog(simTs, a.id, 'found', '${s.id} at ${p.id}'),
        );
      }
    }
    if (a.errand?.targetId == p.id) {
      final wasClaim = a.errand?.claim == true;
      a.errand = null;
      unawaited(
        store.memory(
          Memory(
            agent: a.id,
            simTs: simTs,
            kind: 'observation',
            source: 'self',
            text: wasClaim
                ? 'went to see ${p.name} — the living one\'s words echo'
                : 'went to see ${p.name} — the rumor was true',
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
      _say(
        a,
        d.line.isEmpty
            ? '¡${t.name.split(' ').first}! Still with us?'
            : _cleanLine(d.line),
        'warm',
      );
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
    // Only a name spoken aloud brings a ghost back — a nameless greeting
    // warms them but they stay translucent, half-remembered.
    if (t.faded && wakeSecret != null && t.battery > 8) {
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
    _events.add(SimEvent(SimEventType.move, {'agent': a.id, 'path': const []}));
  }

  /// Walk to a spirit, then run [onNear]. The target is "held" — stops
  /// wandering while the initiator approaches (they see it coming) — so
  /// conversations always happen face to face, never across the plaza.
  /// [order] marks a living-one directive: if the slot is lost AT the
  /// doorstep (target slipped into a convo mid-chase), the order goes
  /// back on the queue instead of dying silently where it arrived.
  void _approachForConvo(
    Agent a,
    Agent t, {
    required void Function(Agent, Agent) onNear,
    void Function(Agent)? onFail,
    Decision? order,
  }) {
    void fail() {
      if (onFail != null) {
        onFail(a);
      } else {
        _fallbackStroll(a);
      }
    }

    if (t.heldBy != null ||
        t.engaged ||
        t.inConvo ||
        _marchers.contains(t.id)) {
      fail();
      return;
    }
    // A marcher's only destination is the culprit's doorstep — ambient
    // errands and gossip approaches can't retask the charge mid-walk.
    // The staged gather carves out its current witness the same way.
    if (_marchers.contains(a.id) &&
        t.id != culpritId &&
        t.id != _gatherTeller?.id) {
      fail();
      return;
    }
    t.heldBy = a.id;
    t.heldUntil = simTs + holdFor;
    _walks.remove(t.id); // pause mid-path — someone is coming to talk
    _deferredWalks.remove(t.id);
    _arrivals.remove(t.id);
    // Same for the approached: a held spirit's directive-walk re-queues
    // so the living one's order outlives the interruption.
    final heldOrder = _directiveWalks.remove(t.id);
    if (heldOrder != null) _pendingApproach[t.id] = heldOrder;
    _releaseSlot(t.id);
    _stopVisual(t);

    // stand on a walkable tile adjacent to the target
    final tx = (t.x / kTile).floor(), ty = (t.y / kTile).floor();
    (int, int)? best;
    var bd = double.infinity;
    for (final d in const [
      (0, -1),
      (0, 1),
      (-1, 0),
      (1, 0),
      (-1, -1),
      (1, -1),
      (-1, 1),
      (1, 1),
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
        if (t.heldBy != ag.id || t.engaged || t.inConvo) {
          // Lost the slot at the doorstep — the living one's order goes
          // back on the queue for another shot; ambient intent lets the
          // moment pass.
          if (order != null && !ag.engaged) {
            _pendingApproach[ag.id] = order;
            unawaited(
              store.simLog(
                simTs,
                ag.id,
                'directive',
                're-queued — ${t.id} slipped away at the door',
              ),
            );
          }
          return;
        }
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
    // Mid-sentence — the bubble is still on screen. Park the walk instead
    // of issuing it; tick() releases it once the line fades.
    if (simTs < a.bubbleUntil) {
      _deferredWalks[a.id] =
          (pts: pts, onArrive: onArrive, until: a.bubbleUntil);
      return;
    }
    _issuePath(a, pts, onArrive);
  }

  void _issuePath(Agent a, List<List<double>> pts, _Arrival? onArrive) {
    _walks[a.id] = pts;
    if (onArrive != null) _arrivals[a.id] = onArrive;
    _events.add(SimEvent(SimEventType.move, {'agent': a.id, 'path': pts}));
  }

  /// Advance every walking agent along its path at the SAME rate the
  /// renderer lerps (real dt × kSpiritSpeed × timeScale) — sim and pixels
  /// stay in sync. Locomotion scales with the festival clock so 4× is a true
  /// fast-forward: legs, mouths, and gossip all move faster together.
  void _advanceWalks(double dt) {
    for (final id in _walks.keys.toList()) {
      final a = agents[id];
      final path = _walks[id];
      if (a == null || path == null || a.engaged || a.inConvo) {
        _walks.remove(id);
        continue;
      }
      var budget = kSpiritSpeed * dt * timeScale;
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
          _directiveWalks.remove(id); // landed — the order reached its mark
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
      final errandPoi =
          e != null &&
              (e.kind == 'verify' || e.kind == 'tend') &&
              pois[e.targetId] != null
          ? pois[e.targetId]
          : null;
      if (errandPoi != null && r < 0.8) {
        _visitSlot(
          a,
          errandPoi.id,
          onArrive: _browse(errandPoi),
          onFail: _fallbackStroll,
        );
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
    final errandHere =
        a.errand?.targetId == p.id &&
        (a.errand?.kind == 'tend' || a.errand?.kind == 'verify');
    if (errandHere) {
      a.verifiedPois.add(p.id);
      a.errand = null;
    }
    _arrivalMusing(a, p, errandHere: errandHere);
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

  /// Arrival musings when no carried whisper gives the thought context —
  /// a pool of plain case-flavored lines rotated per spirit so the town
  /// doesn't chant one static sentence. Authored, not model: an errand
  /// glance isn't worth an inference round-trip.
  static const _musings = [
    'the ofrenda looks wrong tonight.',
    'someone touched the altar — i can feel it.',
    'her frame should not be bare.',
    'who would steal from the dead?',
    'something happened here. i know it.',
    'i keep thinking about her picture.',
    'somebody knows more than they say.',
    'this place feels watched tonight.',
  ];

  /// The visible beat of investigation — 💭 first, a floating thought a
  /// breath later — so arriving on an errand or a carried whisper reads
  /// as the spirit actually LOOKING, not silently standing on the tile.
  /// Real-time delay: thought bubbles are a visual beat, not sim-work.
  void _arrivalMusing(Agent a, Poi p, {required bool errandHere}) {
    Claim? whisper;
    for (final c in claims.values) {
      if (c.version.containsKey(a.id) &&
          _normId(c.text).contains(_normId(p.id))) {
        whisper = c;
        break;
      }
    }
    if (!errandHere && whisper == null) return;
    _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '💭'});
    final musing = whisper != null
        ? '"${whisper.text}" — let me look.'
        : _musings[(a.id.hashCode + simTs ~/ 20).abs() % _musings.length];
    unawaited(
      Future.delayed(
        const Duration(milliseconds: 1200),
        () => _emit(a, SimEventType.thought, {'agent': a.id, 'text': musing}),
      ),
    );
  }

  /// Authored private whispers — the beats only the living one sees.
  /// A mutter becomes a floating thought; a confidence is spoken to one
  /// friend and trapped there (private secrets never re-share). Proof
  /// beats loop until the player relays them — or until `leak`, when the
  /// village overhears its own muttering and the proof escapes anyway.
  void _tickWhispers() {
    for (final w in whispers) {
      final sp = agents[w.speaker];
      if (sp == null || sp.faded || sp.engaged || sp.inConvo) continue;
      final gs = w.grants;
      // already in the open — the whisper has nothing left to say
      if (gs != null &&
          (_relayedSecrets.contains(gs) || _leakedSecrets.contains(gs))) {
        continue;
      }
      // Leak: past its moment, an unrelayed proof is overheard by whoever
      // stands near the mutterer — the village solves it alone, slower.
      if (gs != null && simTs >= w.leak) {
        _leakedSecrets.add(gs);
        overheardWhispers.add(w.id);
        final ear = _nearestFreeSpirit(sp, exclude: {sp.id, culpritId});
        if (ear != null &&
            !ear.knownSecrets.contains(gs) &&
            secrets.containsKey(gs)) {
          ear.knownSecrets.add(gs);
          ear.bumpVersion();
          ear.newsUntil = simTs + 90;
          _emit(ear, SimEventType.emote, {'agent': ear.id, 'glyph': '👂'});
          unawaited(
            store.simLog(simTs, ear.id, 'leak', '$gs overheard from ${sp.id}'),
          );
        }
        // the mutterer knows what they mutter — it lives in their mouth too
        if (!sp.knownSecrets.contains(gs) && secrets.containsKey(gs)) {
          sp.knownSecrets.add(gs);
          sp.bumpVersion();
        }
        continue;
      }
      final last = _whisperFiredAt[w.id] ?? -999;
      if (simTs < w.at || simTs < last + 240) continue;
      final t = w.to == null ? null : agents[w.to];
      if (w.to != null &&
          (t == null || t.faded || t.engaged || t.inConvo)) {
        continue; // the friend isn't ready — try again next tick
      }
      _whisperFiredAt[w.id] = simTs;
      overheardWhispers.add(w.id);
      if (t == null) {
        _emit(sp, SimEventType.thought, {'agent': sp.id, 'text': w.line});
        // the mutterer holds their own secret — sealed while private
        if (gs != null &&
            !sp.knownSecrets.contains(gs) &&
            secrets.containsKey(gs)) {
          sp.knownSecrets.add(gs);
          sp.bumpVersion();
        }
      } else {
        _emit(
          sp,
          SimEventType.say,
          {'agent': sp.id, 'line': w.line, 'mood': 'whisper'},
        );
        // The confidence lands in exactly one ear — and dies there.
        if (gs != null &&
            !t.knownSecrets.contains(gs) &&
            secrets.containsKey(gs)) {
          t.knownSecrets.add(gs);
          t.bumpVersion();
        }
      }
      unawaited(store.simLog(simTs, sp.id, 'whisper', w.id));
    }
  }

  /// The closest spirit to [a] who could actually hear a mutter — the
  /// mechanism that turns a private proof into a leaked one.
  Agent? _nearestFreeSpirit(Agent a, {Set<String> exclude = const {}}) {
    Agent? best;
    var bd = double.infinity;
    for (final o in agents.values) {
      if (exclude.contains(o.id) ||
          o.faded ||
          o.engaged ||
          o.inConvo ||
          o.id == a.id) {
        continue;
      }
      final d = (o.x - a.x) * (o.x - a.x) + (o.y - a.y) * (o.y - a.y);
      if (d < bd) {
        bd = d;
        best = o;
      }
    }
    return best;
  }

  /// The ledger just filled — the town doesn't wait for the living one.
  /// The first spirit holding an established proof goes to face the
  /// culprit; the confrontation completes what the village assembled.
  /// Spirits walking the case-march — an approach poaching a marcher kills
  /// its arrival callback mid-charge (the accuser stops, the culprit's hold
  /// expires, the case never lands). Marchers refuse visitors until they
  /// arrive, fade, or the living one takes over.
  final _marchers = <String>{};

  bool _confrontAnnounced = false;
  void _maybeConfront() {
    if (_caseResolved || caseProgress < 3) return;
    // A failed march retries while the case is hot — a busy culprit or a
    // lost doorstep costs seconds, not a 20s dead window.
    if (simTs - _confrontAt < 6) return;
    final culprit = agents[culpritId];
    if (culprit == null ||
        culprit.faded ||
        culprit.engaged ||
        culprit.inConvo) {
      return;
    }
    // A march already in flight — the culprit's holder is still en route.
    final holder = culprit.heldBy == null ? null : agents[culprit.heldBy];
    if (holder != null &&
        (_walks.containsKey(holder.id) ||
            _deferredWalks.containsKey(holder.id))) {
      return;
    }
    Agent? accuser;
    for (final a in agents.values) {
      if (a.id == culpritId ||
          a.faded ||
          a.engaged ||
          a.inConvo ||
          a.heldBy != null) {
        continue;
      }
      if (a.knownSecrets.any((sid) {
        final s = secrets[sid];
        return s?.proofFor == culpritId &&
            (!(s?.private ?? false) ||
                _relayedSecrets.contains(sid) ||
                _leakedSecrets.contains(sid));
      })) {
        accuser = a;
        break;
      }
    }
    if (accuser == null) return;
    _confrontAt = simTs;
    final acc = accuser;
    unawaited(
      store.simLog(
        simTs,
        acc.id,
        'case',
        'the ledger is full — goes to face $culpritId',
      ),
    );
    _emit(acc, SimEventType.emote, {'agent': acc.id, 'glyph': '🕯'});
    // Announce once per case — the say pins them through its bubble life,
    // the deferred walk releases right as the words fade. Retries march
    // quietly; the town already heard the charge.
    if (!_confrontAnnounced) {
      _confrontAnnounced = true;
      _say(
        acc,
        'The ledger is full. I know who took her face — come, face him with me.',
        'certain',
      );
    }
    _marchers.add(acc.id);
    _approachForConvo(
      acc,
      culprit,
      onNear: (ag, tt) {
        _marchers.remove(ag.id);
        startConversation(ag.id, tt.id);
      },
      onFail: (_) => _confrontAt = simTs - 5, // culprit busy — retry next tick
    );
  }

  /// The town woke to a bare frame — the curious keep drifting back to
  /// the ofrenda to look again. Looking is what finds things: each
  /// visit is an inspect, and inspect is what uncovers the pick.
  int _lastCuriosityAt = -999;
  void _tickCaseCuriosity() {
    if (simTs - _lastCuriosityAt < 45) return;
    for (final a in agents.values) {
      if (a.faded ||
          a.engaged ||
          a.inConvo ||
          a.heldBy != null ||
          a.errand != null ||
          _walks.containsKey(a.id)) {
        continue;
      }
      if (!a.knownSecrets.contains('frame_empty')) continue;
      if (a.verifiedPois.contains('ofrenda')) continue;
      if (a.stats.curiosity < 2 && rng.nextDouble() > 0.4) continue;
      _lastCuriosityAt = simTs;
      a.errand = (
        kind: 'verify',
        targetId: 'ofrenda',
        claim: false,
        subject: null,
      );
      unawaited(
        store.simLog(simTs, a.id, 'curious', 'goes to look at the bare frame'),
      );
      return; // one spirit per window — the altar draws them one by one
    }
  }

  /// A village that hasn't heard the living one in a while wonders
  /// aloud — the nudge that says the sim wants input.
  void _tickNudge() {
    if (simTs - lastPlayerMsgTs < 240) return;
    if (simTs - _lastNudgeAny < 90) return;
    for (final a in agents.values) {
      if (a.faded || a.engaged || a.inConvo || a.heldBy != null) continue;
      if (simTs - (_lastNudgeAt[a.id] ?? -999) < 180) continue;
      _lastNudgeAt[a.id] = simTs;
      _lastNudgeAny = simTs;
      _emit(a, SimEventType.thought, {
        'agent': a.id,
        'text': '…if a thought came to me about the missing frame, I\'d follow it.',
      });
      return; // one nudge per window
    }
  }

  /// Case file — every authored proof, its reach, and whether the living
  /// one has made it admissible (relayed). The sheet veils the text.
  List<({String id, String text, int mouths, bool relayed, bool private})>
  get caseProofs => [
    for (final s in secrets.values)
      if (s.proofFor != null)
        (
          id: s.id,
          text: s.shareText,
          mouths: agents.values
              .where((a) => a.knownSecrets.contains(s.id))
              .length,
          relayed: !s.private ||
              _relayedSecrets.contains(s.id) ||
              _leakedSecrets.contains(s.id),
          private: s.private,
        ),
  ];

  /// Accusations afloat — authored blame secrets + player-planted ones.
  List<({String text, int mouths, String? about})> get caseAccusations => [
    for (final s in secrets.values)
      if (s.accuses != null)
        (
          text: s.shareText,
          mouths: agents.values
              .where((a) => a.knownSecrets.contains(s.id))
              .length,
          about: s.accuses,
        ),
    for (final c in claims.values)
      if (c.kind == 'accusation')
        (text: c.text, mouths: c.version.length, about: c.pointsTo),
  ];

  /// What [a] can honestly say about the case when the living one asks —
  /// proofs and blame they hold, said as a compact prompt digest.
  String? _caseDigestFor(Agent a) {
    final bits = <String>[];
    for (final sid in a.knownSecrets) {
      final s = secrets[sid];
      if (s == null) continue;
      if (s.proofFor != null) {
        bits.add('proof: ${s.shareText}');
      } else if (s.accuses != null) {
        bits.add('blame heard: ${s.shareText} (no proof)');
      } else if (s.alibiFor != null) {
        bits.add('alibi: ${s.shareText}');
      } else if (s.headline) {
        bits.add(s.shareText);
      }
    }
    for (final c in claims.values) {
      if (c.version.containsKey(a.id) &&
          (c.kind == 'proof' || c.kind == 'accusation')) {
        bits.add('gossip: "${c.heardBy(a.id)}"');
      }
    }
    if (bits.isEmpty) return 'nothing yet — you have heard no proof, no blame';
    return bits.join(' | ');
  }

  /// Whispers the player has overheard — speaker, relayed vs trapped.
  List<({String speaker, String line, bool relayed})> get caseWhispers => [
    for (final w in whispers)
      if (overheardWhispers.contains(w.id))
        (
          speaker: w.speaker,
          line: w.line,
          relayed: w.grants == null ||
              _relayedSecrets.contains(w.grants) ||
              _leakedSecrets.contains(w.grants),
        ),
  ];

  /// The next thing the living one could do — rendered as the sheet's
  /// task line so the case file reads as a guide, not a scoreboard.
  List<String> get caseTasks => [
    if (caseResolved) ...[
      'the thief confessed — the portrait is home',
    ] else ...[
      if (caseProofs.any((p) => p.private && !p.relayed))
        'carry an overheard whisper to another spirit — it becomes proof',
      if (caseProofs.any((p) => p.relayed && p.mouths < 2))
        'let a proof reach one more mouth — two mouths make it count',
      if (caseProofs.any((p) => p.id == 'guitar_pick' && p.mouths == 0))
        'inspect the great ofrenda — something was left under the frame',
      if (caseProgress >= 3)
        'the ledger is full — face Ramón yourself, or let the town',
      if (caseProgress < 3 && overheardWhispers.isEmpty)
        'watch for spirits muttering to themselves — those are clues only you can carry',
    ],
  ];

  /// Small models leak JSON edge punctuation into their lines
  /// ("How's the day?\",") — strip wrapper quotes/stray commas at the
  /// ends only; mid-line apostrophes are sacred. Then reject output that
  /// reads as model noise instead of village speech: em/en dashes, stray
  /// brackets/asterisks, or a run-on past eighteen words. A dropped line
  /// bubbles nothing — better silence than "Dimness grows."
  static final _badLineChars = RegExp(r'''[—–~*{}\[\]_|<>^"]''');
  static String _cleanLine(String s) {
    s = s.trim().replaceAll(RegExp('^[\'"]+|[\'",]+\$'), '').trim();
    if (s.isEmpty) return '';
    if (_badLineChars.hasMatch(s)) return '';
    if (s.split(RegExp(r'\s+')).length > 18) return '';
    return s;
  }

  void _say(Agent a, String line, String mood) {
    // Provisional pin — the renderer re-anchors this to the moment the
    // bubble actually appears (walkers' lines queue for arrival), but
    // walks issued in the same call site already defer on this.
    a.bubbleUntil = simTs + (kBubbleLifeSay + 0.4) * timeScale;
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
      (o) => o.id != a.id && !o.faded && _dist2(a.x, a.y, o.x, o.y) < 120 * 120,
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
      a.battery = max(0, a.battery - 1.0);
      if (a.solidified) a.battery = max(a.battery, 20);
      final wasFaded = a.faded;
      // Fading is sticky — once you're a ghost only being remembered brings
      // you back (a name spoken, the living one's attention, a gift). A
      // battery bump alone can't un-fade; otherwise any greeting revives.
      a.faded = a.faded || (!a.solidified && a.battery <= 8);
      if (a.faded != wasFaded) {
        a.bumpVersion();
        _events.add(
          SimEvent(SimEventType.state, {'agent': a.id, 'faded': a.faded}),
        );
        if (a.faded) {
          _abortConvoWith(a.id);
          _releaseSlot(a.id);
          _marchers.remove(a.id); // a ghost can't carry the charge
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
    _deferredWalks.remove(agentId);
    _marchers.remove(agentId); // the living one outranks the march
    _arrivals.remove(agentId);
    // The living one interrupted a walking order — re-queue it so it
    // fires when this engagement ends.
    final grabbedOrder = _directiveWalks.remove(agentId);
    if (grabbedOrder != null) _pendingApproach[agentId] = grabbedOrder;
    _stopVisual(a); // sim froze — the renderer must not finish the lerp
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
    _events.add(
      SimEvent(SimEventType.state, {
        'agent': agentId,
        'engaged': true,
        'faded': a.faded,
      }),
    );
    // The living one came to face him — and the ledger is full. He breaks
    // the moment the engagement opens, same as a spirit's accusation.
    if (agentId == culpritId && !_caseResolved && caseProgress >= 3) {
      _confess(a);
    }
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
  /// the spirit never controls the UI. One chat at a time — a second call
  /// while a reply streams is dropped rather than garbling the history.
  Stream<String> sendPlayerMessage(String text) async* {
    final a = agents[engagedId];
    if (a == null || _playerBusy) return;
    _playerBusy = true;
    lastPlayerMsgTs = simTs; // a living voice was heard — the stall clock resets
    try {
      final hist = _hist(a.id);
      hist.add(ChatMsg(true, text));
      if (hist.length > _playerHistCap) {
        hist.removeRange(0, hist.length - _playerHistCap);
      }
      playerChatCount[a.id] = (playerChatCount[a.id] ?? 0) + 1;
      // Speaking a name: if the player knows a secret that names a fading
      // spirit (wakes_agent) and speaks that spirit's name, the engaged
      // spirit learns the name — or the faded one is revived directly.
      // Data-driven: any wakes_agent secret works, not a hardcoded string.
      for (final s in secrets.values) {
        final w = s.wakesAgent;
        if (w == null || !playerKnown.contains(s.id)) continue;
        final first = agents[w]?.name.split(' ').first.toLowerCase() ?? w;
        final lower = text.toLowerCase();
        if (!lower.contains(first) && !lower.contains(w)) continue;
        if (a.id == w) {
          a.battery = min(100, a.battery + 40);
          if (a.faded && a.battery > 8) {
            a.faded = false;
            a.bumpVersion();
            _events.add(
              SimEvent(SimEventType.state, {'agent': a.id, 'faded': false}),
            );
          }
        } else {
          await _teachSecret(a, s);
        }
        break;
      }
      // Let the MODEL parse the message first — natural language intent
      // is its job; regexes only fill in when the model is unreachable
      // (mock/offline) or answers garbage. Every proposed effect still
      // passes the deterministic gates below.
      Map<String, dynamic>? cls;
      try {
        cls = await llm.direct(prompts.playerIntentPrompt(a, text));
      } catch (_) {}
      final clsIntent = cls?['intent'];
      final clsClaim = () {
        final v = cls?['claimText'];
        return v is String && v.trim().isNotEmpty ? v.trim() : null;
      }();
      final clsTarget = () {
        final v = cls?['orderTarget'];
        return v is String ? _agentByRef(v, exclude: a.id) : null;
      }();
      final clsAsk = '${cls?['orderKind']}'.toLowerCase() == 'ask';
      final clsAbout = <String>[
        for (final n in '${cls?['about'] ?? ''}'.split(','))
          if (n.trim().isNotEmpty) n.trim(),
      ];
      // Claims move the world — naming a place sends the curious to look;
      // naming a spirit becomes a question to carry (D2).
      _claimCuriosityFromText(a, text);
      for (final ref in clsAbout) {
        final p = _poiByRef(ref);
        if (p != null) {
          _claimCuriosity(a, p.id);
          continue;
        }
        final o = _agentByRef(ref, exclude: a.id);
        if (o != null) a.goal ??= 'askAbout:${o.id}';
      }
      // The living one's imperative is an order, not a suggestion — "ask
      // Bruno", "tell Sefa", "go see Ramón" sets the spirit walking NOW.
      // 'ask' verbs open a convo where the named spirit shares; anything
      // else carries the whisper itself — to its subject, if that's who
      // was named (the rumor-meets-its-subject shock). Detection runs
      // before claim-planting: "tell X about Y" *seeds* Y — it is not a
      // question even though 'tell' reads interrogative alone.
      var directiveTo = false;
      Agent? directiveTarget;
      var asking = false;
      final imperative = RegExp(
        r'\b(ask|tell|go|find|visit|talk|speak|fetch|bring|pregunta|dile|habla|busca|anda)\b',
        caseSensitive: false,
      ).firstMatch(text);
      if (imperative != null) {
        final norm = _normId(text);
        for (final o in agents.values) {
          if (o.id == a.id) continue;
          // The living one names people the way people are named — "Bruno",
          // "Abuela", "Violeta" — match id or first name, same ≥4-char
          // guard against noise words.
          final idNorm = _normId(o.id);
          final firstNorm = _normId(o.name.split(' ').first);
          if ((idNorm.length >= 4 && norm.contains(idNorm)) ||
              (firstNorm.length >= 4 && norm.contains(firstNorm))) {
            directiveTarget = o;
            break;
          }
        }
        asking = RegExp(
          r'\b(ask|pregunta|averigua|find)\b',
          caseSensitive: false,
        ).hasMatch(text);
        directiveTo = directiveTarget != null;
      }
      // The model's parse wins over the regex guess — it understood the
      // sentence, the regex only pattern-matched it.
      if (clsTarget != null && clsIntent == 'order') {
        directiveTarget = clsTarget;
        directiveTo = true;
        asking = clsAsk;
      }
      // A declarative message plants a Claim — free text that circulates
      // mouth-to-mouth. Only true question shapes ask instead of seeding:
      // a '?' mark, an interrogative opener, or an outright demand
      // ("tell me", "do you know"). A rumor that merely CONTAINS the word
      // 'secret' is still a rumor — "Bruno hiding a secret" must plant.
      final isAsk = RegExp(
        r'\?|^(who|what|where|when|why|how|did|does|do|is|are|was|were|can|could|should|would|que|quien|donde|como|cuando)\b'
        r'|\b(tell me|do you|have you|got any|any news|any secret|any rumor|know any|cuentame|dime)\b',
        caseSensitive: false,
      ).hasMatch(text);
      // Planting rule: a tell-directive seeds its payload; a plain
      // declarative seeds itself. An ask-order may still CARRY a rumor
      // in front of it — "Bruno got some secrets, near grave 37, ask
      // people nearby" — strip the imperative tail and seed what came
      // before, when it actually names someone or somewhere worth
      // carrying. Bare "find out"/"you have to find out" leaves nothing
      // a rumor could hang on, so it plants nothing.
      var rumorText = text;
      // The classifier's stripped claim beats the regex surgery — it can
      // tell the rumor from the order instead of cutting at a keyword.
      if (clsClaim != null && _mentionsEntity(clsClaim)) {
        rumorText = clsClaim;
      } else if (asking && imperative != null) {
        rumorText = text
            .substring(0, imperative.start)
            .replaceAll(RegExp(r'[,\s]+$'), '')
            .trim();
        if (rumorText.isNotEmpty && !_mentionsEntity(rumorText)) {
          rumorText = '';
        }
      }
      final planted =
          ((directiveTo || !isAsk || clsIntent == 'rumor') &&
                  _normId(rumorText).length >= 6)
              ? (rumorText.isEmpty ? null : _plantClaim(a, rumorText))
              : null;
      final t = directiveTarget;
      if (t != null) {
        // The pending approach below executes the order — the errand is
        // bookkeeping only. A verify errand from the same message ("near
        // grave 37") rides underneath: question first, then go look.
        a.errand ??= (
          kind: 'seek',
          targetId: t.id,
          claim: false,
          subject: planted?.id,
        );
        unawaited(
          store.simLog(
            simTs,
            a.id,
            'directive',
            '${asking ? 'ask' : 'tell'} → ${t.id}',
          ),
        );
        // The spirit is mid-conversation with the living one — walking
        // is impossible while engaged, so the order queues as a deferred
        // approach. On release it fires on the next decision slot: 'ask'
        // opens a convo where the named spirit shares what it holds;
        // 'share' carries the whisper itself — to its subject, if that
        // is who was named (the rumor-meets-its-subject shock).
        _directiveRetries.remove(a.id); // a fresh order gets fresh retries
        // The order marker must sit in `thought` — Decision's third
        // positional is `line`, which is why retries/interruption-recovery
        // (and the hop's don't-stomp-orders check) could never see it.
        _pendingApproach[a.id] = asking
            ? Decision('ask', t.id, '',
                thought: 'the living one sent me', subject: planted?.id)
            : Decision('share', t.id, '',
                thought: 'the living one sent me', subject: planted?.id);
      }
      final memories = await store.recall(
        a,
        simTs,
        contextEntities: {'player'},
      );
      // The model is told WHAT the message was — a rumor demands a
      // reaction to the rumor itself; an order demands acknowledgment.
      // Keep it terse: a small model follows a short imperative, not a
      // lecture. The text itself is already the last line of history.
      final note = planted != null || clsIntent == 'rumor'
          ? 'Fresh rumor'
                '${(planted?.about.isNotEmpty ?? false) ? ' about ${planted!.about.map((e) => agents[e]?.name.split(' ').first ?? e).join(', ')}' : ''}'
                ' — weigh it: believe, doubt, or want more. Not your stories.'
          : t != null || clsIntent == 'order'
          ? 'An order: ${asking ? 'go question' : 'carry word to'} '
                '${t?.name ?? 'someone nearby'}. Acknowledge it your way — '
                'accept, balk, or bargain.'
          : null;
      final prompt = prompts.playerChatPrompt(
        a,
        history: hist.length > 8 ? hist.sublist(hist.length - 8) : hist,
        memories: memories.map((m) => m.text).toList(),
        rumors: _heldRumors(a),
        caseFile: _caseDigestFor(a),
        note: note,
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
      }
      // The model's reply is richer than words: it may just REACT (no line),
      // and for a planted claim it declares belief, who to carry it to, and
      // — for the mischievous — a twisted retelling. The engine owns the
      // claim ledger; the persona owns the intent.
      final reply = PlayerReply.parse(buf.toString());
      final sayPrev = reply.say == null
          ? '—'
          : (reply.say!.length > 40
                ? '${reply.say!.substring(0, 40)}…'
                : reply.say!);
      unawaited(
        store.simLog(
          simTs,
          a.id,
          'reply',
          'say=$sayPrev react=${reply.react} believes=${reply.believes} '
              'to=${reply.shareWith ?? '—'}${reply.twist != null ? ' twist' : ''}',
        ),
      );
      if (planted != null) {
        if (reply.believes == true) planted.believers.add(a.id);
        final tw = reply.twist;
        if (tw != null &&
            a.stats.mischief >= 3 &&
            tw.length <= 140 &&
            _normId(tw) != _normId(planted.text)) {
          planted.version[a.id] = tw;
          unawaited(store.simLog(simTs, a.id, 'twist', '${planted.id}: $tw'));
        }
        // The words must travel: the model may name a carrier, and if it
        // doesn't, the spirit still takes the whisper to SOMEONE — their
        // closest confidant. One whisper always earns at least one hop.
        var target = _fuzzyId(reply.shareWith, agents.keys.toSet());
        target ??= _pickConfidant(a);
        if (target != null &&
            target != a.id &&
            !planted.version.containsKey(target) &&
            !directiveTo) {
          // The hop is guaranteed by the pending approach below — the
          // errand slot is just the "what next" marker. A verify/tend
          // errand is her own go-look curiosity about the named place;
          // let it ride so she delivers the whisper AND THEN goes to
          // see for herself. A 'seek'/'tell' errand is the living one's
          // directive — never touched here.
          a.errand ??= (
            kind: 'tell',
            targetId: target,
            claim: true,
            subject: planted.id,
          );
          // An errand is only a suggestion — the next decision could stroll
          // right past it. Queue the approach instead: on release the
          // spirit walks to their confidant and the hop actually lands.
          final cur = _pendingApproach[a.id];
          if (cur == null || cur.thought != 'the living one sent me') {
            _pendingApproach[a.id] = Decision(
              'share',
              target,
              'this cannot stay with me',
              subject: planted.id,
            );
          }
          unawaited(
            store.simLog(
              simTs,
              a.id,
              'errand',
              'carry ${planted.id} → $target',
            ),
          );
        }
        _persistClaims();
      }
      final glyph = _reactGlyph(reply.react);
      if (glyph != null) {
        _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': glyph});
      }
      final say = reply.say;
      if (say != null && say.isNotEmpty) {
        hist.add(ChatMsg(false, say));
        unawaited(
          store.memory(
            Memory(
              agent: a.id,
              simTs: simTs,
              kind: 'said',
              source: 'self',
              text: 'to the living one: $say',
              importance: 4,
              entities: ['player'],
            ),
          ),
        );
        yield say;
      } else {
        // They just take it in — a nonverbal beat, no invented words.
        final beat = _reactBeat(reply.react);
        hist.add(ChatMsg(false, beat));
        unawaited(
          store.memory(
            Memory(
              agent: a.id,
              simTs: simTs,
              kind: 'said',
              source: 'self',
              text: 'reacted ${reply.react} to the living one\'s words',
              importance: 4,
              entities: ['player'],
            ),
          ),
        );
        yield beat;
      }
      a.battery = min(100, a.battery + 10);

      // Ask and ye shall receive — a question-shaped message draws out a
      // secret the spirit holds and the player lacks. Deterministic like
      // spirit↔spirit transfer: the model writes the line, the engine owns
      // the knowledge. Prefer the spirit's freshest news — that's the spark
      // the 💡 cue promised. Rumor-tier secrets need rapport; nobody
      // confesses their own scandal to a stranger (B3).
      if (RegExp(
        r'\?|secret|news|heard|know|tell|learn|rumor|chisme|cuentame|pasa',
        caseSensitive: false,
      ).hasMatch(text)) {
        final s = await _playerTeachTarget(a);
        if (s != null) {
          learnSecretAsPlayer(s.id, 'spirit:${a.id}');
          _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '✨'});
          _events.add(
            SimEvent(SimEventType.log, {
              'text': '${a.name} tells you: ${s.shareText}',
            }),
          );
        }
      }
    } finally {
      _playerBusy = false;
    }
  }

  /// The secret an engaged spirit should teach the player: their most
  /// recently learned one the player lacks that passes the rapport gate,
  /// else anything they hold that's shareable.
  Future<Secret?> _playerTeachTarget(Agent a) async {
    for (final sid in await store.recentSecrets(a.id)) {
      final s = secrets[sid];
      if (s != null && !playerKnown.contains(sid) && _playerTeachGate(a, s)) {
        return s;
      }
    }
    for (final sid in a.knownSecrets) {
      final s = secrets[sid];
      if (s != null && !playerKnown.contains(sid) && _playerTeachGate(a, s)) {
        return s;
      }
    }
    return null;
  }

  /// B3 — the player faces the rumor gate too. Town lore flows freely;
  /// rumor-tier gossip needs rapport (they've actually talked with you);
  /// a spirit's own scandal needs rapport AND a kindness — the living
  /// stranger has to earn it.
  bool _playerTeachGate(Agent a, Secret s) {
    if (s.tier != 'rumor') return true;
    final rapport = (playerChatCount[a.id] ?? 0) >= 2;
    if (s.aboutAgent == a.id) return rapport && giftedAgents.contains(a.id);
    return rapport;
  }

  /// Whether this spirit takes the living one's word as fact — trusting
  /// souls (warmth≥4), old acquaintances (chat≥3), or the kindly-fed
  /// (gifted) believe. Skeptics prefer their own eyes.
  bool _playerBelieves(Agent a) =>
      a.stats.warmth >= 4 ||
      (playerChatCount[a.id] ?? 0) >= 3 ||
      giftedAgents.contains(a.id);

  /// D1 — the player offers a secret they know to the engaged spirit.
  /// Persona decides what happens: hearing their own scandal is a jolt they
  /// can't unhear; trusting spirits believe and the secret enters normal
  /// circulation; skeptics go verify for themselves; the rest just hear it.
  /// Returns a one-line result for the UI.
  Future<String> teachSpirit(String agentId, String secretId) async {
    final a = agents[agentId];
    final s = secrets[secretId];
    if (a == null || s == null) return 'nothing to tell';
    if (!playerKnown.contains(secretId)) return 'you don\'t know that yet';
    if (a.knownSecrets.contains(secretId)) return '${a.name} already knows.';
    if (s.aboutAgent == a.id) {
      // The living one knows their secret — a jolt they can't unhear.
      await _teachSecret(a, s);
      a.mood = 'shaken';
      unawaited(
        store.memory(
          Memory(
            agent: a.id,
            simTs: simTs,
            kind: 'heard',
            source: 'player_claim',
            text: 'the living one knows my secret — ${s.shareText}',
            importance: 9,
            entities: ['player', s.id],
          ),
        ),
      );
      _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '!'});
      return '${a.name} goes very still.';
    }
    if (_playerBelieves(a)) {
      await _teachSecret(a, s);
      return '${a.name} believes you.';
    }
    if (a.stats.wit >= 4) {
      _claimCuriosityForSecret(a, s);
      return '${a.name} isn\'t so sure — they\'ll see for themselves.';
    }
    unawaited(
      store.memory(
        Memory(
          agent: a.id,
          simTs: simTs,
          kind: 'heard',
          source: 'player_claim',
          text: 'the living one claims: ${s.shareText}',
          importance: 5,
          entities: ['player', s.id],
        ),
      ),
    );
    return '${a.name} hears it, half-believing.';
  }

  /// Atomic player→spirit knowledge transfer — same commit path as
  /// spirit↔spirit: utterance event id is the proof.
  Future<void> _teachSecret(Agent a, Secret s) async {
    final eid = await store.logEvent(simTs, 'utterance', {
      'speaker': 'player',
      'listeners': [a.id],
      'secret': s.id,
    });
    final learned = await store.transferKnowledge(
      a.id,
      s.id,
      'player',
      simTs,
      eid,
    );
    if (!learned) return;
    a.knownSecrets.add(s.id);
    a.newsUntil = simTs + 90;
    a.bumpVersion();
    _checkSolidify();
    _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '✨'});
    _events.add(
      SimEvent(SimEventType.log, {
        'text': 'you tell ${a.name}: ${s.shareText}',
      }),
    );
  }

  /// D2 — a claim worth chasing: naming a place sends the curious to see
  /// for themselves (claim-tagged so arrival memory stays neutral — they
  /// checked, they didn't "prove the rumor true").
  void _claimCuriosity(Agent a, String? poiId) {
    if (poiId != null && pois.containsKey(poiId)) {
      a.goal ??= 'askAbout:$poiId';
      if (a.stats.curiosity >= 3 &&
          a.errand == null &&
          !a.verifiedPois.contains(poiId) &&
          !a.faded) {
        a.errand = (
          kind: 'verify',
          targetId: poiId,
          claim: true,
          subject: null,
        );
        _emit(a, SimEventType.emote, {'agent': a.id, 'glyph': '❓'});
        unawaited(store.simLog(simTs, a.id, 'curious', 'goes to see $poiId'));
      }
    }
  }

  void _claimCuriosityForSecret(Agent a, Secret s) =>
      _claimCuriosity(a, s.unlocksPoiLore);

  // ===================== player-planted rumors (claims) ====================
  //
  // Free text the living one whispers becomes a Claim — it circulates
  // through the same mouth-to-ear machinery as secrets but lives in its own
  // ledger: never unlocks POI lore, never counts for a verdict. Every
  // holder carries the version they HEARD, so a mischievous spirit's
  // retelling keeps mutating down the line — telephone, authored by the
  // LLM, tracked verbatim by the engine.

  /// Who the spirit takes the living one's words to when the model names
  /// nobody: their closest living confidant (warmth ledger), else anyone
  /// still walking. Guarantees a player whisper always earns ≥1 hop.
  String? _pickConfidant(Agent a) {
    final others = agents.values
        .where((o) => o.id != a.id && !o.faded && !o.engaged)
        .toList();
    if (others.isEmpty) return null;
    others.sort((x, y) => (a.warmth[y.id] ?? 0).compareTo(a.warmth[x.id] ?? 0));
    return others.first.id;
  }

  /// Register the player's words as a Claim held by [a]. Same-words repeats
  /// just add the holder — one claim per distinct whisper.
  Claim _plantClaim(Agent a, String text) {
    final norm = _normId(text);
    for (final cl in claims.values) {
      if (_normId(cl.text) == norm) {
        cl.version[a.id] = cl.text;
        _persistClaims();
        return cl;
      }
    }
    final t = text.length > 140 ? '${text.substring(0, 137)}…' : text;
    final cl = Claim(
      id: 'claim_${++claimSeq}',
      text: t,
      bornTs: simTs,
      about: _claimAbout(text),
    );
    cl.version[a.id] = t;
    claims[cl.id] = cl;
    // The living one relayed an overheard whisper — canon tokens make it
    // admissible proof: the claim now carries the real secret into every
    // mouth it reaches.
    for (final w in whispers) {
      if (w.grants == null) continue;
      if (w.canon.every((tok) => norm.contains(_normId(tok)))) {
        cl.kind = 'proof';
        cl.grantsSecret = w.grants;
        cl.pointsTo = secrets[w.grants]?.proofFor;
        _relayedSecrets.add(w.grants!);
        overheardWhispers.add(w.id);
        unawaited(
          store.simLog(simTs, a.id, 'relay', 'whisper ${w.id} → ${w.grants}'),
        );
        break;
      }
    }
    // An accusation — blame without proof. Fingers whoever it names.
    if (cl.kind == 'rumor' &&
        RegExp(
          r'\b(took|stole|stolen|thief|culprit|rob|blame|did it|robó|fue)\b',
          caseSensitive: false,
        ).hasMatch(text)) {
      for (final o in cl.about) {
        if (o != a.id && agents.containsKey(o)) {
          cl.kind = 'accusation';
          cl.pointsTo = o;
          break;
        }
      }
    }
    _persistClaims();
    unawaited(store.simLog(simTs, a.id, 'claim', 'the living one planted: $t'));
    return cl;
  }

  /// Who a whisper is about — spirit ids, first names, and the honored
  /// dead, matched the conservative way (≥4 chars; "la luz" must not tag
  /// Tía Luz).
  List<String> _claimAbout(String text) {
    final norm = _normId(text);
    final out = <String>[];
    for (final o in agents.values) {
      final idNorm = _normId(o.id);
      final firstNorm = _normId(o.name.split(' ').first);
      if ((idNorm.length >= 4 && norm.contains(idNorm)) ||
          (firstNorm.length >= 4 && norm.contains(firstNorm))) {
        out.add(o.id);
      }
    }
    for (final s in secrets.values) {
      final ab = s.aboutAgent;
      if (ab != null &&
          ab.length >= 4 &&
          !agents.containsKey(ab) &&
          norm.contains(_normId(ab)) &&
          !out.contains(ab)) {
        out.add(ab);
      }
    }
    return out;
  }

  /// Would this persona pass a rumor to that ear? Looser than the secret
  /// gate — gossip travels easier than confession. A rumor about yourself
  /// only crosses to someone you trust deeply.
  bool _canPassClaim(Agent teller, Agent hearer, Claim c) {
    if (c.private) return false; // a confidence reaches one ear and dies
    if (c.about.contains(teller.id)) {
      return (teller.warmth[hearer.id] ?? 0) >= 4;
    }
    return teller.stats.mischief >= 3 ||
        teller.stats.curiosity >= 3 ||
        teller.stats.warmth >= 4 ||
        (teller.warmth[hearer.id] ?? 0) >= 2;
  }

  /// The claim versions this spirit carries — surfaced in prompts as
  /// "rumors the living one fed you", voiceable as gossip, never fact.
  /// Rumors this spirit holds — freshest first, capped. Every claim it
  /// ever heard stays in the ledger and still travels via share offers,
  /// but the prompt only carries the recent few: a whisper planted an
  /// hour ago must not crowd out the one the living one just handed.
  List<String> _heldRumors(Agent a, {int limit = 3}) {
    final held = claims.values
        .where((cl) => cl.version.containsKey(a.id))
        .toList()
      ..sort((x, y) => y.bornTs.compareTo(x.bornTs));
    return [for (final cl in held.take(limit)) cl.heardBy(a.id)];
  }

  void _persistClaims() {
    unawaited(
      store.setWorld(
        'claims',
        jsonEncode(claims.values.map((c) => c.toJson()).toList()),
      ),
    );
  }

  /// Cuaderno view — what the player set loose and how far it traveled.
  List<({String text, int mouths})> claimsForCuaderno() => [
    for (final cl in claims.values) (text: cl.text, mouths: cl.version.length),
  ];

  /// Roster dossier — everything the player can see about one spirit.
  /// Static traits come from the Agent; the "have they grown" fields are
  /// grounded in persisted memories/knowledge, not invented: learned =
  /// secrets held beyond what they woke with; learning = a score over
  /// memories + importance + secrets + rumors + places verified.
  Future<SpiritDossier> spiritDossier(String id) async {
    final a = agents[id]!;
    final st = await store.memoryStats(id);
    final reflection = await store.latestReflection(id);
    final initial = secrets.values
        .where((s) => s.initiallyKnownBy.contains(id))
        .map((s) => s.id)
        .toSet();
    final learned = a.knownSecrets.difference(initial).toList();
    final heldClaims = claims.values
        .where((c) => c.version.containsKey(id))
        .map((c) => (text: c.heardBy(id), believes: c.believers.contains(id)))
        .toList();
    final learning =
        st.count +
        learned.length * 5 +
        heldClaims.length * 2 +
        a.verifiedPois.length * 3 +
        (st.importanceSum ~/ 10);
    final level = learning >= 40
        ? 'sage of the festival'
        : learning >= 20
        ? 'remembering much'
        : learning >= 8
        ? 'starting to see'
        : 'still just a spark';
    return SpiritDossier(
      memoryCount: st.count,
      importanceSum: st.importanceSum,
      latestReflection: reflection,
      initialSecrets: initial.length,
      learnedSecrets: learned,
      heldClaims: heldClaims,
      verifiedPois: a.verifiedPois.length,
      learningScore: learning,
      learningLevel: level,
    );
  }

  /// Nonverbal player-chat beats — the spirit takes the words in without
  /// speaking. Glyph floats in-world; the beat line renders in chat.
  String? _reactGlyph(String react) => switch (react) {
    'shock' => '❗',
    'curious' => '❓',
    'wary' => '👀',
    'amused' => '😏',
    'warm' => '🌼',
    'scared' => '🕯️',
    _ => null,
  };

  String _reactBeat(String react) => switch (react) {
    'shock' => '· gasps softly.',
    'curious' => '· leans in, eyes bright.',
    'warm' => '· smiles, candlelight in their eyes.',
    'wary' => '· studies you a long moment.',
    'amused' => '· snorts, half a laugh.',
    'sad' => '· looks away toward the candles.',
    'scared' => '· pulls their shawl tighter.',
    _ => '· listens in silence.',
  };

  /// The village roster every prompt carries — names, ids, roles, plus the
  /// honored dead the secrets mention (Genero & co.). Base knowledge of
  /// who's who, so spirits understand what the living one means.
  String _buildCast() {
    final souls = agents.values
        .map((a) => '${a.name} (${a.id} — ${a.role})')
        .join('; ');
    final dead = secrets.values
        .map((s) => s.aboutAgent)
        .whereType<String>()
        .where((id) => !agents.containsKey(id))
        .toSet()
        .map((d) => '${d[0].toUpperCase()}${d.substring(1)}')
        .join(', ');
    return 'The village: $souls.${dead.isEmpty ? '' : ' Honored dead: $dead.'}';
  }

  /// What the living one means by place-words — ids and display names cover
  /// "fountain"/"ofrenda", but "the tree" must reach the Old Ceiba and
  /// "the graveyard" Cemetery Lane. Tokens the player would actually type.
  static const _poiAliases = <String, List<String>>{
    'ancient_tree': ['tree', 'ceiba', 'big tree', 'old tree'],
    'bridge': ['bridge', 'puente'],
    'fountain': ['fountain', 'fuente'],
    'ofrenda': ['ofrenda', 'altar', 'shrine'],
    'grave_37': ['grave 37', 'grave37', 'grave thirty'],
    'cemetery_lane': ['cemetery', 'graveyard', 'graves', 'cementerio'],
    'gravedigger_hut': ['hut', 'gravedigger'],
    'cantina': ['cantina', 'catrina', 'bar'],
    'flower_stall': ['flower', 'flowers', 'stall', 'flores'],
    'curiosity_shop': ['shop', 'store', 'curiosity'],
    'plaza': ['plaza', 'square'],
  };

  /// D2 — typed claims move the world: naming a place sends the curious to
  /// look; naming a spirit becomes an askAbout goal. Conservative matching
  /// — POIs first (distinctive names), agents ≥4 chars (Tía "Luz" is a
  /// common word; matching her name on "la luz de las velas" would send
  /// spirits chasing candlelight).
  void _claimCuriosityFromText(Agent a, String text) {
    final norm = _normId(text);
    for (final e in _poiAliases.entries) {
      if (pois.containsKey(e.key) &&
          e.value.any((al) => norm.contains(_normId(al)))) {
        _claimCuriosity(a, e.key);
        return;
      }
    }
    for (final p in pois.values) {
      if (norm.contains(_normId(p.id)) || norm.contains(_normId(p.name))) {
        _claimCuriosity(a, p.id);
        return;
      }
    }
    for (final o in agents.values) {
      if (o.id == a.id) continue;
      final idNorm = _normId(o.id);
      final firstNorm = _normId(o.name.split(' ').first);
      if ((idNorm.length >= 4 && norm.contains(idNorm)) ||
          (firstNorm.length >= 4 && norm.contains(firstNorm))) {
        a.goal ??= 'askAbout:${o.id}';
        return;
      }
    }
  }

  /// Resolve a name/id the model produced to an agent — exact, first
  /// name, or fuzzy ("solors" → solorio). null when it points at nobody.
  Agent? _agentByRef(String ref, {String? exclude}) {
    final norm = _normId(ref);
    if (norm.isEmpty) return null;
    for (final o in agents.values) {
      if (o.id == exclude) continue;
      if (_normId(o.id) == norm ||
          _normId(o.name) == norm ||
          _normId(o.name.split(' ').first) == norm) {
        return o;
      }
    }
    final fuzzy = _fuzzyId(ref, agents.keys.toSet());
    return fuzzy != null && fuzzy != exclude ? agents[fuzzy] : null;
  }

  /// Same for places — "grave 37" → grave_37, "the fountain" → fountain.
  Poi? _poiByRef(String ref) {
    final norm = _normId(ref);
    if (norm.isEmpty) return null;
    for (final p in pois.values) {
      if (_normId(p.id) == norm || _normId(p.name) == norm) return p;
    }
    final fuzzy = _fuzzyId(ref, pois.keys.toSet());
    return fuzzy != null ? pois[fuzzy] : null;
  }

  /// Does this text name anyone or anywhere the village knows? The gate
  /// for seeding rumor out of an order — "you have to find out" points
  /// at nothing and plants nothing.
  bool _mentionsEntity(String text) {
    final norm = _normId(text);
    for (final o in agents.values) {
      final idNorm = _normId(o.id);
      final firstNorm = _normId(o.name.split(' ').first);
      if ((idNorm.length >= 4 && norm.contains(idNorm)) ||
          (firstNorm.length >= 4 && norm.contains(firstNorm))) {
        return true;
      }
    }
    for (final p in pois.values) {
      if (norm.contains(_normId(p.id)) || norm.contains(_normId(p.name))) {
        return true;
      }
    }
    return false;
  }

  /// POI inspect — deep lore iff player knows an unlocking secret.
  /// Multiple secrets can gate the same POI; any known one reveals it.
  String inspectPoi(String poiId) {
    final p = pois[poiId];
    if (p == null) return '';
    final known = secrets.values
        .where((s) => s.unlocksPoiLore == poiId && playerKnown.contains(s.id))
        .firstOrNull;
    return known?.truth ?? p.surfaceText;
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

  /// The live petal count is authoritative — the world kv only mirrors it.
  /// Writing on pickup keeps store.purchase honest (no autosave-window desync).
  void addPetal() {
    playerPetals++;
    unawaited(store.setWorld('petals', '$playerPetals'));
  }

  /// Atomic purchase via store.transaction. Returns true on commit.
  Future<bool> buyItem(String itemId) async {
    final item = shopItems[itemId];
    if (item == null) return false;
    if (item['seller'] != null && (playerChatCount[item['seller']] ?? 0) == 0) {
      return false; // warmth gate — seller doesn't trust the player yet
    }
    if (playerPetals < (item['price'] as int)) return false; // live balance
    final ok = await store.purchase(
      'player',
      itemId,
      item['price'] as int,
      simTs,
      balance: playerPetals,
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

  /// Give an inventory item to the engaged spirit — battery + rapport.
  /// Engaged-only: gifts happen face to face, not across the map.
  Future<bool> giveGift(String agentId, String itemId) async {
    if ((playerInventory[itemId] ?? 0) <= 0) return false;
    final a = agents[agentId];
    if (a == null || agentId != engagedId) return false;
    playerInventory[itemId] = playerInventory[itemId]! - 1;
    giftedAgents.add(agentId);
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

  /// Persona-shaped propagation — rumor-tier gossip only travels channels
  /// that fit the teller: gossips leak to anyone (mischief≥3), warm souls
  /// confide freely (warmth-stat≥4), everyone else needs a real bond
  /// (warmth≥2). And nobody confesses their own scandal to a stranger —
  /// secrets ABOUT the teller demand warmth≥4. Deterministic; this is how
  /// the same rumor travels differently through every persona.
  bool _canShareRumor(Agent a, Agent b, Secret? s) {
    if (s == null || s.tier != 'rumor') return true;
    // confidences don't travel — until they're overheard into the open
    if (s.private && !_leakedSecrets.contains(s.id)) return false;
    // An accusation dies in the ear of whoever holds the alibi — Carmen
    // doesn't pass on a blame she can disprove.
    if (s.accuses != null &&
        b.knownSecrets.any(
          (id) => secrets[id]?.alibiFor == s.accuses,
        )) {
      return false;
    }
    if (s.aboutAgent == a.id) return (a.warmth[b.id] ?? 0) >= 4;
    return (a.warmth[b.id] ?? 0) >= 2 ||
        a.stats.mischief >= 3 ||
        a.stats.warmth >= 4;
  }

  /// Persona distortion — a teller with mischief≥4 who passes a secret that
  /// has an authored variant (variant_of → sid) invents the embellished
  /// version instead: they gain the lie as knowledge (ownership must exist
  /// for the transfer to commit), the receiver learns only the variant.
  /// Nobody embellishes their own scandal. The lie and the truth then
  /// compete in the knowledge graph — the ledger counts proof-mouths only.
  String _distorted(Agent teller, Agent receiver, String sid) {
    if (teller.stats.mischief < 4) return sid;
    final v = secrets.values.where((x) => x.variantOf == sid).firstOrNull;
    if (v == null ||
        receiver.knownSecrets.contains(v.id) ||
        v.aboutAgent == teller.id) {
      return sid;
    }
    teller.knownSecrets.add(v.id);
    teller.bumpVersion();
    unawaited(store.simLog(simTs, teller.id, 'embellished', '$sid -> ${v.id}'));
    return v.id;
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
    _persistClaims();
  }

  bool _resolved = false;
  void _resolution() {
    if (_resolved) return;
    _resolved = true;
    final remembered = agents.values.where((a) => !a.faded).length;
    _events.add(
      SimEvent(SimEventType.endRun, {
        'remembered': remembered,
        'faded': agents.length - remembered,
        'verdict': _caseNote,
      }),
    );
  }
}
