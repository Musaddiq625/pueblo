import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

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
  WidgetsFlutterBinding.ensureInitialized();
  final personasJson = await rootBundle.loadString('assets/data/personas.json');
  final secretsJson = await rootBundle.loadString('assets/data/secrets.json');

  // --dart-define switches: SIM_SEED, SIM_TIME_SCALE, LLM=model, DEMO=1
  const seed = int.fromEnvironment('SIM_SEED', defaultValue: 7);
  const timeScaleStr =
      String.fromEnvironment('SIM_TIME_SCALE', defaultValue: '1.0');
  final timeScale = double.tryParse(timeScaleStr) ?? 1.0;
  const llmName = String.fromEnvironment('LLM', defaultValue: 'mock');
  const demo = bool.fromEnvironment('DEMO', defaultValue: false);

  // LLM=gemma → on-device path: model gate first, then GemmaLocalClient.
  if (llmName == 'gemma') {
    runApp(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: ModelGate(onReady: () async {
        final bundle = await bootstrap(
          personasJson: personasJson,
          secretsJson: secretsJson,
          pois: poiDefs,
          waypointsIdx: waypoints,
          waypointPos: waypointPos,
          homePos: homePositions({for (final p in poiDefs) p.id: p}),
          llm: GemmaLocalClient(rng: Random(seed)),
          rng: Random(seed),
          timeScale: demo ? 6.0 : timeScale,
          dawnAt: demo ? 600 : 900,
          dbPath: 'pueblo_sim.db',
        );
        PuebloGame.personaSprite = bundle.sprites;
        runApp(PuebloApp(bundle: bundle));
      }),
    ));
    return;
  }

  final LLMClient llm = llmName == 'mock'
      ? MockLLMClient(seed: seed)
      : OllamaClient(model: llmName);

  final bundle = await bootstrap(
    personasJson: personasJson,
    secretsJson: secretsJson,
    pois: poiDefs,
    waypointsIdx: waypoints,
    waypointPos: waypointPos,
    homePos: homePositions({for (final p in poiDefs) p.id: p}),
    llm: llm,
    rng: Random(seed),
    timeScale: demo ? 6.0 : timeScale,
    dawnAt: demo ? 600 : 900,
    freshDb: true,
    dbPath: 'pueblo_sim.db',
  );

  PuebloGame.personaSprite = bundle.sprites;

  runApp(PuebloApp(bundle: bundle));
}

class PuebloApp extends StatefulWidget {
  final SimBundle bundle;
  const PuebloApp({super.key, required this.bundle});
  @override
  State<PuebloApp> createState() => _PuebloAppState();
}

class _PuebloAppState extends State<PuebloApp> {
  late final PuebloGame game;
  final _rb = GlobalKey();
  String? inspecting;
  bool inspectIsDeep = false;
  Poi? shoppingAt;
  int petals = 0;
  int? remembered, fadedCount;

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
      onEndRun: (r, f) => setState(() {
        remembered = r;
        fadedCount = f;
      }),
    );
    // SHOT=<seconds> → dev tool: rasterize the frame to a PNG after settling.
    const shotSec = int.fromEnvironment('SHOT');
    if (shotSec > 0) {
      Timer(Duration(seconds: shotSec), _dumpFrame);
    }
  }

  Future<void> _dumpFrame() async {
    final boundary =
        _rb.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;
    final img = await boundary.toImage(pixelRatio: 2.0);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) return;
    final dir = await getApplicationDocumentsDirectory();
    final f = File('${dir.path}/pueblo_frame.png');
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
      inspectIsDeep = engine.secrets.values
          .any((s) => s.unlocksPoiLore == p.id && engine.playerKnown.contains(s.id));
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
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: const Color(0xFF120E20),
        body: RepaintBoundary(
          key: _rb,
          child: Stack(
            children: [
            // Trackpad pinch → PointerPanZoom events (Flame lacks a
            // PanZoomDetector) — forward scale + pan to the camera.
            Listener(
              onPointerPanZoomUpdate: (e) =>
                  game.trackpadPinch(e.scale, e.panDelta),
              child: GameWidget(game: game),
            ),

            // HUD: petals + dawn + model badge
            Positioned(
              top: 10, left: 10,
              child: _Hud(engine: engine, petals: petals),
            ),

            // POI inspect toast
            if (inspecting != null)
              Positioned(
                top: 56, left: 0, right: 0,
                child: Center(
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xF22A2145),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: inspectIsDeep
                              ? const Color(0xFFFFC233)
                              : const Color(0xFF6A6088)),
                    ),
                    child: Text(inspecting!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 12.5, height: 1.4,
                            color: Color(0xFFFFF4DC))),
                  ),
                ),
              ),

            // ShopSheet — stall taps open the catalog
            if (shoppingAt != null && engaged == null)
              Positioned(
                left: 0, right: 0, bottom: 0,
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
                left: 0, right: 0, bottom: 0,
                child: InspectCard(
                  key: const Key('inspectCard'),
                  engine: engine,
                  spiritSprite: PuebloGame.personaSprite[engaged] ?? 'sk_base',
                  onEnd: _endInteraction,
                ),
              ),

            // End run card
            if (remembered != null)
              Center(
                child: Container(
                  padding: const EdgeInsets.all(28),
                  decoration: BoxDecoration(
                    color: const Color(0xF2201A38),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: const Color(0xFFFFC233), width: 2),
                  ),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    const Text('Dawn comes.',
                        style: TextStyle(fontSize: 22, color: Color(0xFFFFC233))),
                    const SizedBox(height: 10),
                    Text('$remembered spirits remembered · $fadedCount faded',
                        style: const TextStyle(color: Color(0xFFDCD4F0))),
                  ]),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _Hud extends StatelessWidget {
  final SimEngine engine;
  final int petals;
  const _Hud({required this.engine, required this.petals});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xD0201A38),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF3A2C50)),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        const Text('🌼', style: TextStyle(fontSize: 13)),
        const SizedBox(width: 4),
        Text('$petals',
            key: const Key('petalCount'),
            style: const TextStyle(fontSize: 13, color: Color(0xFFFFC233))),
        const SizedBox(width: 12),
        const Icon(Icons.nights_stay, size: 14, color: Color(0xFF8D84B0)),
        const SizedBox(width: 4),
        ValueListenableBuilder<int>(
          valueListenable: _clockListenable(engine),
          builder: (_, ts, _) {
            final left = (engine.dawnAt - ts).clamp(0, 1 << 30);
            final m = left ~/ 60, s = left % 60;
            return Text('$m:${s.toString().padLeft(2, '0')}',
                key: const Key('dawnTimer'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF8D84B0)));
          },
        ),
        const SizedBox(width: 12),
        Text(engine.llm.name,
            style: const TextStyle(fontSize: 10, color: Color(0xFF5A5078))),
      ]),
    );
  }

  ValueNotifier<int> _clockListenable(SimEngine e) =>
      _ClockHolder.instance.notifier(e);
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
