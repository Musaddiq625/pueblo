# El Pueblo de los Muertos 🕯️

A top-down, Game Boy-style village of the dead — built for Día de los Muertos.
Nine spirits wander a pixel-art pueblo at night: they visit the shops, gossip
by the fountain, remember each other's names, and slowly piece together who
stole **La Golondrina's portrait** from the great ofrenda.

**The twist: the spirits are AI agents.** Every personality, mutter, rumor, and
line of dialogue is generated on-device by an **open-weight model (Gemma)** —
while a deterministic Dart simulation owns what is *true*: who knows which
secret, who is walking where, who fades when forgotten, and who the thief
really is. The model writes the voices; the engine keeps the facts.

No API keys. No cloud. The whole village thinks offline.

## How the mystery plays out

- **The intro** — a hooded silhouette lifts the golden portrait from a wall of
  framed dead; two villagers find the bare slot at dawn.
- **The hunt** — spirits inspect the ofrenda, find the dropped guitar pick,
  hear whispers (someone was humming *her* tune), trade secrets in
  conversation, and watch private mutters leak into the open.
- **The fade** — a spirit whose remembrance battery dies dims into a
  translucent skeleton until someone speaks their name. Solorio starts
  forgetting; the town can still bring him back.
- **The confession** — at three established proofs the ledger fills and a
  🕯 accuser marches on the culprit: *"It was you, Ramón — the pick beneath
  her frame, the wax on your sleeve."* The culprit answers in his own words,
  and the resolution card names the who, the what, and the why.
- **You** — zoom and pan the village, tap a spirit to talk, carry whispers
  yourself, or let the village solve it alone. The player is a shortcut, not
  a requirement.

## Architecture

```
┌────────────────────────┐      proposals       ┌──────────────────────┐
│  Open-weight model     │  ──────────────────▶ │  Deterministic sim   │
│  gemma3 via Ollama     │   decide/convo/chat  │  (Dart)              │
│  or on-device Gemma    │                      │  • truth & secrets   │
│  (flutter_gemma)       │ ◀──────────────────  │  • walks & schedules │
│                        │   persona + case     │  • knowledge graph   │
└────────────────────────┘    digest prompts    │  • batteries & fades │
                                                │  • verdict (proof-   │
                                                │    led, not LLM)     │
                                                └─────────┬────────────┘
                                                          │ SimEvents
                                                ┌─────────▼────────────┐
                                                │  Flame renderer      │
                                                │  sprites, bubbles,   │
                                                │  glyphs, ofrenda…    │
                                                └──────────────────────┘
```

LLMs propose; Dart disposes. Malformed model output is sanitized
(`_cleanLine`), conversations hold both speakers until the last bubble dies,
and the case's verdict is computed from an authored secret ledger — never
from model confidence.

## Run it

```bash
# 1) the model (any open-weight chat model works)
ollama pull gemma3:4b && ollama serve

# 2) the village
./run_macos.sh                      # macOS, real model, driver on
# or:
flutter run -d macos \
  --dart-define=LLM=gemma3:4b \
  --dart-define=DRIVER=true         # ext.pueblo.cmd control socket
```

| dart-define | default | meaning |
| --- | --- | --- |
| `LLM` | `mock` | Ollama model name, `mock` for canned lines, `gemma` for on-device |
| `OLLAMA_BASE` | localhost | model server URL (use LAN IP on a phone) |
| `STRICT_LLM` | off | hard-fail instead of mock fallback when the server is down |
| `DRIVER` | off | enables the `ext.pueblo.cmd` VM-service driver (state, shot, solve…) |
| `SIM_TIME_SCALE` | `1.0` | sim speed |
| `DEMO` | off | fast-forwarded demo timings |

On-device path (`--dart-define=LLM=gemma`) uses `flutter_gemma` for fully
offline inference on Android (Pixel-class and up).

## For judges / reviewers

- The game is deterministic-first: `flutter test` covers the sim engine,
  the sprite contract, and the mystery's logic (81 tests).
- A driver socket (`ext.pueblo.cmd`) supports `state`, `shot`, `speed`,
  `tap_spirit`, `chat`, `look`, and `solve` — the last is a director's cut
  that seeds the ledger so the confession can be filmed on demand;
  `./solve.sh <vm-service-uri>` wraps it.
- Repo history shows the build process — sprite pipelines, the mystery
  design (`MYSTERY_PLAN.md`), and the LLM boundary (`AUDIT_REPORT.md`).

## Tech stack

Flutter · Flame · Dart · SQLite (sqflite) · Ollama · gemma3 (open weights) ·
flutter_gemma · pixel art from CC0 packs (see
[`assets/sprites/village/LICENSES.md`](assets/sprites/village/LICENSES.md))

## License

MIT for code — see [LICENSE](LICENSE). Third-party art is CC0, credited in
`assets/sprites/village/LICENSES.md`.
