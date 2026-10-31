/// Core sim data types — pure Dart, no Flutter imports.
library;

/// Shared locomotion speed (world units / real second). The sim advances
/// positions at this rate and the renderer lerps at the same rate, so the
/// two never diverge — no teleport-on-arrival.
const kSpiritSpeed = 55.0;

/// Speech-bubble lifetime in REAL seconds (the renderer's `_ttl`, not sim
/// time). The sim lingers a finished conversation for ~this long so nobody
/// walks off while their last line is still readable — at 8× speed that is
/// ~29 sim-seconds, not 3.
const kBubbleLifeSay = 3.6;
const kBubbleLifeThought = 2.6;
const kBubbleLifeEmote = 1.8;

class Stats {
  final int curiosity;
  final int wit;
  final int warmth;
  final int spiritSight;
  final int mischief;
  final int grump;

  const Stats({
    this.curiosity = 0,
    this.wit = 0,
    this.warmth = 0,
    this.spiritSight = 0,
    this.mischief = 0,
    this.grump = 0,
  });

  factory Stats.fromJson(Map<String, dynamic> j) => Stats(
        curiosity: j['curiosity'] ?? 0,
        wit: j['wit'] ?? 0,
        warmth: j['warmth'] ?? 0,
        spiritSight: j['spirit_sight'] ?? 0,
        mischief: j['mischief'] ?? 0,
        grump: j['grump'] ?? 0,
      );

  int byName(String n) => switch (n) {
        'curiosity' => curiosity,
        'wit' => wit,
        'warmth' => warmth,
        'spirit_sight' => spiritSight,
        'mischief' => mischief,
        'grump' => grump,
        _ => 0,
      };
}

enum Mood { neutral, warm, curious, sad, scared }

class Agent {
  final String id;
  final String name;
  final String role;
  final String persona;
  final Stats stats;
  final String home;

  double battery; // 0..100
  double x, y;
  int stateVersion = 0;
  bool engaged = false;
  bool inConvo = false;
  String? heldBy; // spirit approaching to talk — stand still till they arrive
  double heldUntil = -1; // sim_ts — holds expire so nobody freezes forever
  double bubbleUntil =
      -1; // sim_ts — a visible speech bubble pins them in place
  bool faded = false;
  bool solidified = false; // nameless-grave arc: can't re-fade once true
  String? goal; // e.g. 'askAbout:ancient_tree'

  /// Current errand — the agent's plan. (kind: 'tell'|'verify'|'tend'|'seek',
  /// targetId: agent or POI id, claim: came from a player claim rather than
  /// a known secret — so arrival memories stay neutral, not "the rumor was
  /// true", subject: the specific Claim id a 'tell' errand is carrying).
  /// Deterministically assigned, LLM-chosen how to pursue.
  ({String kind, String targetId, bool claim, String? subject})? errand;

  /// Relationship ledger — who this spirit feels close to. +2 per
  /// meaningful convo, +5 on receiving a secret. Feeds prompts and
  /// tell-targeting; persisted in the world kv table.
  final Map<String, int> warmth = {};

  /// Transient disposition set by the director's mood beat — surfaced in
  /// prompts as "Feeling: …". Not persisted; the day forgets.
  String? mood;

  /// One authored quirk from personas.json — the Wildermyth-style hook the
  /// director casts roles from.
  String? hook;

  /// Time-of-day routine from personas.json: at sim_ts >= `at`, tend
  /// `poi`. Majora's-Mask-style baseline under the emergent errands.
  List<({int at, String poi})> schedule = const [];

  /// Recently learned something — the 💡 "has news" cue renders while
  /// sim_ts < this. Lets the player spot who just heard a secret.
  int newsUntil = -1;

  /// POIs this spirit has personally inspected — gates the verify→inspect
  /// reaction loop so a heard secret sends them to see for themselves.
  final Set<String> verifiedPois = {};

  double lastActedAt = -30; // starts eligible for the decision cache
  int lastTalkedToPlayer = -1; // sim_ts
  final Set<String> knownSecrets = {};

  Agent({
    required this.id,
    required this.name,
    required this.role,
    required this.persona,
    required this.stats,
    required this.home,
    this.battery = 80,
    this.x = 0,
    this.y = 0,
  });

  void bumpVersion() => stateVersion++;

  String get condition =>
      faded ? 'fading' : (battery > 55 ? 'lively' : 'dim');
}

class Secret {
  final String id;
  final String surface;
  final String truth;
  final String shareText;
  final List<String> initiallyKnownBy;
  final String? unlocksPoiLore;

  /// Speaking this secret's name aloud to [wakesAgent] recharges them hard —
  /// the resurrection mechanic, data-driven instead of hardcoded.
  final String? wakesAgent;

  /// The agent this secret is ABOUT — for rumor-tier gossip, the subject
  /// only confesses their own scandal to a deeply trusted ear (warmth≥4).
  final String? aboutAgent;

  /// The festival's headline — the director reports on its spread.
  final bool headline;

  /// Case model — who this secret incriminates. A secret with [proofFor]
  /// is evidence: it only counts toward the case when ≥2 different
  /// spirits hold it (one mouth is just a rumor). Deterministic.
  final String? proofFor;

  /// Case model — who this secret *clears*. An alibi held in the right
  /// ear kills an accusation at the moment of transfer.
  final String? alibiFor;

  /// An accusation — a blame, not a fact. Spreads like gossip, dies when
  /// it reaches a mouth that holds the matching [alibiFor].
  final String? accuses;

  /// Confidences — never shared in conversation and never count toward
  /// the case until the living one carries them into circulation.
  final bool private;

  /// Found by inspecting: the POI id where a curious spirit physically
  /// uncovers this secret (a pick under a frame, wax on a candle).
  final String? foundAt;

  /// A distorted telling of another secret — authored lies that travel as
  /// knowledge. When a teller with mischief≥4 passes the base secret, the
  /// engine swaps in this variant: the teller invents the embellishment,
  /// the receiver learns only the lie. Verdicts count truth-knowers only.
  final String? variantOf;

  final String tier;

  const Secret({
    required this.id,
    required this.surface,
    required this.truth,
    required this.shareText,
    required this.initiallyKnownBy,
    this.unlocksPoiLore,
    this.wakesAgent,
    this.aboutAgent,
    this.headline = false,
    this.proofFor,
    this.alibiFor,
    this.accuses,
    this.private = false,
    this.foundAt,
    this.variantOf,
    this.tier = 'town',
  });

  factory Secret.fromJson(Map<String, dynamic> j) => Secret(
        id: j['id'],
        surface: j['surface'],
        truth: j['truth'],
        shareText: j['share_text'],
        initiallyKnownBy: List<String>.from(j['initially_known_by'] ?? const []),
        unlocksPoiLore: j['unlocks_poi_lore'],
        wakesAgent: j['wakes_agent'],
        aboutAgent: j['about_agent'],
        headline: j['headline'] == true,
        proofFor: j['proof_for'],
        alibiFor: j['alibi_for'],
        accuses: j['accuses'],
        private: j['private'] == true,
        foundAt: j['found_at'],
        variantOf: j['variant_of'],
        tier: j['tier'] ?? 'town',
      );
}

class Memory {
  final String agent;
  final int simTs;
  final String kind; // observation|said|heard|reflection
  final String source; // world|self|spirit:<id>|player_claim|rumor
  final String text;
  final int importance; // 1..10
  final List<String> entities;

  const Memory({
    required this.agent,
    required this.simTs,
    required this.kind,
    required this.source,
    required this.text,
    required this.importance,
    this.entities = const [],
  });
}

class ChatMsg {
  final bool isUser;
  final String text;
  const ChatMsg(this.isUser, this.text);
}

/// A rumor the player planted — free text that circulates mouth-to-mouth
/// like a secret but lives in a separate ledger: claims never unlock POI
/// lore, never count toward a verdict, and always trace back to "the living
/// one". Telephone rules: every holder carries the version they HEARD, so a
/// mischievous retelling keeps mutating down the line while [text] stays
/// the verbatim original. The LLM voices it; the engine owns who holds it.
class Claim {
  final String id; // claim_<n>
  final String text; // the living one's verbatim words (≤140 chars)
  final List<String> about; // agent / about_agent ids mentioned
  final int bornTs;

  /// 'rumor' (default) — free gossip. 'accusation' — fingers a spirit
  /// ([pointsTo]); debunked by alibis. 'proof' — a relayed whisper that
  /// grants its canonical secret ([grantsSecret]) to every new mouth.
  String kind;

  /// The spirit an accusation/proof fingers (agent id, validated).
  String? pointsTo;

  /// Canonical proof id — set when the living one's words match an
  /// authored whisper. Each new mouth learns that secret for real.
  String? grantsSecret;

  /// Friend-only — reaches its confidant and dies there.
  bool private;

  /// holderId -> the version they heard (and will pass on). Keys = holders.
  final Map<String, String> version = {};

  /// Holders who said they believe it — the rest repeat it as gossip.
  final Set<String> believers = {};

  Claim({
    required this.id,
    required this.text,
    required this.bornTs,
    this.about = const [],
    this.kind = 'rumor',
    this.pointsTo,
    this.grantsSecret,
    this.private = false,
  });

  Set<String> get holders => version.keys.toSet();

  String heardBy(String agentId) => version[agentId] ?? text;

  Map<String, dynamic> toJson() => {
        'id': id,
        'text': text,
        'about': about,
        'born_ts': bornTs,
        'kind': kind,
        'points_to': pointsTo,
        'grants_secret': grantsSecret,
        'private': private,
        'version': version,
        'believers': believers.toList(),
      };

  factory Claim.fromJson(Map<String, dynamic> j) {
    final c = Claim(
      id: j['id'],
      text: j['text'],
      bornTs: j['born_ts'] ?? 0,
      about: List<String>.from(j['about'] ?? const []),
      kind: j['kind'] ?? 'rumor',
      pointsTo: j['points_to'],
      grantsSecret: j['grants_secret'],
      private: j['private'] == true,
    );
    (j['version'] as Map?)?.forEach((k, v) => c.version['$k'] = '$v');
    c.believers.addAll(List<String>.from(j['believers'] ?? const []));
    return c;
  }
}

/// Everything the roster sheet shows for one spirit — the dynamic fields,
/// grounded in persisted memory/knowledge rather than invented.
class SpiritDossier {
  final int memoryCount;
  final int importanceSum;
  final String? latestReflection;

  /// Secrets they woke up knowing (authored baseline).
  final int initialSecrets;

  /// Secret ids they learned today — beyond their baseline.
  final List<String> learnedSecrets;

  /// Rumors they're carrying: their heard version + whether they believe it.
  final List<({String text, bool believes})> heldClaims;

  /// POIs they went to check for themselves.
  final int verifiedPois;

  /// Derived "did they get smarter" score + label.
  final int learningScore;
  final String learningLevel;

  const SpiritDossier({
    required this.memoryCount,
    required this.importanceSum,
    required this.latestReflection,
    required this.initialSecrets,
    required this.learnedSecrets,
    required this.heldClaims,
    required this.verifiedPois,
    required this.learningScore,
    required this.learningLevel,
  });
}

class Poi {
  final String id;
  final String name;
  final String surfaceText;
  final double x, y;
  final double radius;
  final bool anomaly; // emits curiosity stimulus
  final bool isStall;
  final String? sprite;

  const Poi({
    required this.id,
    required this.name,
    required this.surfaceText,
    required this.x,
    required this.y,
    this.radius = 70,
    this.anomaly = false,
    this.isStall = false,
    this.sprite,
  });
}
