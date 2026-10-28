# Audit Findings & Technical Fix Plan

Deep-dive audit of the AI simulation, with fixes referencing the code.
No code was changed while writing this plan. (A set of already-tested fixes
from the audit session sits **uncommitted** in the working tree — see §2.)

---

## 1. What the project is (scope, as-built)

**El Pueblo de las Velas** — an autonomous town of the dead (Día de los
Muertos), where six spirits live one night on their own: they walk, run
errands, inspect POIs, gossip, and pass six canon secrets mouth-to-ear.
The player is a living visitor who gathers petals, buys gifts, learns
Solorio's lost name, and can keep spirits from fading. Dawn ends the night
(`dawnAt = 900`, engine.dart:154 — a 15-minute run).

Layers (all present, all wired):

| Layer | Files | Role |
|---|---|---|
| Sim (pure Dart) | `lib/sim/engine.dart` (1630 lines) | world clock, errands, decisions, convos, batteries, knowledge, player verbs |
| Inference | `lib/sim/broker.dart`, `llm.dart`, `gemma_client.dart` | serialized priority job queue over qwen3:4b (macOS dev) / Gemma 3n (Pixel ship) |
| Persistence | `lib/sim/store.dart` | sqlite: memories, knowledge (with lineage), events, sim_log |
| Prompts | `lib/sim/prompts.dart` | knowledge-isolated decision / convo-turn / player-chat / reflection |
| Render | `lib/game/*` | Flame: tiles, sprites, bubbles, labels, camera, driver bridge |

## 2. Live audit evidence (this session)

Verified working, from `sim_log` + driver state dumps + screenshots:

- **Walking with purpose** — every agent moved between snapshots; decide
  log shows errand-driven gotos: `bruno→ancient_tree` (verify errand — he
  knows the ceiba is hollow), `ines→fountain`, `sefa/luz→bridge`, `ramon→plaza` (tend).
- **Contextual speech** — "Bruno? You there?" (Solorio, fading, curious),
  "Hail, Solorio, do you still feel the light?" (Ramón, troubadour).
- **World lives occluded** — the Timer pump (pueblo_game.dart:154) kept
  simTs advancing while the window was hidden (previously froze).
- **Knowledge transfers + second hops** (earlier run): sefa→luz
  cantina_recipe @114, luz→bruno same secret @235 — mouth-to-ear chains.
- **Sprites/labels** — village zones read correctly; fixed a label-occlusion
  bug ("Doñ"/"Ramó" — depth-sorted bodies painted over name tags).

Found broken (the three audit bugs, all fixed in the working tree, uncommitted):

1. **Verify-errand infinite loop** — `goto` cleared the errand on arrival
   but never marked `verifiedPois`, so `_ensureErrand` re-assigned it
   forever (luz/sefa cycled `goto(bridge)` 3+ times, tell phase never
   started, zero transfers that run). Fix: arrival = seeing; both
   `goto` onArrive and `_browse` now add `verifiedPois`.
2. **Solorio's rescue invisible to the LLM** — Bruno knows his name but
   nothing in the decision prompt connected "fading spirit nearby" to
   "you can save them". Fix: `URGENT:` rescue line in decisionPrompt +
   data-driven `wakes_agent` in secrets.json (was hardcoded to
   solorio/grave_37_name in `_greet`).
3. **Model picks actions without targets** — `{"action":"goto","target":"null"}`
   wasted decisions. Fix: null-string normalization + errand/nearest-POI
   fallbacks in `_execute`.

All 15 sim tests pass with these fixes. **Not yet committed** — review
then say the word and I'll commit.

## 3. Open issues (with code refs) — the fix plan

### P0 — correctness of the loop

**P0.1 Engagement drops approaches instead of deferring them.**
Spec (PLAN.md §11.9 point 2) says approaches targeting the engaged
spirit are "deferred or retargeted". Code: every approach case does
`if (t != null && !t.engaged && !t.inConvo) {...} else _fallbackStroll`
(engine.dart:728-780, share/ask/askAbout same pattern) — the intent is
discarded, not queued.
*Fix:* add `final Map<String, Decision> _pendingApproach` keyed by
initiator id. On the blocked branch, store the decision + set
`lastActedAt = simTs + decisionEvery` so the retry lands in the next
slot; in `_scheduleDecision`, if `_pendingApproach[agent.id]` exists and
the target is now free, offer that action first. Cap: one retry, then
drop (prevents stalker loops). Test: engage B, scripted greet(A→B)
decision, disengage, assert the retry fires and the convo starts.

**P0.2 Tell-errand targeting ignores distance.**
`_ensureErrand` picks `bestCount` = max knowledge-diff (engine.dart:599),
so a spirit can pick a partner across the map and ping-pong when a
nearer partner has the same diff.
*Fix:* score candidates `diff - _dist/(4*kTile)` (a 400px walk ≈ −1
secret), and add hysteresis: don't retarget while the current target
still lacks ≥1 held secret. Test: place three agents, assert nearest
equal-diff target wins.

**P0.3 No rescue guarantee for a fading spirit.**
The rescue affordance (URGENT line, working tree) only appears if a
name-holder happens to be within 220px at a decision slot. Bruno's home
(gravedigger_hut) is near Solorio so it usually converges — but
"usually" can silently kill the game's spine.
*Fix:* in `_ensureErrand`, insert a priority above verify: if any agent
`faded && battery < 20` and the decider holds a `wakes_agent` secret
for them → errand = ('seek', faded.id). The existing seek→approach→
greet chain does the rest deterministically. Test: fade B, script A's
decisions, assert a wake-greet occurs within N sim-seconds.

**P0.4 Fuzzy id resolution for model typos.**
Live: `"Solors"`, `"Sefas"`, `target:"solor_01"` — all fell to
fallbackStroll. Currently only exact ids resolve (agents[target]).
*Fix:* tiny alias pass in `_execute`: normalize lowercase, strip
diacritics, then match by prefix; if still nothing, Levenshtein ≤1 over
agent ids + poi ids (≈20 ids, trivial cost). Keep the fallback path as
the last resort. Test: scripted decision `target:'solorio!'` resolves.

### P1 — depth of the AI simulation (baseline + emergent)

**P1.1 AI Storyteller (the RimWorld director pattern).**
RimWorld's storyteller reads colony state, spends a threat **point
budget**, and backs off after losses (adaptation) so stories get pacing
instead of noise. Our equivalent — a `director` job, lowest priority in
`JobKind` (broker.dart:10), run every ~120 sim-s against a
**deterministic state digest** (batteries, fading count, knowledge
coverage per secret, convo density, time-of-night):

```
digest = "night 0:34. batteries: luz 62, bruno 80... solorio fading(2).
secrets known: tree_is_hollow 1/6, grave_37_name 1/6, ...
recent: luz told bruno bridge_memory; ines inspected fountain."
palette: rumor | mood | gathering | curiosity_spike
Reply ONLY JSON: {"beat":"...","agent":"id|null","poi":"id|null",
                  "line":"≤15 words"}
```

Engine validates against canon (guardrail §11.8: LLM proposes, code
disposes) and applies exactly one:
- `rumor` → inject an importance-6 memory into 1-2 agents near the poi
  ("someone whispered: …") — surfaces later via recall (store.dart:145
  already ranks by importance/recency/entities).
- `mood` → set a soft `mood` field read by decision/convo prompts.
- `gathering` → override all errands to ('tend', poi) for ~60 sim-s.
Budget+damping, RimWorld-style: max 1 beat / 2 min; no beat while a
fading-rescue or purpose convo is active; back off for 120 sim-s after
any beat (tension → release).
Files: `broker.dart` (JobKind.director), `engine.dart` (digest + apply),
`prompts.dart` (directorPrompt), `llm.dart` (client method).

**P1.2 Baseline story = Wildermyth roles.**
Wildermyth authors story beats as **templates with role slots**, cast
from live character aspects ("the casting call"); the play improvises
inside the authored skeleton. Ours:
- Add one authored `hook` line per persona in `personas.json` (Bruno:
  "counts graves when nervous", Inés: "believes the fountain talks
  back", …) — includes it in decisionPrompt.
- Author 5-10 beat templates keyed to the spine: "the doubter scoffs at
  a rumor", "the witness tells the doubter", "the fading one asks for
  their name", "the keeper of names shares it". The director (P1.1)
  casts roles by live state: doubter = highest grump; witness = most
  recent learner; fading one = battery < 20.
This is the direct answer to "baseline, but scenarios continue as per
the people talking": baseline = canon secrets + Solorio spine + hooks;
emergence = casting + conversations + knowledge spread. Pure emergent
(no baseline) is a trap with a 4b model — purpose-bound prompts are
coherent; freeform drifts (verified live: purpose convos stay on topic,
ambient lines wander).

**P1.3 Majora's Mask schedule layer.**
MM's world reads as alive because NPCs follow authored time-tables and
key events fire **whether or not the player attends** (Sakon robs at
midnight regardless; Anju's choice changes with involvement). Ours:
- `personas.json`: add `schedule: [{"at": 120, "poi": "fountain"}, …]`
  per spirit — deterministic baseline routine; `_ensureErrand` consults
  the schedule slot when no verify/tell/rescue errand is active (tend
  becomes time-phased instead of always-home).
- One town moment per night: at ~60% of `dawnAt`, everyone's errand
  becomes ('tend','ofrenda') — the Día gathering, a visual finale the
  player can attend or miss. Our sim already runs unwatched (the pump),
  so this genuinely happens without the player — MM's magic.

**P1.4 Relationship model.**
Conversations currently leave no interpersonal trace beyond memories.
Add `Map<String, int> warmth` per Agent (models.dart): +2 meaningful
convo, +5 receiving a secret, −1 grump-rebuff. Surface in
decisionPrompt ("you're close to X") and use in tell-errand targeting
(P0.2 score: prefer warm pairs at equal diff). Persist in the existing
`agents.stats` JSON column (store.dart:117 saveAgent). This is the
Generative-Agents "relationship" pillar our recall scoring partially
covers via entities but prompts never see.

**P1.5 Reflections barely surface.**
Reflections store at importance 7 (engine.dart:657-666) and CAN win the
recall ranking, but they compete with 5 recent memories and lose.
*Fix:* fetch the agent's latest `kind='reflection'` memory (one query,
cache in `_memCache`) and pass it as its own prompt line —
decisionPrompt: "You've been thinking: …". One param, deterministic
fetch, no LLM involvement. This closes the Smallville loop:
reflection → (retrieved) → planning.

### P2 — polish & measurement

**P2.1 Convo turn cap** — `c.transcript.length >= 4` (engine.dart:450)
ends purpose convos before the listener reacts when the holder stalls.
Raise to 6 when `purpose != null`; keep 4 for small talk.

**P2.2 Dawn finale** — the `endRun` card exists; the gathering beat
(P1.3) makes dawn earned. Optionally a `SimEventType.dawn` visual
(wash) — event type already declared (engine.dart:29).

**P2.3 Eval regression metrics** — extend `bin/eval.dart` with a
headless "night" mode: N decisions through MockLLMClient, assert
purpose-pick rate (share/ask ≥ 60%), transfers per 100 decisions,
rescue latency. Makes P0/P1 fixes measurable, catches drift when the
model or prompt changes.

**P2.4 Balance knobs** — decisionEvery 12.0 / convoEvery 5.0 /
batteryEvery 10.0 (engine.dart:120-122) are untuned constants; after
P1.1-1.3 land, sweep them with the eval harness rather than by eye.

## 4. Game-reference synthesis (what to steal, from where)

- **Stanford Generative Agents** (arxiv 2304.03442) — memory stream →
  retrieval (importance/recency/relevance — we have this, store.dart:145),
  reflection (have, under-surfaced → P1.5), planning (errands, have),
  reaction (verify errand, have). Their insight: believability comes
  from the full loop, not dialogue quality.
- **RimWorld AI Storyteller** (teemo.dev systems guide; Sylvester's
  "story generator" thesis) — a director that reads state and paces
  beats with a budget + adaptation damper. Steal the whole pattern
  (P1.1): drama as a product of measured pacing, not raw randomness.
- **Wildermyth** (Worldwalker; writer's wiki + GDC talk) — authored beat
  templates with role slots cast from character aspects; "avoid breach
  of trust / out-of-character" as design law (mirrors our §11.8
  guardrails). Steal roles + hooks (P1.2).
- **Majora's Mask** (schedule scholarship, Zelda wiki schedule tables) —
  authored time-tables + events that fire without the player; reactive
  changes when the player involves themselves. Steal schedules + the
  un-attended town moment (P1.3) — our occluded-window pump makes this
  real, not faked.
- **Stardew / Pokémon Emerald** (per repo's STARDEW_RESEARCH.md) —
  readable routine + consistent map; the visual half of believability.
  Largely done (village rebuild); the schedule layer completes it.
- **NVIDIA ACE / Dead Meat / GoodAI "AI People"** (GDC 2025, NVIDIA
  blog) — on-device SLMs with character depth + environment awareness
  + memory: validates the Gemma 3n Pixel ship path; their "Game
  Conscious" layer = our deterministic engine around the LLM.

**Verdict on baseline vs pure-emergent:** keep the baseline. Every
system that works at small scale (ours, Wildermyth, MM) is a hybrid:
authored rails, emergent filling. The baseline is cheap (6 secrets, 6
personas, 1 spine, 10 beats) and it's what makes a 4b model look wise.

## 5. Suggested order

1. Commit the working-tree fixes (§2) — they unblock the tell phase.
2. P0.1 + P0.4 (deferred approaches, fuzzy ids) — small, testable.
3. P1.5 + P0.2/P0.3 (reflection line, weighted/rescue errands) — small.
4. P1.3 schedules + gathering (deterministic, no new inference).
5. P1.1 director + P1.2 roles/hooks (the big AI layer; eval first).
6. P2 measurement + balance sweep.
