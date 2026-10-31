# MYSTERY_PLAN — "El Cuadro Robado" (The Stolen Picture)

Replaces "The Uninvited Dead" arc (`photo_missing → sefa_removed_it →
genero_betrayal`, `truth N/4`) with a proof-driven whodunit the agents
solve themselves — catalyzed, not scripted, by the player.

---

## 1. Premise

**Día de los Muertos, the great ofrenda.** The village's beloved dead
singer — **Doña Mercedes "La Golondrina"**, the famous voice of three
generations — had her portrait on the ofrenda. Tonight the frame stands
empty. Someone took it.

**The culprit: Ramón el Trovador.** Motive (authored, deterministic):
La Golondrina is *remembered* — her candle burns bright, her songs on
every lip — while Ramón's own name dims a little more each year (he is
the fading-arc's mirror: jealousy of the remembered). He took the frame
to dim her. A liar by trade — he deflects with confident, unproven
accusations against Bruno ("the gravedigger carried a sack past the
ofrenda") and Carmen ("she collects photos for her nameless graves").

**Why agents can solve it but won't:** the decisive proofs exist only
in *private whispers* — things spirits mutter to themselves or tell one
trusted ear. Those never propagate. Only the player sees them. The
player must carry them into the world as "thoughts."

---

## 2. Story bible

### Cast

| Spirit | Mystery role |
|---|---|
| **Ramón** (culprit) | Lies, deflects, counter-accuses; confesses when proof converges |
| **Violeta** | Child witness — heard *humming* near the ofrenda (private whisper, never shares — adults scare her) |
| **Bruno** | Falsely accused — sack held grave-flowers (alibi held by **Carmen**) |
| **Carmen** | Falsely accused — was tending Solorio's candles (alibi held by **Aurelio**) |
| **Sefa** | Sharp-tongued gossip — repeats accusations fastest, twists them |
| **Abuela Inés** | Noticed the empty frame first; memory-keeper, weighs proofs |
| **Padre Aurelio** | Ofrenda keeper — noticed the candle *re-lit* by the thief's hand |
| **Solorio** | Fading — optional witness; must be name-woken to recall seeing someone at dusk |
| **Tía Luz** | Saw Ramón *pocketing something silver* near the cantina (private whisper to Sefa) |

### Real proofs (canonical claims — `proof: true`)

| # | Proof | Enters play via |
|---|---|---|
| P1 | A **guitar pick** (mother-of-pearl, Ramón's) found under the frame | Aurelio inspects the ofrenda — POI `inspect` reveals it to whoever looks |
| P2 | **Humming heard** at the ofrenda — Violeta whispers it to herself | **private whisper** — player must overhear + relay |
| P3 | Ramón **knows the frame's crack** — a detail only the thief could know | **private whisper** — he mutters it to himself, guilt-leaking |
| P4 | **Silver flash** in Ramón's hand — Luz whispers it to Sefa alone | **friend-only whisper** — lands in Sefa's knowledge but `private` flag blocks re-share — still trapped |
| P5 | **Wax on his sleeve** — fresh candle wax, matches the re-lit candle | slow-burn: surfaces if Ramón is `ask`ed about the candle while holding guilt |

### The culprit's accusations (claims, `proof: false`)

- "Bruno carried a sack past the ofrenda at dusk" — spread eagerly
- "Carmen collects pictures for her nameless graves" — second wave
- Debunk rules (deterministic): an accusation against X dies in mouths
  that hold X's alibi proof. Alibis = proofs too (`bruno_alibi`,
  `carmen_alibi`) — Carmen/Aurelio hold them privately at boot.

### Resolution

Deterministic ledger, not spread-count:

- `proofSet(culprit)` = distinct real proofs naming the culprit held by
  **≥2 different non-culprit spirits**.
- **Confession threshold: 3.** When 3 distinct proofs point at Ramón in
  circulation, the next `ask`/`confront` on him by a spirit holding any
  proof triggers the confession → photo restored to the ofrenda
  (`poiGlow` + frame swap) → resolution card.
- Below threshold, confrontation is still *allowed* (anyone can
  accuse) — Ramón **denies** (LLM words, persona voice) and
  counter-accuses (deterministic pick: his two scripted targets).

**The gate that makes the player matter:** the village's own
circulation can never reach 3 — P2/P3 are private whispers, P4 dies in
Sefa's ear. Without the player relaying overheard whispers, the ledger
stalls at 1–2 proofs. Agents can *suspect*; they cannot *prove*.

---

## 3. Mechanics — what changes, what reuses

### 3a. Claim kinds (extends existing claims)

```dart
class Claim {
  String id, text;
  Map<String,String?> version;   // mouth → twisted wording (existing)
  List<String> about;
  String kind;        // NEW: 'rumor' | 'accusation' | 'proof'
  String? pointsTo;   // NEW: agent id an accusation/proof fingers
  bool private;       // NEW: friend-only — never re-shares
}
```

- `_canPassClaim` returns false when `private == true` — a friend-only
  whisper reaches its confidant and dies there. Deterministic dead end.
- Twisting mutates `version` wording; `kind`/`pointsTo` are canonical —
  a proof stays a proof even mangled in transit.
- `_plantClaim` (player path): classifying "X took the picture" →
  `accusation`. Player can lie too — same weight as Ramón's lies:
  entertaining, debunkable, no proof backing.

### 3b. Private whispers (player-only visibility)

New scheduler `_whisperRoster`: scripted beats per spirit, emitted as
`SimEventType.thought`/quiet `say` **without touching any ledger** —
the player reads the bubble; no agent learns it.

```
violeta, @plaza_edge, ~T+90s : "…someone was humming by the big frames."
ramon,   @cantina,    ~T+4min: "…the crack ran down the left side—
                                nobody knows that but me."
luz→sefa (friend-only, claim private:true): "he pocketed something
                                silver — I saw it at the cantina."
```

- Each beat loops until its content has been *relayed* (a claim with
  matching canonical proof id exists) — no permanent misses, no
  dead ends.
- Whispers during `inConvo`/`engaged`/`faded` defer to next slot.

### 3c. Player input = "a thought"

Presentation shift only — same pipeline:

- Prompt framing: "the living one's words arrive as a *thought* in your
  head — it's yours now; you don't know where it came from."
- Relayed whisper → planted claim keeps verbatim player text, but
  `kind` upgrades to `proof` **only if** the text matches an authored
  whisper canon (deterministic `_normId` match on the whisper's key
  phrase) — the player can't mint proofs from thin air, only carry real
  ones. Everything else lands as accusation/rumor.
- Orders unchanged: "ask Ramón about the frame" still queues directive.

### 3d. Suspicion ledger + confrontation (replaces verdict)

- `proofSet(target)` → distinct `proof`-claims `pointsTo==target` held
  by ≥2 distinct holders. Checked on every proof learn (replaces
  `_checkVerdict`).
- `confront` decision offered when a spirit holds a proof and the
  target is free — weighted by grump/mischief.
- Confrontation convo: `askedAbout` = accusation; confronter's held
  proof ids injected into prompt so the model cites them.
- Culprit branch (deterministic gate): `proofSet < 3` → deny +
  counter-accuse (plants accusation claim vs Bruno/Carmen alternately);
  `≥3` → `confession` event → ofrenda frame restores → resolution card
  shows `verdictPass`-style line ("The thief confessed — the portrait
  returns to its candle.").
- Remove: `truthCount`, `_checkVerdict`, `_verdict`, `verdictResolved`,
  `verdictOf` handling, `truth N/4` chip text. `verdict` event type
  stays as the resolution event (rename payload: `culprit`, `proofs`).

### 3e. Stall nudges

- `lastPlayerMsgAt` (real player messages only). If a spirit gets a
  decision slot while `simTs - lastPlayerMsgAt > 240` and no directive
  is in flight: small chance (per-spirit cooldown ~60 sim-s) to emit a
  `thought` — deterministic lines like
  `"…if a thought came to me about the missing frame, I'd follow it."`
  Signals "the sim wants input" without breaking immersion.

### 3f. Intro cinematic (in-engine, no video asset)

Boot sequence (~10 s, skippable on tap):

1. Brief dim overlay on the village.
2. A **shadow** agent (single darkened sprite — tint `#000` over any
   spare sheet, no face) walks plaza→ofrenda slot (existing `_routeTo`).
3. `poiGlow` flicker on ofrenda → frame sprite swaps to empty-frame
   variant → shadow despawns toward cantina.
4. Two nearby spirits emit scripted `say` lines:
   *"…wait — La Golondrina's frame. It's EMPTY."* /
   *"Who takes a picture off the ofrenda — tonight of all nights?"*
5. Overlay lifts → sim begins (agents get the `photo_missing` starter
  knowledge per `initially_known_by`).

Choice: in-engine over video asset — cheaper, driver-testable,
consistent pixel look, skippable. A real video would need an asset +
platform codec plumbing for marginal gain.

---

## 4. UI changes

- **Remove** `truth N/4` text + the truths sheet rows.
- **New chip `🕵️ case N/3`** (N = proofs naming the culprit in play —
  i.e. `proofSet` size, capped 3). Tap → **case file** sheet:
  - *Proofs in play* — text + mouths (player-known only; unknown →
    "a proof you haven't heard yet")
  - *Accusations afloat* — `accusation` claims + mouths + who they point at
  - *Whispers you've overheard* — private beats the player saw (ledger of
    relayed vs unrelayed) — **this is the player's job board**
- Resolution card reuses existing `verdict` event path with
  `culprit` + confession text.

## 5. LLM vs deterministic split (unchanged contract)

| LLM owns | Engine owns |
|---|---|
| Denial/confession wording, accusation phrasing, persona flavor, suspicion banter in convos | Proof ledger, `pointsTo`, private gating, alibi-debunk, confession threshold, photo restore, whisper schedule, stall nudges |
| `accuse`/`confront`/`ask` *proposals* | Validation — only authored `pointsTo` values accepted; a hallucinated suspect name degrades to generic gossip |

## 6. Edge cases

| Case | Handling |
|---|---|
| Culprit fades before confession | `confront` on faded target fails; resolution needs him awake — ties to the name-speaking mechanic (speak "Ramón" to keep him) |
| Player plants false accusations | Allowed — `accusation` kind, debunkable by alibis; a player's lie can stall the village (a real cost — documented) |
| Whisper missed forever | Beats loop until relayed — never permanently lost |
| Twisted proof wording | `version` mutates text; `kind`/`pointsTo` canonical — "silver thing" can't become "guitar pick" but stays proof #P4 |
| Culprit learns his own accusation | Harmless — `pointsTo` targeting self is ignored in his tally |
| Two spirits confront simultaneously | `conversations` exclusivity + heldBy already serialize it; second confronter retries/defers |
| Overhear → relay of a *friend-only* whisper | Player carries it into a claim — the trap is broken by design (that's the gameplay) |
| Relaying the same whisper twice | `_normId` claim dedupe — already exists |
| 8× fast-forward | Whispers are visual beats — min display ~1.5 real-s; stall nudges throttled by sim-time |
| Save/load mid-case | Claims/proofs persist via existing ledger store; whisper-relayed set needs a persisted flag |
| LLM invents a proof | `kind: proof` only assigned by authored canon match — LLM output can never mint a proof |

## 7. Pros / cons

**Pros** — mystery is *emergent*: agents genuinely reason over held
evidence; player has a real job (the only bridge over private
whispers); liar-culprit creates drama beats (deny → counter-accuse →
crack); fading mechanic gains story weight; removes the artificial
"4 mouths know one secret" counter.

**Cons** — more authored content to write (~5 proofs, whisper lines,
denial/confession prompts); private-whisper gating means a *passive*
player can stall the arc (mitigated: stall nudges + loop-until-relayed);
cinematic adds a boot-path branch; culprit is fixed in v1 (replay
sameness — randomization deferred).

## 8. Phases

| # | Work | Touchpoints |
|---|---|---|
| P0 | Story bible → `secrets.json` rewrite (proofs/accusations/alibis), persona hooks (Ramón motive/voice, witness hooks) | assets/data |
| P1 | Claim kinds + `pointsTo` + `private` + pass/validation rules | models.dart, engine.dart |
| P2 | Whisper roster scheduler + relay-detection + player-only events | engine.dart, pueblo_game.dart |
| P3 | `proofSet` + `confront` + confession + photo restore; remove verdict machinery | engine.dart |
| P4 | Culprit behaviors (deny/counter-accuse/nervous) + confront prompts | prompts.dart, engine.dart |
| P5 | Case-file sheet + `case N/3` chip; delete truths sheet | main.dart |
| P6 | Stall nudges | engine.dart |
| P7 | Intro cinematic (shadow walk, frame swap, scripted lines, skip) | pueblo_game.dart, engine.dart |
| P8 | Tests: proof gating, private no-share, debunk, confession threshold, whisper relay, stall nudge | sim_test.dart |

## 9. Open questions for you

1. Culprit locked as **Ramón** — or do you want him swappable per run?
2. Singer name: **La Golondrina** ok, or your own name for her?
3. Soft-fail: if the player never engages, should the case stay cold
   forever (festival just goes on) or end with "the whisper died" text?
4. Whispers visible only when the player's camera is near the speaker,
   or anywhere on the map? (Near-only is more "detective"; anywhere is
   more forgiving.)
