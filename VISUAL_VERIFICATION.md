# Visual Verification Runbook

How to inspect the running village — used to catch the walk-shrink,
missing-prop, alpha-loss, and dead-world bugs during the rebuild.

## Launch for inspection

```bash
fvm flutter run -d macos \
  --dart-define=LLM=mock --dart-define=DRIVER=true --dart-define=DEMO=true
```

- `DRIVER=true` registers the `ext.pueblo.cmd` VM-service extension.
- `DEMO=true` runs 6× time so the night cycle completes quickly.
- The log prints `A Dart VM Service on macOS is available at:
  http://127.0.0.1:<port>/<token>/` — connect the `vm_service` MCP
  tool to `ws://…/ws`, then `callMethod getVM` for the isolate id.

## Commands (ext.pueblo.cmd)

| cmd | effect |
|---|---|
| `state` | JSON: simTs, camera, spirits (pos/screen/faded/battery), POIs |
| `world` | loaded flag, child counts, lifecycle, `ticks` (see caveat) |
| `shot` | RepaintBoundary PNG → `…/Documents/pueblo_frame.png` |
| `tap_spirit <name>` | engages that spirit (same path as a real tap) |
| `tap_poi <id>` | inspects POI / opens the shop sheet for stalls |
| `release` | disengages the current spirit |
| `chat <msg>` | sends a player message to the engaged spirit |
| `zoom <f>` | camera zoom, clamped 0.8–2.5 |
| `center` | re-follow the player |

## Caveat: hidden window = dead world

On macOS, if the app window is fully occluded/minimized the lifecycle
goes `AppLifecycleState.hidden`: Flutter stops producing frames, so
`update()` never runs (`ticks` stays 0, `simTs` frozen) and `shot`
captures an unpainted black frame. Fix: make the window visible
(relaunch, or un-hide it) — `world` reports `lifecycle=` and `ticks=`
so you can confirm.

## What a healthy frame looks like

- Terrain: river top edge + bridge, dirt streets, dark earth, moonlit
  cobble plaza (running-bond), marigold carpet at the ofrenda.
- Props: terracotta-roof buildings on the market row, stalls with
  counters, crypt + fenced graveyards (NE + SE), ceiba SE, ofrenda
  wall S, lantern glow, papel picado over the market street.
- Spirits: skeleton sprites (no black backing), colored aura ring +
  short name label under feet; Solorio renders translucent (faded).
- Movement: spirits at uniform size while walking (the repack makes
  this structural — report any visible shrink as a manifest bug).
- Speech: bubbles over standing spirits; the bottom-left town log
  always shows the last ~4 lines.
- Glow: candle flicker on the ofrenda + grave 37.

## Targeted checks

- Walk cycle: `shot` while a spirit is mid-path — same size as idle.
- Convo approach: two spirits converge, face each other, 💬 emote.
- Slots: spirits stand in front of stall counters / grave rows facing
  the POI (not inside the prop).
- Depth: walking south of a tree the spirit covers the trunk; north of
  it the canopy covers them.
- Tapping: `tap_spirit Ramón` → that spirit faces the player + stops;
  `state` shows `engaged`; `release` resumes wandering.
