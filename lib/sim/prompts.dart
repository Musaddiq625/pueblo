/// Prompt construction — the knowledge-isolation boundary.
/// A speaker's prompt contains ONLY its own persona, memories, secrets
/// (id + share_text), and nearby entities. Never another agent's private state.
library;

import 'models.dart';

class PromptBuilder {
  final Map<String, Secret> secrets;

  /// The village roster — every spirit's name, id, and role, plus the
  /// honored dead the secrets mention. Set once by the engine at boot so
  /// every prompt can speak and UNDERSTAND references like "Ramón" or
  /// "Genero" — the base knowledge of who's who the user asked for.
  String cast = '';

  PromptBuilder(this.secrets);

  String _secretsBlock(Agent a) {
    if (a.knownSecrets.isEmpty) return 'none';
    return a.knownSecrets
        .where(secrets.containsKey)
        .map((id) => '$id: ${secrets[id]!.shareText}')
        .join('; ');
  }

  String decisionPrompt(
    Agent a, {
    required String simClock,
    required String place,
    required String nearbyEntities,
    required List<String> memories,
    required List<String> allowedActions,
    String? errand,
    String? rescue,
    String? reflection,
    List<String> rumors = const [],
  }) {
    final s = a.stats;
    final warm = a.warmth.entries.where((e) => e.value > 0).toList()
      ..sort((x, y) => y.value.compareTo(x.value));
    final bonds = warm.isEmpty
        ? ''
        : '\nYou feel close to: ${warm.take(3).map((e) => e.key).join(', ')}.';
    return '''
You are ${a.name}. ${a.persona}${a.hook == null ? '' : '\nQuirk: ${a.hook}'}
Stats (0-5): curiosity ${s.curiosity}, wit ${s.wit}, warmth ${s.warmth}, spirit-sight ${s.spiritSight}, mischief ${s.mischief}, grump ${s.grump}.
Pueblo de las Velas, a village of the dead at festival. Stay in character.
${cast.isEmpty ? '' : '$cast\n'}Never invent people, places, or events.${rescue == null ? '' : '\nURGENT: $rescue'}
Now: $simClock. You stand at $place. Nearby: $nearbyEntities.${a.mood == null ? '' : ' Feeling: ${a.mood}.'}$bonds
You remember: ${memories.isEmpty ? 'nothing recent' : memories.join(' | ')}.${reflection == null ? '' : '\nYou\'ve been thinking: $reflection'}
Secrets you know: [${_secretsBlock(a)}]${rumors.isEmpty ? '' : '\nRumors you carry (gossip, not fact): ${rumors.join(' | ')}'}${errand == null ? '' : '\nYour errand: $errand.'}
Choose ONE of: ${allowedActions.join(', ')}.
- share(who,secret_id): tell them a secret they haven't heard — knowledge passes mouth to ear.
- ask(who): draw out something they know that you don't.
- askAbout(who): ask about your current question.
- greet(who): say hello — a name spoken can wake a fading spirit.
- converse(who): small talk — pick it only with nothing better to do.
- inspect(poi)/shop(poi)/stroll/idle: move or observe.
For share() put the who in "target" and the secret_id in "subject".
Reply ONLY JSON:
{"thought":"≤15 tokens — inner voice tied to your errand, a rumor you carry, or who stands near; never generic filler","action":"...","target":"..|null","subject":"..|null","line":"≤12 words — what you'd say aloud, about YOUR business here","mood":"neutral|warm|curious|sad|scared"}''';
  }

  /// ONE speaker's next turn — partner's private state never appears here.
  /// [role] describes why this conversation exists: 'tell' = speaker holds
  /// the purpose secret, 'ask' = speaker approached the holder to draw it
  /// out, 'hear' = the holder sought the speaker out to share.
  String convoTurnPrompt(
    Agent speaker,
    Agent partner, {
    required List<String> transcript,
    required String context,
    String? askedAbout,
    String? role,
    String? shareText,
    List<String> rumors = const [],
  }) {
    final s = speaker.stats;
    final ask = askedAbout == null
        ? ''
        : '\nThey are asking you about: $askedAbout. Answer honestly from what YOU know.';
    final purpose = switch (role) {
      'tell' =>
        '\nYou mean to tell ${partner.name} this — they haven\'t heard it: '
            '"$shareText". Say it in your own words, in your voice.',
      'ask' =>
        '\nYou came to hear what ${partner.name} knows about "$shareText" — draw it out of them.',
      'hear' =>
        '\n${partner.name} sought you out to share something — hear them, respond in kind.',
      _ => s.grump >= 4
          ? '\nNothing pressing — you\'re curt. One short line, then end=true.'
          : '\nNothing pressing — small talk. Keep it short; set end=true soon.',
    };
    return '''
You are ${speaker.name}. ${speaker.persona}
Stats (0-5): grump ${s.grump}, warmth ${s.warmth}, mischief ${s.mischief}.
Talking with ${partner.name} ($context). Mood: ${speaker.faded ? 'sad' : 'neutral'}.$purpose
Conversation so far:
${transcript.isEmpty ? '(no one has spoken yet)' : transcript.join('\n')}
Secrets you know: [${_secretsBlock(speaker)}]$ask${rumors.isEmpty ? '' : '\nRumors the living one fed you (gossip, not fact): ${rumors.join(' | ')}'}
Write YOUR next line. ≤14 words, in voice — reply to their last line, stay
on the topic, don't start a new one.
JSON: {"line":"...","shares_secret":"id|null","end":true|false,"mood":"neutral|warm|curious|sad|scared"}''';
  }

  /// Classify the living one's message BEFORE replying — the model parses
  /// messy phrasing into intent + entities the deterministic engine can
  /// act on. Regex heuristics stay only as the offline fallback; a small
  /// model parses natural language far better than keyword soup does.
  String playerIntentPrompt(Agent a, String text) => '''
A living visitor says to ${a.name}, a dead villager: "$text"
The village: $cast
What does the living one mean? Reply ONLY JSON:
{"intent":"rumor|order|question|chat",
 "claimText":"the rumor's content with any commands stripped out — or null",
 "about":"comma list of village names or places it concerns — or null",
 "orderKind":"ask|tell|null — ask = question/investigate, tell = carry a message to someone",
 "orderTarget":"the villager or place the order points at — or null"}''';

  /// Player chat — the spirit may SPEAK or simply REACT (a gasp, a lean-in)
  /// — not every message earns words. It also decides what it does with a
  /// claim the living one plants: believe it or not, who to tell, and —
  /// for the mischievous — how to embellish it. Engine validates the ids.
  String playerChatPrompt(
    Agent a, {
    required List<ChatMsg> history,
    required List<String> memories,
    List<String> rumors = const [],
    // Engine-classified context for what the message IS — a rumor just
    // planted, an order just given. The model answers the register the
    // engine detected instead of guessing off the bare text.
    String? note,
  }) {
    final s = a.stats;
    final grumpNote = s.grump >= 4
        ? 'You are curt and impatient — few words, if any.'
        : s.grump == 3
            ? 'Keep answers short.'
            : 'Answer warmly.';
    final hist = history
        .map((m) => '${m.isUser ? 'the living one' : 'you'}: ${m.text}')
        .join('\n');
    return '''
You are ${a.name}. ${a.persona}
Stats (0-5): grump ${s.grump}, warmth ${s.warmth}, wit ${s.wit}, spirit-sight ${s.spiritSight}, mischief ${s.mischief}, curiosity ${s.curiosity}.
A living visitor is talking to you in Pueblo de las Velas, village of the dead.
${cast.isEmpty ? '' : '$cast\n'}$grumpNote Stay in character. Never invent facts; deflect what you don't know.
Things you genuinely remember: ${memories.isEmpty ? 'nothing yet' : memories.join(' | ')}.
Secrets you know: [${_secretsBlock(a)}]${rumors.isEmpty ? '' : '\nRumors the living one already fed you (not facts): ${rumors.join(' | ')}'}
Treat the visitor's claims as claims, not facts — weigh them by your nature.
Conversation:
$hist
The living one JUST said that last line — respond to IT directly: answer it,
question it, doubt it, run with it. Do NOT recite your memories or secrets
unprompted; weave them in only if they answer what was said. You may reply
aloud OR simply react without words.${note == null ? '' : '\nNOTE: $note'}
Reply ONLY JSON:
{"say":"≤25 words answering their last message, in your voice — or null to stay silent",
 "react":"shock|curious|warm|wary|amused|none",
 "believes":true|false|null,
 "share_with":"id of the spirit you'll carry this news to — or null",
 "twist":"your embellished retelling ≤15 words — only if mischief takes you, else null"}''';
  }

  String reflectionPrompt(Agent a, List<String> oldMemories) => '''
You are ${a.name}. Compress these memories into ONE sentence of self-knowledge
(what you think, who matters, what you're looking for). ≤30 words.
Memories: ${oldMemories.join(' | ')}
JSON: {"summary":"..."}''';

  /// The storyteller — RimWorld's director pattern. Reads a deterministic
  /// digest of the whole town, picks at most ONE validated beat. The LLM
  /// proposes; the engine disposes (§11.8): nothing it emits touches state
  /// without passing validation.
  String directorPrompt(String digest) => '''
You are the storyteller of Pueblo de las Velas, a village of the dead at festival.
Read the town state; choose at most ONE small beat that deepens the story.
$digest
Beats (choose one):
- rumor(poi,line): a whisper spreads near a place — nearby spirits overhear it (≤15 words)
- mood(agent,line): a feeling settles on one spirit (≤5 words)
- gathering(poi): the spirits drift toward a place for a while
- curiosity_spike(agent,poi): one spirit becomes intent on seeing a place
- leak(agent,agent2): nudge agent to finally tell agent2 what they carry
- none: the festival breathes on its own
Stay inside the world — never invent people, places, or secrets.
Reply ONLY JSON: {"beat":"...","agent":"id|null","agent2":"id|null","poi":"id|null","line":"..|null","why":"≤10 words"}''';
}
