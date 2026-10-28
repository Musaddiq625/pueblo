/// Core sim data types — pure Dart, no Flutter imports.
library;

/// Shared locomotion speed (world units / real second). The sim advances
/// positions at this rate and the renderer lerps at the same rate, so the
/// two never diverge — no teleport-on-arrival.
const kSpiritSpeed = 55.0;

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
  bool faded = false;
  bool solidified = false; // nameless-grave arc: can't re-fade once true
  String? goal; // e.g. 'askAbout:ancient_tree'

  /// Current errand — the agent's plan. (kind: 'tell'|'verify'|'tend'|'seek',
  /// targetId: agent or POI id). Deterministically assigned, LLM-chosen how
  /// to pursue. Every walk should have a reason.
  ({String kind, String targetId})? errand;

  /// Relationship ledger — who this spirit feels close to. +2 per
  /// meaningful convo, +5 on receiving a secret. Feeds prompts and
  /// tell-targeting; persisted in the world kv table.
  final Map<String, int> warmth = {};

  /// Transient disposition set by the director's mood beat — surfaced in
  /// prompts as "Feeling: …". Not persisted; the night forgets.
  String? mood;

  /// One authored quirk from personas.json — the Wildermyth-style hook the
  /// director casts roles from.
  String? hook;

  /// Time-of-night routine from personas.json: at sim_ts >= `at`, tend
  /// `poi`. Majora's-Mask-style baseline under the emergent errands.
  List<({int at, String poi})> schedule = const [];

  /// POIs this spirit has personally inspected — gates the verify→inspect
  /// reaction loop so a heard secret sends them to see for themselves.
  final Set<String> verifiedPois = {};

  double lastActedAt = 0;
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'stats': {
          'curiosity': stats.curiosity,
          'wit': stats.wit,
          'warmth': stats.warmth,
          'spirit_sight': stats.spiritSight,
          'mischief': stats.mischief,
          'grump': stats.grump,
        },
        'battery': battery,
        'x': x,
        'y': y,
        'state_version': stateVersion,
        'known': knownSecrets.toList(),
      };
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
  final String tier;

  const Secret({
    required this.id,
    required this.surface,
    required this.truth,
    required this.shareText,
    required this.initiallyKnownBy,
    this.unlocksPoiLore,
    this.wakesAgent,
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
