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
  }) {
    final s = a.stats;
    return '''
You are ${a.name}. ${a.persona}
Stats (0-5): curiosity ${s.curiosity}, wit ${s.wit}, warmth ${s.warmth}, spirit-sight ${s.spiritSight}, mischief ${s.mischief}, grump ${s.grump}.
Pueblo de las Velas, a village of the dead at night. Stay in character.
Never invent people, places, or events.
Now: $simClock. You stand at $place. Nearby: $nearbyEntities.
You remember: ${memories.isEmpty ? 'nothing recent' : memories.join(' | ')}.
Secrets you know: [${_secretsBlock(a)}]
Choose ONE of: ${allowedActions.join(', ')}. Reply ONLY JSON:
{"thought":"≤15 tokens","action":"...","target":"..|null","subject":"..|null","line":"≤12 words","mood":"neutral|warm|curious|sad|scared"}''';
  }

  /// ONE speaker's next turn — partner's private state never appears here.
  String convoTurnPrompt(
    Agent speaker,
    Agent partner, {
    required List<String> transcript,
    required String context,
    String? askedAbout,
  }) {
    final s = speaker.stats;
    final ask = askedAbout == null
        ? ''
        : '\nThey are asking you about: $askedAbout. Answer honestly from what YOU know.';
    return '''
You are ${speaker.name}. ${speaker.persona}
Stats (0-5): grump ${s.grump}, warmth ${s.warmth}, mischief ${s.mischief}.
Talking with ${partner.name} ($context). Mood: ${speaker.faded ? 'sad' : 'neutral'}.
Conversation so far:
${transcript.isEmpty ? '(no one has spoken yet)' : transcript.join('\n')}
Secrets you know: [${_secretsBlock(speaker)}]$ask
Write YOUR next line. ≤14 words, in voice.
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
}
