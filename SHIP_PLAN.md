# SHIP_PLAN — stabilize, shrink, ship (daytime edition)

Goal: a **playable, daytime** Pueblo de las Velas that works with or
without a live LLM, in the least time possible. Not a rebuild — the
architecture is already the pattern successful projects converged on
(engine owns state, LLM owns voice). This plan removes the night→dawn
clock; the festival runs in perpetual day and the authored arc resolves
on **knowledge thresholds**, not a countdown.

## 0. What changes conceptually

| Before (night) | After (day) |
|---|---|
| Night ends at `dawnAt=900` → `_endRun` halts the world | No halt — the festival is perpetual; sim keeps running |
| Verdict fires at 80% of the clock, earned or not | Verdict fires when **≥4 spirits know the deep truth** (pass) — or at a *soft* pacing moment only as a fallback fail |
| Dawn card ends the session | Resolution card shows the outcome; world continues |
| HUD counts down to dawn | HUD shows festival progress: "truth reached 3/4 mouths" |
| Night palette | Keep current twilight look for now — palette swap is polish (P3) |

Día de los Muertos is literally a daytime festival — spirits walk among
the living during the celebration, so the theme actually fits *better*.

## Phase 1 — Stability (the real bugs, mostly done)

Done already: `_send` try/finally (wedged button), `OLLAMA_BASE` +
`adb reverse` in `run_pixel.sh`, `llmAlive` HUD badge, INTERNET
permission, `textInputAction: send`, error/empty beats.

- [x] `SimStore.open`: `PRAGMA busy_timeout=5000` — a second instance waits instead of throwing mid-stream (the bug that killed the send button)
- [x] `run_pixel.sh`/`run_macos.sh`: warn if another app instance holds the DB (single-instance guard — one `pueblo_sim.db`, ever)
- [x] **LLM auto-fallback**: if `OllamaClient.probe()` fails at boot, quietly boot with `MockLLMClient` and badge `offline → mock`. The game must always open playable. (`--strict-llm` dart-define keeps hard failure for debugging)

Verify: launch twice → second instance warns, first keeps running; kill
Ollama mid-session → badge flips red, replies degrade to listen-beats,
no wedged send.

## Phase 2 — Remove the day-passed clock (the ask)

Engine (`lib/sim/engine.dart`):
- [x] `dawnAt` → rename semantics to `festivalAt` (pacing clock only, no end-of-world)
- [x] `_verdict()` becomes **event-driven**: evaluate on every secret learn — fire when `verdictOf`'s deep-truth knowers ≥4 (pass) or when `festivalAt` elapses with <4 (fail, soft fallback so the arc can still close)
- [x] Delete `if (simTs >= dawnAt) _endRun()` — world never halts
- [x] `_endRun` → `_resolution()` — emits the same `endRun` event payload (remembered/faded/verdict) as a *report*, not a stop; fires once when the verdict resolves. World continues after.
- [x] The 60% "all gather at ofrenda" pull stays — it becomes the festival-ceremony moment tied to `festivalAt`, not dawn
- [x] Battery drain: keep (remembrance is the theme, independent of clock), maybe soften `-1.5/10s` → `-1.0/10s` since there's no deadline pressure to beat

UI (`lib/main.dart`):
- [x] `dawnTimer` countdown chip → `festivalChip`: shows `truth N/4` — how many mouths hold the deep truth (live count from engine)
- [x] Dawn card → resolution card on `verdict`/`endRun` event, dismissible; world visibly continues behind it
- [x] `_Hud` text: "grown tonight" → "grown today"

Verify: `speed 8` through two full `festivalAt` windows — world still
alive, verdict resolves on threshold early when gossip travels fast,
resolution card appears once, spirits keep moving after.

## Phase 3 — Mock mode is a real game mode

The blocker for "game works" everywhere: LLM must be optional.

- [x] `MockLLMClient.playerChat` returns `PlayerReply`-shaped output sometimes (`{"say":"...","react":"curious","share_with":"ramon"}`) so believe/spread/twist paths exercise in mock
- [x] Mock convo turns occasionally pass held secrets/claims (already does via prompt regex — verify claim offers appear in mock prompts)
- [x] Document `LLM=mock` as the offline/demo path; auto-fallback from P1 makes it automatic

Verify: full arc completable on `--mock` — claims travel, ≥4 learn the
truth, verdict passes, resolution card shows.

## Phase 4 — LLM budget (the latency killers)

- [x] Single in-flight decision per spirit (already true by design — audit the queue so a stuck `_chat` timeout can't pile up)
- [x] Convo turn cap — enforce N=6 exchanges max, `end` default true after (Suck Up discipline: short by design)
- [x] Cache: identical `decide` prompts within ~30 sim-s → reuse prior decision (spirit "keeps doing the thing")
- [x] `num_predict` budget pass: player chat 220 is the big one — keep; convo turns stay ≤90

Verify: `time` a real-model session — no spirit frozen >10s waiting on
a decision; `sim_log` shows no convo over 6 turns.

## Phase 5 — Believability surface (cheap wins, inZOI trick)

- [x] **Thought bubbles**: `Decision.thought` already exists — render it as a fading one-line float above the spirit (like the 💡/✨ events) — highest believability-per-token in the genre
- [x] Keep 💡 on receive-news (done) + verdict `poiGlow` on pass (exists)

## Phase 6 — The loop, without days

- [x] Resolution card CTA: "keep celebrating" → continue; "new day" → `freshDb` restart
- [x] Roster already reads "grown" metrics — works across any timespan
- [x] After verdict resolves: world continues; a *second* arc slot can come later (explicitly out of scope)

## Deferred (say no for now)

- Daylight palette swap (the twilight look reads "festival" fine)
- On-device Gemma (Pixel works via `adb reverse`/`--lan` meanwhile)
- engine.dart split, `bin/eval.dart` real-model run
- Multi-arc structure, save-slot UI

## Order of work

1. P1 store busy_timeout + auto-fallback → game always opens playable
2. P2 daytime conversion → the ask itself
3. P3 mock-mode completeness → offline Pixel testing unblocked
4. P4+P5 → polish pass
5. P6 → ship loop

Each phase lands green: `fvm flutter test test/sim_test.dart
test/inspect_card_test.dart` + `fvm dart analyze lib`.
