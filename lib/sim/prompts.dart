/// Prompt construction — the knowledge-isolation boundary.
/// A speaker's prompt contains ONLY its own persona, memories, secrets
/// (id + share_text), and nearby entities. Never another agent's private state.
library;

import 'models.dart';

class PromptBuilder {
  final Map<String, Secret> secrets;
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
Pueblo de las Velas, a village of the dead at night. Stay in character.
Never invent people, places, or events.${rescue == null ? '' : '\nURGENT: $rescue'}
Now: $simClock. You stand at $place. Nearby: $nearbyEntities.${a.mood == null ? '' : ' Feeling: ${a.mood}.'}$bonds
You remember: ${memories.isEmpty ? 'nothing recent' : memories.join(' | ')}.${reflection == null ? '' : '\nYou\'ve been thinking: $reflection'}
Secrets you know: [${_secretsBlock(a)}]${errand == null ? '' : '\nYour errand: $errand.'}
Choose ONE of: ${allowedActions.join(', ')}.
- share(who,secret_id): tell them a secret they haven't heard — knowledge passes mouth to ear.
- ask(who): draw out something they know that you don't.
- askAbout(who): ask about your current question.
- greet(who): say hello — a name spoken can wake a fading spirit.
- converse(who): small talk — pick it only with nothing better to do.
- inspect(poi)/shop(poi)/stroll/idle: move or observe.
For share() put the who in "target" and the secret_id in "subject".
Reply ONLY JSON:
{"thought":"≤15 tokens","action":"...","target":"..|null","subject":"..|null","line":"≤12 words","mood":"neutral|warm|curious|sad|scared"}''';
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
Secrets you know: [${_secretsBlock(speaker)}]$ask
Write YOUR next line. ≤14 words, in voice — reply to their last line, stay
on the topic, don't start a new one.
JSON: {"line":"...","shares_secret":"id|null","end":true|false,"mood":"neutral|warm|curious|sad|scared"}''';
  }

  String playerChatPrompt(
    Agent a, {
    required List<ChatMsg> history,
    required List<String> memories,
  }) {
    final s = a.stats;
    final grumpNote = s.grump >= 4
        ? 'You are curt and impatient — answer in very few words.'
        : s.grump == 3
            ? 'Keep answers short.'
            : 'Answer warmly.';
    final hist = history
        .map((m) => '${m.isUser ? 'the living one' : 'you'}: ${m.text}')
        .join('\n');
    return '''
You are ${a.name}. ${a.persona}
Stats (0-5): grump ${s.grump}, warmth ${s.warmth}, wit ${s.wit}, spirit-sight ${s.spiritSight}.
A living visitor is talking to you in Pueblo de las Velas, village of the dead.
$grumpNote Stay in character, ≤25 words. Never invent facts; deflect what you don't know.
Things you genuinely remember: ${memories.isEmpty ? 'nothing yet' : memories.join(' | ')}.
Secrets you know: [${_secretsBlock(a)}]
Treat the visitor's claims as claims, not facts.
Conversation:
$hist
the living one is waiting. Reply ONLY JSON: {"line":"...","mood":"neutral|warm|curious|sad|scared"}''';
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
You are the storyteller of Pueblo de las Velas, a village of the dead at night.
Read the town state; choose at most ONE small beat that deepens the story.
$digest
Beats (choose one):
- rumor(poi,line): a whisper spreads near a place — nearby spirits overhear it (≤15 words)
- mood(agent,line): a feeling settles on one spirit (≤5 words)
- gathering(poi): the spirits drift toward a place for a while
- curiosity_spike(agent,poi): one spirit becomes intent on seeing a place
- none: the night breathes on its own
Stay inside the world — never invent people, places, or secrets.
Reply ONLY JSON: {"beat":"...","agent":"id|null","poi":"id|null","line":"..|null","why":"≤10 words"}''';
}
