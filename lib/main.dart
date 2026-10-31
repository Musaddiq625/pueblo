import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import 'game/intro_scene.dart';
import 'game/pueblo_game.dart';
import 'game/world_def.dart';
import 'sim/bootstrap.dart';
import 'sim/engine.dart';
import 'sim/gemma_client.dart';
import 'sim/llm.dart';
import 'sim/models.dart';
import 'ui/inspect_card.dart';
import 'ui/model_gate.dart';
import 'ui/shop_sheet.dart';

Future<void> main() async {
  // DRIVER=true → Playwright-style control for test tooling via the
  // ext.pueblo.cmd VM service extension (Dart MCP vm_service tool).
  // NB: flutter_driver's enableFlutterDriverExtension is NOT used — its
  // DriverBinding wraps the binary messenger and the Flame world's asset
  // loads never complete under it (black screen, dead world).
  // Commands: state | tap_spirit <name> | tap_poi <id> | release |
  //           chat <msg> | zoom <f> | center | shot
  WidgetsFlutterBinding.ensureInitialized();
  const driver = bool.fromEnvironment('DRIVER');
  if (driver) {
    // registerExtension only bites once the isolate's service connection
    // is live — main() runs too early, so defer to the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      dev.registerExtension(
        'ext.pueblo.cmd',
        (method, params) async => dev.ServiceExtensionResponse.result(
          jsonEncode({
            'result':
                await (PuebloGame.activeGame?.driverCommand(params['cmd']) ??
                    Future.value('ERR game not loaded')),
          }),
        ),
      );
    });
  }
  final personasJson = await rootBundle.loadString('assets/data/personas.json');
  final secretsJson = await rootBundle.loadString('assets/data/secrets.json');
  final whispersJson = await rootBundle.loadString(
    'assets/data/whispers.json',
  );

  // --dart-define switches: SIM_SEED, SIM_TIME_SCALE, LLM=model, DEMO=true
  const seed = int.fromEnvironment('SIM_SEED', defaultValue: 7);
  const timeScaleStr = String.fromEnvironment(
    'SIM_TIME_SCALE',
    defaultValue: '1.0',
  );
  final timeScale = double.tryParse(timeScaleStr) ?? 1.0;
  const llmName = String.fromEnvironment('LLM', defaultValue: 'mock');
  const demo = bool.fromEnvironment('DEMO', defaultValue: false);

  // LLM=gemma → on-device path: model gate first, then GemmaLocalClient.
  if (llmName == 'gemma') {
    runApp(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData.dark(),
        home: ModelGate(
          onReady: () async {
            final bundle = await bootstrap(
              personasJson: personasJson,
              secretsJson: secretsJson,
              whispersJson: whispersJson,
              pois: poiDefs,
              homePos: homePositions({for (final p in poiDefs) p.id: p}),
              llm: GemmaLocalClient(rng: Random(seed)),
              rng: Random(seed),
              timeScale: demo ? 6.0 : timeScale,
              festivalAt: demo ? 600 : 900,
              dbPath: 'pueblo_sim.db',
            );
            PuebloGame.personaSprite = bundle.sprites;
            PuebloGame.personaTint = bundle.tints;
            PuebloGame.personaDye = bundle.dyes;
            runApp(PuebloApp(bundle: bundle));
          },
        ),
      ),
    );
    return;
  }

  // OLLAMA_BASE — where to reach the model server. On a phone, localhost
  // is the PHONE itself, not the dev machine: pass the host's LAN IP
  // (--dart-define=OLLAMA_BASE=http://192.168.x.x:11434) or every reply
  // silently degrades to silence.
  const ollamaBase = String.fromEnvironment('OLLAMA_BASE');
  // STRICT_LLM=1 → hard fail when the model server is down (debugging).
  // Default: failover — mock keeps the village alive until Ollama returns.
  const strictLlm = bool.fromEnvironment('STRICT_LLM');
  final LLMClient llm = llmName == 'mock'
      ? MockLLMClient(seed: seed)
      : strictLlm
          ? OllamaClient(
              model: llmName,
              base: ollamaBase.isEmpty ? null : Uri.parse(ollamaBase),
            )
          : FailoverLLMClient(
              primary: OllamaClient(
                model: llmName,
                base: ollamaBase.isEmpty ? null : Uri.parse(ollamaBase),
              ),
              fallback: MockLLMClient(seed: seed),
            );

  Future<SimBundle> mkBundle() => bootstrap(
    personasJson: personasJson,
    secretsJson: secretsJson,
    whispersJson: whispersJson,
    pois: poiDefs,
    homePos: homePositions({for (final p in poiDefs) p.id: p}),
    llm: llm,
    rng: Random(seed),
    timeScale: demo ? 6.0 : timeScale,
    festivalAt: demo ? 600 : 900,
    freshDb: true,
    dbPath: 'pueblo_sim.db',
  );

  Future<void> launch() async {
    final bundle = await mkBundle();
    PuebloGame.personaSprite = bundle.sprites;
    PuebloGame.personaTint = bundle.tints;
    PuebloGame.personaDye = bundle.dyes;
    runApp(PuebloApp(bundle: bundle, onNewDay: launch));
  }

  await launch();
}

class PuebloApp extends StatefulWidget {
  final SimBundle bundle;

  /// Resolution card → rebuild the whole sim + app for a fresh day.
  final Future<void> Function()? onNewDay;
  const PuebloApp({super.key, required this.bundle, this.onNewDay});
  @override
  State<PuebloApp> createState() => _PuebloAppState();
}

class _PuebloAppState extends State<PuebloApp> {
  late final PuebloGame game;
  final _rb = GlobalKey();
  final _navKey = GlobalKey<NavigatorState>();
  String? inspecting;
  bool inspectIsDeep = false;
  Poi? shoppingAt;
  int petals = 0;
  int? remembered, fadedCount;
  String? verdictNote; // the arc's resolution, if a verdict fired today
  bool resolutionDismissed = false; // card hides; the festival keeps going
  bool rosterOpen = false;

  SimEngine get engine => widget.bundle.engine;

  @override
  void initState() {
    super.initState();
    petals = engine.playerPetals;
    game = PuebloGame(
      engine: engine,
      onEngage: _engage,
      onPoiInspect: _inspect,
      onPetalsChanged: () => setState(() => petals = engine.playerPetals),
      onEndRun: (r, f, v) => setState(() {
        remembered = r;
        fadedCount = f;
        verdictNote = v;
        engine.disengage(); // close any open InspectCard under the card
      }),
    );
    // DRIVER 'shot' command → capture the RepaintBoundary, return the path.
    PuebloGame.shotHook = () async {
      await _dumpFrame();
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/pueblo_frame.png';
    };
    PuebloGame.rosterHook = () => setState(() => rosterOpen = true);
    // DRIVER 'reset' → same fresh-world path as the resolution card.
    PuebloGame.resetHook = widget.onNewDay;
    // SHOT=<sec> → first capture delay. SHOTN=<n> frames, SHOTEACH=<ms>
    // spacing (default 1000). Files: pueblo_frame.png, pueblo_frame_1.png…
    const shotSec = int.fromEnvironment('SHOT');
    if (shotSec > 0) {
      const n = int.fromEnvironment('SHOTN', defaultValue: 1);
      const each = int.fromEnvironment('SHOTEACH', defaultValue: 1000);
      for (var i = 0; i < n; i++) {
        Timer(
          Duration(milliseconds: shotSec * 1000 + i * each),
          () => _dumpFrame(i),
        );
      }
    }
    // The theft — the opening beats the whole case hangs on. A popup
    // crop of the ofrenda, not a video: same tiles, same sprites.
    // SKIP_INTRO disables it — DRIVER runs get it too (driver commands
    // ride the VM service, not taps; the dialog never blocks them).
    if (!const bool.fromEnvironment('SKIP_INTRO')) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _showIntro());
    }
  }

  void _showIntro() {
    if (!mounted) return;
    // The state's own context sits ABOVE MaterialApp — dialogs opened on
    // it find no Navigator/Localizations and throw. Go through the key.
    final ctx = _navKey.currentContext;
    if (ctx == null) return;
    showDialog<void>(
      context: ctx,
      barrierDismissible: false,
      barrierColor: const Color(0xE6080612),
      builder: (ctx) {
        final scene = IntroScene(
          onDone: () {
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
        );
        return Dialog(
          backgroundColor: const Color(0xFF0A0814),
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: const BorderSide(color: Color(0xFF3A2C50)),
          ),
          child: SizedBox(
            width: 560,
            height: 340,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(14, 10, 14, 6),
                  child: Text(
                    'día de los muertos — the night the frame went bare',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Color(0xFF8D84B0),
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: GameWidget(game: scene),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: TextButton(
                    key: const Key('introSkip'),
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text(
                      'comenzar →',
                      style: TextStyle(
                        fontSize: 12,
                        color: Color(0xFFFFC233),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _dumpFrame([int idx = 0]) async {
    final boundary =
        _rb.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    // Hidden/occluded windows produce no vsync frames — force one so the
    // boundary has fresh pixels to rasterize.
    SchedulerBinding.instance.scheduleForcedFrame();
    await WidgetsBinding.instance.endOfFrame;
    final img = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final name = idx == 0 ? 'pueblo_frame.png' : 'pueblo_frame_$idx.png';
    final f = File('${dir.path}/$name');
    await f.writeAsBytes(bytes.buffer.asUint8List());
    debugPrint('SHOT saved: ${f.path}');
  }

  void _engage(Agent a) {
    engine.engage(a.id);
    setState(() {}); // card visibility follows engine.engagedId
  }

  void _endInteraction() {
    engine.disengage();
    setState(() {});
  }

  void _inspect(Poi p) {
    if (p.isStall) {
      setState(() => shoppingAt = p);
      return;
    }
    final text = engine.inspectPoi(p.id);
    setState(() {
      inspectIsDeep = engine.secrets.values.any(
        (s) => s.unlocksPoiLore == p.id && engine.playerKnown.contains(s.id),
      );
      inspecting = '${p.name}\n$text';
    });
    Future.delayed(const Duration(seconds: 4), () {
      if (mounted) setState(() => inspecting = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    final engaged = engine.engagedId;
    game.sheetOpen = engaged != null;
    return MaterialApp(
      navigatorKey: _navKey,
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      // Boundary above the Navigator — driver 'shot' captures the whole
      // scene including dialogs (the intro plays in a route overlay).
      builder: (_, child) => RepaintBoundary(key: _rb, child: child!),
      home: Scaffold(
        backgroundColor: const Color(0xFF120E20),
        body: Stack(
          children: [
              // Trackpad pinch → PointerPanZoom events (Flame lacks a
              // PanZoomDetector) — forward scale + pan to the camera.
              Listener(
                onPointerPanZoomUpdate: (e) =>
                    game.trackpadPinch(e.scale, e.panDelta),
                child: GameWidget(game: game),
              ),

              // HUD: petals + truth + model badge
              Positioned(
                top: 10,
                left: 10,
                child: _Hud(
                  engine: engine,
                  petals: petals,
                  onRoster: () => setState(() => rosterOpen = true),
                ),
              ),

              // Town log — hidden per request; the sim still narrates
              // internally (game.townLog) for the driver + debugging.

              // POI inspect toast
              if (inspecting != null)
                Positioned(
                  top: 56,
                  left: 0,
                  right: 0,
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 420),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xF22A2145),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: inspectIsDeep
                              ? const Color(0xFFFFC233)
                              : const Color(0xFF6A6088),
                        ),
                      ),
                      child: Text(
                        inspecting!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 12.5,
                          height: 1.4,
                          color: Color(0xFFFFF4DC),
                        ),
                      ),
                    ),
                  ),
                ),

              // ShopSheet — stall taps open the catalog
              if (shoppingAt != null && engaged == null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: ShopSheet(
                    key: const Key('shopSheet'),
                    engine: engine,
                    stallId: shoppingAt!.id,
                    stallName: shoppingAt!.name,
                    onClose: () => setState(() => shoppingAt = null),
                    onChanged: () =>
                        setState(() => petals = engine.playerPetals),
                  ),
                ),

              // InspectCard — user-driven release only
              if (engaged != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: InspectCard(
                    key: const Key('inspectCard'),
                    engine: engine,
                    // Match the world sprite — a faded spirit is the naked
                    // skeleton there, so the portrait shows it too (no dye:
                    // the ghost has no persona tint left).
                    spiritSprite:
                        engine.agents[engaged]?.faded == true
                            ? PuebloGame.kGhostChar
                            : PuebloGame.personaSprite[engaged] ?? 'sk_base',
                    spiritDye:
                        engine.agents[engaged]?.faded == true
                            ? null
                            : PuebloGame.personaDye[engaged],
                    onEnd: _endInteraction,
                  ),
                ),

              // Roster sheet — the remembered, card-select style
              if (rosterOpen)
                Center(
                  child: _RosterSheet(
                    engine: engine,
                    onClose: () => setState(() => rosterOpen = false),
                  ),
                ),

              // Resolution card — the arc has closed, but the festival never
              // halts. Dismiss to keep playing, or restart for a fresh day.
              if (remembered != null && !resolutionDismissed)
                Center(
                  child: Container(
                    padding: const EdgeInsets.all(28),
                    decoration: BoxDecoration(
                      color: const Color(0xF2201A38),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: const Color(0xFFFFC233),
                        width: 2,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'The candles have spoken.',
                          style: TextStyle(
                            fontSize: 22,
                            color: Color(0xFFFFC233),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          '$remembered spirits remembered · $fadedCount faded',
                          style: const TextStyle(color: Color(0xFFDCD4F0)),
                        ),
                        if (verdictNote != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            verdictNote!,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontStyle: FontStyle.italic,
                              color: Color(0xFFF5A95B),
                            ),
                          ),
                        ],
                        const SizedBox(height: 6),
                        const Text(
                          'the town forgot them — names keep the dead alive',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontStyle: FontStyle.italic,
                            color: Color(0xFF8D84B0),
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            TextButton(
                              key: const Key('keepCelebratingButton'),
                              onPressed: () =>
                                  setState(() => resolutionDismissed = true),
                              child: const Text(
                                'keep celebrating',
                                style: TextStyle(color: Color(0xFF8D84B0)),
                              ),
                            ),
                            if (widget.onNewDay != null) ...[
                              const SizedBox(width: 10),
                              FilledButton.icon(
                                key: const Key('newDayButton'),
                                icon: const Icon(Icons.wb_sunny, size: 16),
                                label: const Text('New day'),
                                style: FilledButton.styleFrom(
                                  backgroundColor: const Color(0xFFEF8C1A),
                                  foregroundColor: const Color(0xFF1A1430),
                                ),
                                onPressed: () => widget.onNewDay!(),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
    );
  }
}

class _Hud extends StatelessWidget {
  final SimEngine engine;
  final int petals;
  final VoidCallback onRoster;
  const _Hud({
    required this.engine,
    required this.petals,
    required this.onRoster,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xD0201A38),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3A2C50)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🌼', style: TextStyle(fontSize: 13)),
          const SizedBox(width: 4),
          Text(
            '$petals',
            key: const Key('petalCount'),
            style: const TextStyle(fontSize: 13, color: Color(0xFFFFC233)),
          ),
          const SizedBox(width: 12),
          const Icon(Icons.auto_awesome, size: 14, color: Color(0xFF8D84B0)),
          const SizedBox(width: 4),
          ValueListenableBuilder<int>(
            valueListenable: _clockListenable(engine),
            builder: (_, _, _) => GestureDetector(
              onTap: () => _showCaseFile(context, engine),
              child: Text(
                engine.caseResolved
                    ? 'case closed'
                    : 'case ${engine.caseProgress}/3',
                key: const Key('truthChip'),
                style: TextStyle(
                  fontSize: 12,
                  color: engine.caseResolved
                      ? const Color(0xFFFFC233)
                      : const Color(0xFF8D84B0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          ValueListenableBuilder<int>(
            valueListenable: _clockListenable(engine),
            builder: (_, _, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  engine.llmAlive
                      ? engine.llm.name
                      : '${engine.llm.name} · offline',
                  key: const Key('llmBadge'),
                  style: TextStyle(
                    fontSize: 10,
                    color: engine.llmAlive
                        ? const Color(0xFF5A5078)
                        : const Color(0xFFE06A6A),
                  ),
                ),
                if (engine.aiBusy) ...[
                  const SizedBox(width: 5),
                  const SizedBox(
                    width: 9,
                    height: 9,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.4,
                      color: Color(0xFFFFC233),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          _CuadernoChip(engine: engine),
          const SizedBox(width: 12),
          _LogChip(engine: engine),
          const SizedBox(width: 12),
          _RosterChip(onOpen: onRoster),
          const SizedBox(width: 12),
          _SpeedChip(engine: engine),
        ],
      ),
    );
  }

  ValueNotifier<int> _clockListenable(SimEngine e) =>
      _ClockHolder.instance.notifier(e);

  /// The case file — three ledgers. Admissible proofs and their reach;
  /// accusations afloat and who they finger; whispers the living one
  /// overheard, relayed or still trapped in a single mouth.
  void _showCaseFile(BuildContext context, SimEngine engine) {
    final proofs = engine.caseProofs;
    final accusations = engine.caseAccusations;
    final whispers = engine.caseWhispers;
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1430),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
      ),
      builder: (_) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'el cuadro robado — the case file',
                  style: TextStyle(fontSize: 14, color: Color(0xFFFFC233)),
                ),
                const SizedBox(height: 4),
                Text(
                  engine.caseResolved
                      ? 'case closed — the thief confessed'
                      : '${engine.caseProgress}/3 proofs weigh against the thief',
                  style: const TextStyle(
                    fontSize: 11,
                    color: Color(0xFF8D84B0),
                  ),
                ),
                const SizedBox(height: 10),
                for (final p in proofs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          p.private && !p.relayed &&
                                  !engine.playerKnown.contains(p.id)
                              ? '🔒 a whisper trapped in one mouth — overhear it, carry it'
                              : p.relayed && p.mouths >= 2
                              ? '🕯 ${p.text}'
                              : p.text,
                          key: Key('case_row_${p.id}'),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFDCD4F0),
                          ),
                        ),
                        Text(
                          'carried by ${p.mouths} mouth${p.mouths == 1 ? '' : 's'}'
                          '${p.relayed && p.mouths >= 2 ? ' — weighs on the ledger' : p.mouths == 0 && p.id == 'guitar_pick' ? ' — inspect the great ofrenda' : p.mouths < 2 && !p.private ? ' — needs one more mouth' : ''}',
                          style: const TextStyle(
                            fontSize: 10.5,
                            color: Color(0xFF6A6088),
                          ),
                        ),
                      ],
                    ),
                  ),
                if (accusations.isNotEmpty) ...[
                  const Divider(color: Color(0xFF3A2C50), height: 14),
                  const Text(
                    'accusations — blame without proof',
                    style: TextStyle(fontSize: 11, color: Color(0xFFB0A6D8)),
                  ),
                  const SizedBox(height: 6),
                  for (final a in accusations)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '“${a.text}”'
                        '${a.about != null ? ' — fingers ${engine.agents[a.about]?.name ?? a.about}' : ''}'
                        ' · ${a.mouths} mouth${a.mouths == 1 ? '' : 's'}',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF9C8FC0),
                        ),
                      ),
                    ),
                ],
                if (whispers.isNotEmpty) ...[
                  const Divider(color: Color(0xFF3A2C50), height: 14),
                  const Text(
                    'overheard whispers — yours to carry',
                    style: TextStyle(fontSize: 11, color: Color(0xFFB0A6D8)),
                  ),
                  const SizedBox(height: 6),
                  for (final w in whispers)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        '${w.relayed ? '✓' : '…'} ${engine.agents[w.speaker]?.name ?? w.speaker}: “${w.line}”',
                        style: const TextStyle(
                          fontSize: 11.5,
                          color: Color(0xFF9C8FC0),
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ),
                ],
                const SizedBox(height: 4),
                const Divider(color: Color(0xFF3A2C50), height: 14),
                for (final t in engine.caseTasks)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 3),
                    child: Text(
                      '• $t',
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFFB0A6D8),
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The living one's notebook — what the day has taught them. What they
/// know, where it might be worth a look, and the headline's empty frame.
class _CuadernoChip extends StatelessWidget {
  final SimEngine engine;
  const _CuadernoChip({required this.engine});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () {
        final known = engine.playerKnown
            .map((id) => engine.secrets[id])
            .whereType<Secret>()
            .toList();
        showModalBottomSheet(
          context: context,
          backgroundColor: const Color(0xFF1A1430),
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
          ),
          builder: (_) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'cuaderno — what you carry',
                    style: TextStyle(fontSize: 14, color: Color(0xFFFFC233)),
                  ),
                  const SizedBox(height: 10),
                  if (known.isEmpty)
                    const Text(
                      'Nothing yet. Ask the spirits what they know — watch for ✨.',
                      style: TextStyle(fontSize: 12, color: Color(0xFF8D84B0)),
                    )
                  else
                    for (final s in known)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${s.tier == 'rumor' ? '🕯 ' : ''}${s.shareText}',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Color(0xFFDCD4F0),
                              ),
                            ),
                            if (s.unlocksPoiLore != null)
                              Text(
                                'worth a look: ${engine.pois[s.unlocksPoiLore]?.name ?? s.unlocksPoiLore}',
                                style: const TextStyle(
                                  fontSize: 10.5,
                                  color: Color(0xFF6A6088),
                                ),
                              ),
                          ],
                        ),
                      ),
                  // Rumors you've planted — free whispers that live or die
                  // in other mouths. Mouths = spirits repeating them now.
                  Builder(
                    builder: (context) {
                      final loose = engine.claimsForCuaderno();
                      if (loose.isEmpty) return const SizedBox.shrink();
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const SizedBox(height: 8),
                          const Divider(color: Color(0xFF3A2C50), height: 14),
                          const Text(
                            'rumors you\'ve set loose',
                            key: Key('cuadernoRumors'),
                            style: TextStyle(
                              fontSize: 11,
                              color: Color(0xFFF5A95B),
                            ),
                          ),
                          const SizedBox(height: 6),
                          for (final c in loose)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Text(
                                '“${c.text}” — ${c.mouths} mouth${c.mouths == 1 ? '' : 's'} repeat${c.mouths == 1 ? 's' : ''} it',
                                key: Key('cuaderno_claim'),
                                style: const TextStyle(
                                  fontSize: 11.5,
                                  color: Color(0xFFB0A6D8),
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
      child: const Text(
        '📖',
        key: Key('cuadernoChip'),
        style: TextStyle(fontSize: 13),
      ),
    );
  }
}

/// The village roster — every spirit on a card, tap one for its dossier:
/// persona, stat stars, what it's carrying, and whether the day has
/// taught it anything. Data-driven off engine.agents so a bigger cast
/// needs no UI changes.
class _RosterChip extends StatelessWidget {
  final VoidCallback onOpen;
  const _RosterChip({required this.onOpen});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onOpen,
      child: const Text(
        '🕯️',
        key: Key('rosterChip'),
        style: TextStyle(fontSize: 13),
      ),
    );
  }
}

class _RosterSheet extends StatefulWidget {
  final SimEngine engine;
  final VoidCallback onClose;
  const _RosterSheet({required this.engine, required this.onClose});

  @override
  State<_RosterSheet> createState() => _RosterSheetState();
}

class _RosterSheetState extends State<_RosterSheet> {
  String? _selected;

  @override
  Widget build(BuildContext context) {
    final spirits = widget.engine.agents.values.toList();
    final sel = _selected ?? spirits.first.id;
    return Container(
      key: const Key('rosterSheet'),
      width: 640,
      height: 420,
      decoration: BoxDecoration(
        color: const Color(0xF51A1430),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3A2C50)),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 8, 4),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    'the remembered — who walks today',
                    style: TextStyle(fontSize: 14, color: Color(0xFFFFC233)),
                  ),
                ),
                GestureDetector(
                  key: const Key('rosterClose'),
                  onTap: widget.onClose,
                  child: const Padding(
                    padding: EdgeInsets.all(6),
                    child: Icon(
                      Icons.close,
                      size: 16,
                      color: Color(0xFF8D84B0),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Row(
              children: [
                // roster grid — portrait cards like a character select
                SizedBox(
                  width: 268,
                  child: GridView.builder(
                    padding: const EdgeInsets.all(10),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          mainAxisSpacing: 8,
                          crossAxisSpacing: 8,
                          childAspectRatio: 0.82,
                        ),
                    itemCount: spirits.length,
                    itemBuilder: (_, i) => _RosterCard(
                      key: Key('rosterCard_${spirits[i].id}'),
                      agent: spirits[i],
                      selected: spirits[i].id == sel,
                      onTap: () => setState(() => _selected = spirits[i].id),
                    ),
                  ),
                ),
                Container(width: 1, color: const Color(0xFF3A2C50)),
                // dossier — everything the day knows about this spirit
                Expanded(
                  child: _Dossier(engine: widget.engine, id: sel),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RosterCard extends StatelessWidget {
  final Agent agent;
  final bool selected;
  final VoidCallback onTap;
  const _RosterCard({
    super.key,
    required this.agent,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final sprite = PuebloGame.personaSprite[agent.id] ?? 'sk_base';
    final dye = PuebloGame.personaDye[agent.id];
    Widget img = Image.asset(
      'assets/sprites/chars/${sprite}_idle.png',
      fit: BoxFit.cover,
      alignment: Alignment.centerLeft,
      filterQuality: FilterQuality.none,
    );
    if (dye != null) {
      img = ColorFiltered(
        colorFilter: ColorFilter.mode(Color(dye), BlendMode.modulate),
        child: img,
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF3A2C50) : const Color(0xFF241C40),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFFFFC233) : const Color(0xFF3A2C50),
            width: selected ? 1.6 : 1,
          ),
        ),
        padding: const EdgeInsets.all(5),
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Opacity(opacity: agent.faded ? 0.45 : 1, child: img),
              ),
            ),
            const SizedBox(height: 3),
            Text(
              agent.name.split(' ').first,
              style: const TextStyle(fontSize: 10, color: Color(0xFFDCD4F0)),
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _Dossier extends StatelessWidget {
  final SimEngine engine;
  final String id;
  const _Dossier({required this.engine, required this.id});

  @override
  Widget build(BuildContext context) {
    final a = engine.agents[id]!;
    return FutureBuilder<SpiritDossier>(
      future: engine.spiritDossier(id),
      builder: (_, snap) {
        final d = snap.data;
        return ListView(
          key: const Key('rosterDetail'),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
          children: [
            Text(
              a.name,
              style: const TextStyle(fontSize: 16, color: Color(0xFFFFC233)),
            ),
            Text(
              '${a.role} · ${a.condition}${a.solidified ? ' · solid' : ''} · 🕯${a.battery.toInt()}',
              style: const TextStyle(fontSize: 11, color: Color(0xFF8D84B0)),
            ),
            const SizedBox(height: 8),
            Text(
              a.persona,
              style: const TextStyle(
                fontSize: 11.5,
                height: 1.4,
                color: Color(0xFFDCD4F0),
              ),
            ),
            if (a.hook != null) ...[
              const SizedBox(height: 4),
              Text(
                'hook: ${a.hook}',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontStyle: FontStyle.italic,
                  color: Color(0xFF8D84B0),
                ),
              ),
            ],
            if (a.mood != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'feeling: ${a.mood}',
                  style: const TextStyle(
                    fontSize: 10.5,
                    color: Color(0xFFF5A95B),
                  ),
                ),
              ),
            const SizedBox(height: 10),
            _statStars(a.stats),
            const SizedBox(height: 10),
            if (d == null)
              const Text('…', style: TextStyle(color: Color(0xFF8D84B0)))
            else ...[
              _line(
                '🧠 memories',
                '${d.memoryCount} stored · weight ${d.importanceSum}',
              ),
              _line(
                '📖 secrets',
                '${a.knownSecrets.length} held '
                    '(${d.initialSecrets} from the start, ${d.learnedSecrets.length} learned today)',
              ),
              if (d.heldClaims.isNotEmpty)
                _line(
                  '🗣️ rumors',
                  '${d.heldClaims.length} carried'
                      '${d.heldClaims.any((c) => c.believes) ? ' — believes ${d.heldClaims.where((c) => c.believes).length}' : ''}',
                ),
              if (d.verifiedPois > 0)
                _line('👣 went to see', '${d.verifiedPois} places'),
              if (a.warmth.isNotEmpty)
                _line(
                  '💛 closest to',
                  (a.warmth.entries.toList()
                        ..sort((x, y) => y.value.compareTo(x.value)))
                      .take(3)
                      .map(
                        (e) =>
                            '${engine.agents[e.key]?.name.split(' ').first ?? e.key} (${e.value})',
                      )
                      .join(', '),
                ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text(
                    '🌱 grown today? ',
                    style: TextStyle(fontSize: 11, color: Color(0xFF8D84B0)),
                  ),
                  Text(
                    '${d.learningLevel} (${d.learningScore})',
                    key: const Key('dossierLearning'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFB8E8A0),
                    ),
                  ),
                ],
              ),
              if (d.latestReflection != null) ...[
                const SizedBox(height: 6),
                Text(
                  '“${d.latestReflection}”',
                  style: const TextStyle(
                    fontSize: 10.5,
                    fontStyle: FontStyle.italic,
                    height: 1.35,
                    color: Color(0xFFB0A6D8),
                  ),
                ),
              ],
            ],
            if (a.goal != null || a.errand != null) ...[
              const SizedBox(height: 8),
              _line(
                '🎯 up to',
                a.errand != null
                    ? '${a.errand!.kind} → ${a.errand!.targetId}'
                    : a.goal!,
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _statStars(Stats s) {
    String stars(int v) => '★' * v.clamp(0, 5) + '☆' * (5 - v.clamp(0, 5));
    Widget row(String label, int v) => Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 82,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10.5, color: Color(0xFF8D84B0)),
            ),
          ),
          Text(
            stars(v),
            style: const TextStyle(
              fontSize: 10.5,
              color: Color(0xFFFFC233),
              letterSpacing: 1,
            ),
          ),
        ],
      ),
    );
    return Column(
      children: [
        row('curiosity', s.curiosity),
        row('wit', s.wit),
        row('warmth', s.warmth),
        row('spirit sight', s.spiritSight),
        row('mischief', s.mischief),
        row('grump', s.grump),
      ],
    );
  }

  Widget _line(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 3),
    child: Text(
      '$label  ·  $value',
      style: const TextStyle(fontSize: 11, color: Color(0xFFDCD4F0)),
    ),
  );
}

/// Sim-speed toggle — cycles 1× → 2× → 4× → 8× so you can fast-forward
/// through quiet stretches of the day.
class _SpeedChip extends StatefulWidget {
  final SimEngine engine;
  const _SpeedChip({required this.engine});

  @override
  State<_SpeedChip> createState() => _SpeedChipState();
}

class _SpeedChipState extends State<_SpeedChip> {
  static const _steps = [1.0, 2.0, 4.0, 8.0];

  @override
  Widget build(BuildContext context) {
    final speed = widget.engine.timeScale;
    return GestureDetector(
      onTap: () => setState(() {
        final i = _steps.indexOf(speed);
        widget.engine.timeScale = _steps[(i < 0 ? 0 : i + 1) % _steps.length];
      }),
      child: Text(
        '${speed.toInt()}×',
        key: const Key('speedChip'),
        style: const TextStyle(
          fontSize: 11,
          color: Color(0xFFB8A8E8),
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

/// Tiny ticker so the HUD clock updates — the engine has no ChangeNotifier.
class _ClockHolder {
  static final instance = _ClockHolder._();
  _ClockHolder._();
  final _n = ValueNotifier<int>(0);
  bool _started = false;
  ValueNotifier<int> notifier(SimEngine e) {
    if (!_started) {
      _started = true;
      Stream.periodic(const Duration(milliseconds: 500))
          .listen((_) => _n.value = e.simTs);
    }
    return _n;
  }
}

/// Live audit tail — the sim_log sheet: decides, learns, errands,
/// rumors, replies, directives. Polls the store every 2s while open so
/// a whisper's chain is watchable end-to-end on-device.
class _LogChip extends StatelessWidget {
  final SimEngine engine;
  const _LogChip({required this.engine});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const Key('logChip'),
      onTap: () => showModalBottomSheet(
        context: context,
        backgroundColor: const Color(0xFF1A1430),
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        builder: (_) => _LogSheet(engine: engine),
      ),
      child: const Text('📜', style: TextStyle(fontSize: 13)),
    );
  }
}

class _LogSheet extends StatefulWidget {
  final SimEngine engine;
  const _LogSheet({required this.engine});

  @override
  State<_LogSheet> createState() => _LogSheetState();
}

class _LogSheetState extends State<_LogSheet> {
  List<Map<String, Object?>> _rows = const [];
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(seconds: 2), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final r = await widget.engine.store.tailLog(60);
    if (mounted) setState(() => _rows = r);
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Color _kindColor(String kind) => switch (kind) {
        'directive' || 'curious' => const Color(0xFF7FD4A8),
        'claim' || 'rumor' || 'twist' => const Color(0xFFF5A95B),
        'reply' => const Color(0xFF9EC8F0),
        'learn' => const Color(0xFFFFC233),
        _ => const Color(0xFF8D84B0),
      };

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        builder: (_, scroll) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'the village, audited',
                style: TextStyle(fontSize: 14, color: Color(0xFFFFC233)),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: _rows.isEmpty
                    ? const Text(
                        'nothing logged yet — talk to a spirit.',
                        style:
                            TextStyle(fontSize: 12, color: Color(0xFF8D84B0)),
                      )
                    : ListView.builder(
                        controller: scroll,
                        itemCount: _rows.length,
                        itemBuilder: (_, i) {
                          final r = _rows[i];
                          final kind = '${r['kind']}';
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 5),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                SizedBox(
                                  width: 38,
                                  child: Text(
                                    '${r['sim_ts']}',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Color(0xFF5A5078),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 68,
                                  child: Text(
                                    '${r['agent']}',
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFF6A6088),
                                    ),
                                  ),
                                ),
                                SizedBox(
                                  width: 62,
                                  child: Text(
                                    kind,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: _kindColor(kind),
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Text(
                                    '${r['payload']}',
                                    style: const TextStyle(
                                      fontSize: 10.5,
                                      color: Color(0xFFDCD4F0),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
