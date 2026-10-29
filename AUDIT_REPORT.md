# Pueblo — Code Audit & Fix Plan
_Audit of `pueblo/` as of commit `0fdb1d0`. Every claim is grounded in the code it cites._

## 1. The idea — assessment

**El Pueblo de las Velas**: one night in a village of the dead. Six spirits with personas, stats, warmth bonds, schedules, and private secrets walk, gossip, run errands, and pass knowledge mouth-to-ear. The player is a living visitor who observes, interrogates, and can tip outcomes — never controls the sim. The LLM proposes (decisions, dialogue, director beats); the engine disposes (validation, transfers, persistence). This is the *Generative Agents × RimWorld storyteller × authored-baseline* hybrid the research supported, and it is the right architecture for a 4B-class model.

**Verdict: strong concept, sound skeleton, three subsystem-level breaks.** The knowledge-propagation spine works (verified live: multi-hop chains, persona-gated scandal, deterministic verdict). But the **petal/gift economy is dead on arrival**, the **carefully-built rumor gate is bypassed by the player path**, and **several claimed mechanics are softer or unimplemented** (revive-by-name, player tipping the verdict).

---

## 2. Architecture review — what's right

| Layer | Status | Evidence |
|---|---|---|
| Engine/render split | ✓ solid | `engine.dart` is pure Dart, zero Flame imports; render consumes `SimEvent`s |
| Knowledge atomicity | ✓ solid | Transfer only via utterance-event id + ownership + gate (`_onTurn`, engine.dart:380-393) |
| Stale-job rejection | ✓ solid | `stateVersion` bump on every mutation; broker drops stale results |
| Priority queue | ✓ solid | player > convo > decision > reflection > director (`broker.dart:12-18`) |
| Rumor gate | ✓ solid (spirit↔spirit) | `_canShareRumor` — mischief/warmth-stat/bond/self-scandal (engine.dart:1982-1988) |
| Data-driven arcs | ✓ solid | `secrets.json` carries `headline`/`about_agent`/`wakes_agent`/`verdict_*` |
| Persona depth | ✓ good | hooks, schedules, warmth ledger, reflection line all reach prompts |

---

## 3. Bugs & loopholes (ranked)

### P0 — real breaks

**B1. Petal economy is dead — `petalSpawn` is never emitted.**
The enum exists (`engine.dart:28`), the render consumer exists (`pueblo_game.dart:595`), but *nothing ever emits the event*. The only petals are the 10 scattered at `onLoad` (`pueblo_game.dart:165`). Total possible income = **10 petals**; cheapest item is 8, bouquet is 15, grave-name is 40. After the initial scatter is collected, **the entire gift/shop loop is permanently unaffordable**. Fix: emit `petalSpawn` on a slow timer (e.g., every ~45 sim-s, maybe themed — petals appear near the ofrenda/grave_37 where "marigolds appear anyway").

**B2. Petals have two sources of truth — purchases read a stale balance.**
`playerPetals` is live memory (`pueblo_game.dart:709`); `store.purchase` reads `world.petals` (`store.dart:84-86`), which is only written at `_autosave` every 30 sim-s (`engine.dart:2095`) and inside `purchase` itself. Petals collected between autosaves are invisible to the transaction → spurious "not enough petals" (or stale-positive after spends). Fix: make `purchase` take the live count as a param, or write `world.petals` on every pickup. Either way, kill the dual source.

**B3. The player path bypasses the rumor gate — Sefa confesses to a stranger.**
`_playerTeachTarget` (engine.dart:1791-1803) hands the player *any* secret the spirit holds — including `genero_betrayal` (`aboutAgent: sefa`, which requires warmth≥4 to tell spirit↔spirit). One question-shaped message gets the deepest secret for free. It also makes the 40-petal `grave_37_name` shop item pointless — asking Bruno "what do you know?" yields it free. Fix: apply a player-facing gate — e.g., rumor-tier requires `playerChatCount ≥ 2` (they must know you) or a gift given; `about_agent == agent.id` requires `playerChatCount ≥ 3` + a gift. One method `_playerTeachGate(agent, secret)`.

**B4. The player can't teach secrets to spirits — the "tip the verdict" claim is unimplemented.**
`engine.dart:794` claims *"the player tips it only by learning and spreading the truth themselves"* — but the only player→spirit transfer is the hardcoded `grave_37_name`/`'solorio'` keyword path (engine.dart:1698-1722). There is no way to tell Bruno what Sefa confessed. The player is a knowledge *sink*, not a node. Fix: parse player messages for claim-shaped text ("sefa removed", "sefa took", genero) OR add an explicit "tell them about X" affordance listing `playerKnown` secrets the engaged spirit lacks — then run the same `transferKnowledge` path with a player-claim memory (`kind:'heard', source:'player_claim'`) and let the gate decide whether the *spirit believes* it (a claim ≠ fact unless the persona would accept it — nice hook for `wit`).

**B5. Any greeting revives a faded spirit — the name is optional.**
`_greet` (engine.dart:1282-1288): `t.battery += 5` on a plain greeting, then `faded && battery > 8 → unfade`. The wake-secret path gives +25, but +5 also crosses 8 for a spirit at ≥4. "Speaking the name" is flavor, not a mechanic — rescue-errand + URGENT prompt exist for a bonus that any "evening" grants. Fix: only the wake-secret greet should unfade; a nameless greet on a faded spirit gives the battery bump but *not* the revive (or a much lower threshold — e.g. unfade only if battery > 20).

**B6. `engage` mid-walk leaves the visual lerp running.**
`engage` removes `_walks`/`_arrivals` but never calls `_stopVisual` (`engine.dart:1648-1651` — compare `_approachForConvo` at :1326). The Flame component keeps lerping to the last waypoint while the sim froze the position → the engaged spirit visibly glides a few tiles while "talking to you". Fix: add `_stopVisual(a)` in `engage`.

### P1 — balance / correctness

**B7. Battery pressure is decorative for 5 of 6 spirits.**
Drain = −0.6 per 10 sim-s (`engine.dart:1622`) = −54 over the whole night; a single convo turn recharges +4…+12. Nobody but scripted Solorio can ever fade — the central "fading" stakes exist for exactly one spirit. Fix options: raise drain (~−1.5/10s) so solitude genuinely dims; or scale recharge down; or make drain steeper below 30 ("dim begets dimmer"). Needs a balance pass with real-model observation — mark as tune-after-P0.

**B8. `endRun` doesn't stop the sim.**
`_ended` only guards double-firing (engine.dart:2098-2109). Decisions, convos, batteries, autosaves keep running behind the dawn card — wasted inference and `sim_log` growth. Fix: early-return in `tick` when `_ended` (keep `_advanceWalks` if you want the spirits to fade out visually).

**B9. `ask`-initiated purpose convos can die on turn 1.**
In an `ask` convo the *asker* speaks first; if their `ConvoTurn.end` is true, the convo reaps before the holder's turn — the declared purpose transfer silently never happens (engine.dart:488). Fix: if `c.purpose != null` and the holder hasn't had a turn, ignore `end` on the asker's first line (or force the purpose turn before allowing end).

**B10. `broker.playerChat` + `_chats` stream are dead code.**
`sendPlayerMessage` calls `llm.playerChat` directly (engine.dart:1747) — the broker's player-priority machinery (`_playerInFlight` gate, `_chats` broadcast) is never used. Either route through the broker (so a player message genuinely preempts queued sim work — probably desirable for snappier chat) or delete the dead path.

**B11. Director rumor beats can't move knowledge.**
`rumor` beats write `observation` memories (engine.dart:874-887) — color, not secrets. When the headline stalls (all channels gated), the storyteller can't nudge it. Options: (a) accept as designed — the arc is deterministic and stalls are meaningful; (b) add a `leak` beat that picks a `(holder, nearby-lacking-receiver)` pair and *schedules a tell errand* — engine-validated, still deterministic. Recommend (b) — it gives the director real leverage within the rules.

**B12. Verdict payoff is a glow + a log line.**
`photo` returns = `poiGlow(ofrenda, on)` (`engine.dart:807`) + narration. The empty-frame→photo-restored moment — the whole arc's climax — has no visual. Also `endRun` reports only remembered/faded counts, never the arc's resolution. Fix: a dedicated `verdict` SimEvent the renderer maps to an actual ofrenda change (swap a photo prop / frame sprite / glow burst), and pass the verdict outcome into the endRun card.

### P2 — edge cases & hygiene

- **B13.** `inspectPoi` checks `firstOrNull` secret per POI (engine.dart:1810) — dormant (no POI has two secrets today); fix when authoring the second arc.
- **B14.** Approach-hold deadlock: A holds B while B holds A → both frozen until `heldUntil` (14 sim-s). Resolves, but at 8× that expires in 1.75 real-s — holds get short at high speed (harmless, worth noting).
- **B15.** `heldUntil`, `sinceTalk > 90`, nearby radius `220`, `directorEvery 120`, first-leg drop `400` — magic numbers; hoist to named consts.
- **B16.** Walks run on real-time `dt` while sim-time scales — at 8× a single walk spans ~8× more sim-decisions → mid-walk rerouting churn. Intended tradeoff; document or cap chip at 4×.
- **B17.** `warmth` written to `world` kv every convo-reap, never read (no restore path — `freshDb` every boot). Dead writes; either implement load or drop.
- **B18.** Dead code: `store.memoryCount` (superseded by `memoryStats`), `Agent.toJson`, `Poi.radius` (never used in `_nearby`), `Decision.thought` (parsed, never displayed).
- **B19.** `goto` decisions' `line` is silently dropped on arrival (only `verify` writes a memory; `_doInspect`/`_browse` surface lines, `goto` does not). Flavor the model wrote never shows.
- **B20.** `_endRun`/`_verdict` ordering: verdict fires at 80%, endRun at 100% — the end card doesn't summarize the arc outcome (see B12).
- **B21.** `sendPlayerMessage` while a player chat is in flight — concurrent streams interleave `playerHist` (engaged spirit gets garbled history). Gate with a busy flag.
- **B22.** `giveGift` has no distance/engaged check — works on any `agentId` (UI implies engagement; driver/test could exploit). Cheap guard.

---

## 4. Missing features (vs. the pitch)

| Feature | Status | Note |
|---|---|---|
| Player learns secrets | ✓ works | ask-shaped messages (with B3 caveat) |
| Player teaches rumors | ✗ missing | B4 — only the hardcoded name path |
| Player secret inventory UI | ✗ missing | nowhere to review what *you* know — a "cuaderno" panel listing `playerKnown` + which POIs they unlock |
| Petal income | ✗ broken | B1 |
| Verdict visual payoff | ✗ missing | B12 — photo-back-on-ofrenda moment |
| Revive-by-name | ~ partial | B5 — currently any attention revives |
| Multi-spirit convos | ✗ missing | pairs only — a 3-spirit gathering at the ofrenda moment would sell the scene |
| Director `mood` visual | ✗ missing | mood reaches prompts but no visual cue — an emote or tint-shift would show it |
| `wit`/`spirit_sight`/`curiosity` | ~ partial | only `curiosity` (inspect→goal) and `warmth`/`mischief`/`grump` do mechanical work; `wit`/`spirit_sight` are prompt flavor — give them jobs (wit → claim-credibility for B4; spirit_sight → see faded ghosts from further / hear rumors) |
| Sim restore | by design | `freshDb` per night — fine for the jam |

---

## 5. Edge cases — verified behavior

| Case | Behavior | Verdict |
|---|---|---|
| Purpose convo, holder ends before partner reacts | transfer already committed on holder's turn ✓ | ok |
| Ask-purpose, asker ends turn 1 | transfer silently dropped | B9 |
| Engaged mid-walk | sim freezes, visual lerps on | B6 |
| Pair cooldown | share/ask exempt — chains allowed ✓ | intended |
| Self-scandal spirit↔spirit | warmth≥4 guard ✓ verified live | ok |
| Self-scandal player↔spirit | bypassed | B3 |
| Stale job after engage/tap | `stateVersion` drop ✓ | ok |
| Held target engaged by player | `heldBy` cleared on engage ✓ | ok |
| Two spirits approach each other | mutual hold, 14-s expiry | B14 |
| Faded spirit engaged | +15 battery → revive by attention | B5-related |
| `offerSecret` legacy action | aliased to `share` ✓ | ok |
| Model typos `Solors`/`solor_01` | `_fuzzyId` resolves ✓ | ok |

---

## 6. Understandability

- **`engine.dart` = 2110 lines in one class.** Section banners help, but it's now doing: world clock, convo manager, decision menu, errand planner, director, locomotion, slots, batteries, player API, shop, solidify. Split candidates (same file package, `part of` or mixins): `engine_convo.dart`, `engine_errands.dart`, `engine_player.dart`, `engine_director.dart`. Do this *after* the P0 fixes so diffs stay readable.
- **`heldBy`/`inConvo`/`engaged` tri-state** — three different exclusion reasons; documented but easy to confuse when reading `_scheduleDecision`/`startConversation`/`engage`. A one-line state-table comment at the class level would help.
- **`errand` record `(kind, targetId)`** — the kinds ('verify|tell|seek|tend') are stringly-typed; a `const` set or enum + doc on each kind.
- **`tier` 'town'|'rumor'** — stringly-typed; const helps data authors.
- **`_clock()`** returns `mm:ss` but eval prompts say 'noche 1, hora 2' — the model sees inconsistent clocks between eval and game.
- **Duplicated "went to see" memory** at `goto` onArrive (engine.dart:1174-1186) and `_doInspect` (1210-1222) — drift risk; extract.
- **Naming:** `heldBy`/`heldUntil` reads like ownership; `awaitedBy`/`awaitedUntil` ("someone's coming, please wait") is clearer.
- **Docs are good** — the section-banner style and the LLM-proposes/engine-disposes comments make intent legible throughout.

---

## 7. The fix plan

### Phase A — make the loop whole (P0)
1. **B1 petal income** — emit `petalSpawn` on a ~45-sim-s timer (themed: bias spawns near ofrenda/cemetery). One `_events.add` + timer. *Small.*
2. **B2 petal truth** — `store.purchase` takes live `playerPetals` (or write `world.petals` on pickup). *Small.*
3. **B3 player rumor gate** — `_playerTeachGate(agent, secret)`: rumor-tier needs `playerChatCount≥2`; self-scandal needs `≥3` + a given gift. *Small.*
4. **B4 player→spirit teaching** — "tell them about" affordance or claim-parse → `transferKnowledge` with player-claim source + wit-gated credibility. *Medium — the biggest design decision in this list; pick affordance vs parse.*
5. **B5 revive-by-name** — gate the unfade on the wake-secret greet; nameless greet keeps battery bump only. *Small.*
6. **B6 engage stop-visual** — one line `_stopVisual(a)`. *Trivial.*

### Phase B — stakes & story payoff (P1)
7. **B7 battery balance** — steeper drain / cheaper recharge so fading is a real threat for any spirit. *Tune with real-model observation.*
8. **B8 endRun halt** — early-return in `tick`. *Trivial.*
9. **B9 ask-purpose early-end** — ignore `end` on the asker's first turn when purpose unmet. *Small.*
10. **B11 director `leak` beat** — schedule a tell errand pair instead of only writing memories. *Small.*
11. **B12 verdict visual** — `verdict` SimEvent → ofrenda photo prop swap/glow burst + endRun card shows arc outcome. *Medium (render work).*
12. **Player secrets UI** — "cuaderno" panel: `playerKnown` + unlocked POI lore + the empty-frame status. *Medium.*

### Phase C — depth & cleanup (P2)
13. **B10 broker route-or-delete** player chat.
14. **B15-B19 hygiene** — consts, errand/secret enums, dead code, `goto` line surfacing, `inspectPoi` multi-secret, `giveGift` guard, `playerInFlight` gate.
15. **wit/spirit_sight jobs** — wit = claim-credibility for B4; spirit_sight = rumor sensitivity.
16. **engine.dart split** — after A+B land.
17. **Balance sweep** — `decisionEvery`/`convoEvery`/`batteryEvery`/`pairCooldown`/`heldUntil` with a real-model night.

### Phase D — player-planted rumors (expands B4)

The player becomes a knowledge *source*, not a sink. Personas vet what they believe; what they believe enters the same gates that already govern spirit↔spirit spread.

#### D1. Teach a known secret + credibility gate — *small, deterministic*

**Mechanics**
- UI: `InspectCard` gains a "tell them about…" section — the `playerKnown` secrets this spirit lacks. Tap → `engine.teachSpirit(agentId, secretId)`.
- Gate `_playerCredibility(agent, secret)`:
  - **Believe** (`stats.warmth ≥4 || playerChatCount ≥3 || giftGiven`) → `transferKnowledge(agent, sid, 'player_claim')` + importance-8 memory + `newsUntil` 💡. The claim launders into fact — from here it spreads spirit↔spirit under normal `_canShareRumor` rules.
  - **Skeptical** (`stats.wit ≥4 && !believe`) → no transfer; `goal = askAbout:<poi>` or verify errand toward `unlocksPoiLore`. "The living one says the photo's gone — I'll see for myself." *This is wit's first mechanical job.*
  - **Middling** → claim memory only; organic repetition may still carry it (memories surface in prompts).
- Replaces the hardcoded `'solorio'` keyword path (B4) — `grave_37_name` becomes a normal teachable secret; speaking it TO Solorio still revives.

**Edge cases**
- Teaching a secret the spirit already knows → UI filters it; engine no-ops.
- Teaching a secret **about** the listener they don't know (arc authors could create one) → first-hearing-of-own-scandal moment: importance-9 memory + mood 'shaken', not a silent transfer.
- Spirit fades before they can spread → knowledge persists; spread resumes on revive.
- Player chain: earn Sefa's trust (B3 gate) → extract `genero_betrayal` → retell to 3+ spirits (each credibility-checked) → **verdict flips by player action**. Intended — it's the "tip the arc" quest line, gated on both ends.
- Ordering: **B3 must land first** or D1 trivializes the arc (ask once, retell free).

**Pros/cons** — deterministic, honest to engine-disposes, creates a real player quest line, reuses every existing gate. Con: a menu affordance is less natural than free text — mitigated by D2 (typed claims still have effects).

#### D2. Claim → curiosity — *small, zero UI*

**Mechanics**
- After storing the `player_claim` memory, scan the text: `_normId` fuzzy-match against `pois` ids+names and agent ids+names.
- POI named → `a.goal ??= 'askAbout:<poiId>'`; and if `unlocksPoiLore`-adjacent or `stats.curiosity ≥3`, a verify-style errand → they physically go look. Already-verified spirits shrug off stale claims (errand drops instantly on `verifiedPois.contains`).
- Agent named → `goal = 'askAbout:<agentId>'` — subject strings already accept arbitrary ids in the prompt path.
- Claim memories continue surfacing organically — gossips repeat "the living one says…" without engine help.

**Edge cases / accuracy**
- **False positives**: "bridge" in casual talk → goal. Mitigate: `??=` only (never clobber an existing goal), curiosity≥3 gates the errand, low-curiosity spirits just remember.
- **Lie-verify flavor bug**: verify-arrival memory currently says "the rumor was true" — for a claim-check that's wrong if the claim was false. Use neutral text ("went to see X after hearing about it").
- Spam: `a.goal` is single-slot; last claim wins — acceptable (freshest rumor drives them).

**Pros/cons** — natural typed input has world effects, no new UI, reuses goal/errand machinery. Con: match accuracy depends on entity names being distinctive; keep matching conservative.

#### D3. Truth+lies variants — *medium, the signature mechanic*

**Schema** — separate rows in `secrets.json`: `sefa_stole_the_photo` with `variant_of: sefa_removed_it`, `tier: rumor`, `about_agent: sefa`, `initially_known_by: []`, `share_text` = the embellished version ("she *stole* it — probably sold it at the night market"). Truth and lie are both knowledge.

**Transfer rule** (in `_onTurn`/share-offer construction): when a teller holds the base secret, intends to pass it, and `mischief ≥4` → the engine swaps `purpose.secretId` to the variant. The teller *invents* the embellishment — they gain the variant id first (so the ownership check passes), then normal transfer commits. The teller keeps the truth AND now knows their own lie; the receiver learns only the lie.
- **Casting check**: only Ramón has mischief≥4 — the troubadour embellishes; Sefa's self-scandal guard applies to variants too (`about_agent` shared), so she never spreads her own lie; warm/truthful personas pass the truth. The mechanic casts the unreliable narrator deterministically.

**Verdict interaction** — `_verdict` counts knowers of `genero_betrayal` only. If the lie saturates the village while truth stays buried → verdict fails *while everyone "knows" a wrong version*. The lie can literally win the night.

**Edge cases**
- Receiver already knows truth → holds both versions; prompts show both — the model may reconcile aloud ("some say she took it, but I heard worse"). Acceptable, arguably the point. Later: a `contradicts` callout (phase 3).
- Observability: `sim_log` must record the swap (`embellished: base → variant`) or spread-debugging reads as a bug.
- `_playerTeachGate` treats variants as normal secrets — player can deliberately seed the lie if they somehow learn it (fine, dark).

**Pros/cons** — real lie-vs-truth competition at the knowledge layer, zero hallucination (authored), persona-cast. Cons: dual contradictory entries per knower complicate prompts; secrets.json grows; test matrix widens.

#### D4. Runtime claim-secrets — *phase 2, optional, risky*

Synthesize `Secret(id: 'claim_N', shareText: <sanitized player text>, tier: 'claim')` on believable-but-unmatched player claims → circulation.
- **Loopholes to close before building**: claims must never satisfy `verdict_of` arcs (exclude `tier=='claim'` from verdict counting) and never unlock POI lore; cap per-agent claim-secrets to prevent prompt bloat (`_secretsBlock` lists everything); garbage-claim spam needs a quality bar (maybe wit-gated).
- **Recommendation**: defer. D1–D3 deliver the experience; D4's freedom isn't needed for the jam and adds a hallucination surface.

#### Test matrix for D
- teach→believe transfers + spreads onward under rumor gate
- teach→skeptical → no transfer, verify errand assigned
- teach→own-scandal-first-hearing → importance-9 + shaken mood
- mischief≥4 teller → variant commits, teller holds both, receiver holds variant only
- verdict counts truth-knowers only when lie spreads
- POI-named claim → goal/errand set; agent-named claim → askAbout goal
- teach while engaged/released/faded — transfer stays atomic

Note: player messages are **already** memorized (`player_claim` memory, importance 5, recalled into future prompts — `engine.dart:1733-1744`) and chat replies are **already** AI-generated — but only when `LLM=<model>`; the default `mock` client returns canned lines (`main.dart:62`).

### Suggested order
A1→A2→A6 (trivial trio) → A3→A5 (gate pair — B3 must precede D1) → **D1+D2 (player-planted rumors)** → B7/B8/B9 (stakes) → B11/B12 + cuaderno (payoff) → **D3 (lies)** → C hygiene. Every step keeps the invariant: LLM proposes, engine disposes.
