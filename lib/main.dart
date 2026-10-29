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

  // --dart-define switches: SIM_SEED, SIM_TIME_SCALE, LLM=model, DEMO=1
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
              pois: poiDefs,
              homePos: homePositions({for (final p in poiDefs) p.id: p}),
              llm: GemmaLocalClient(rng: Random(seed)),
              rng: Random(seed),
              timeScale: demo ? 6.0 : timeScale,
              dawnAt: demo ? 600 : 900,
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

  final LLMClient llm = llmName == 'mock'
      ? MockLLMClient(seed: seed)
      : OllamaClient(model: llmName);

  Future<SimBundle> mkBundle() => bootstrap(
    personasJson: personasJson,
    secretsJson: secretsJson,
    pois: poiDefs,
    homePos: homePositions({for (final p in poiDefs) p.id: p}),
    llm: llm,
    rng: Random(seed),
    timeScale: demo ? 6.0 : timeScale,
    dawnAt: demo ? 600 : 900,
    freshDb: true,
    dbPath: 'pueblo_sim.db',
  );

  Future<void> launch() async {
    final bundle = await mkBundle();
    PuebloGame.personaSprite = bundle.sprites;
    PuebloGame.personaTint = bundle.tints;
    PuebloGame.personaDye = bundle.dyes;
    runApp(PuebloApp(bundle: bundle, onNewNight: launch));
  }

  await launch();
}

class PuebloApp extends StatefulWidget {
  final SimBundle bundle;

  /// Dawn card → rebuild the whole sim + app for another night.
  final Future<void> Function()? onNewNight;
  const PuebloApp({super.key, required this.bundle, this.onNewNight});
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
  String? verdictNote; // the arc's resolution, if a verdict fired tonight
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
        engine.disengage(); // close any open InspectCard under the dawn card
      }),
    );
    // DRIVER 'shot' command → capture the RepaintBoundary, return the path.
    PuebloGame.shotHook = () async {
      await _dumpFrame();
      final dir = await getApplicationDocumentsDirectory();
      return '${dir.path}/pueblo_frame.png';
    };
    PuebloGame.rosterHook = () => setState(() => rosterOpen = true);
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
                    spiritSprite:
                        PuebloGame.personaSprite[engaged] ?? 'sk_base',
                    spiritDye: PuebloGame.personaDye[engaged],
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

              // End run card — the night is over; offer a new one.
              if (remembered != null)
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
                          'Dawn comes.',
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
                        if (widget.onNewNight != null)
                          FilledButton.icon(
                            key: const Key('newNightButton'),
                            icon: const Icon(Icons.bedtime, size: 16),
                            label: const Text('New night'),
                            style: FilledButton.styleFrom(
                              backgroundColor: const Color(0xFFEF8C1A),
                              foregroundColor: const Color(0xFF1A1430),
                            ),
                            onPressed: () => widget.onNewNight!(),
                          ),
                      ],
                    ),
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
          const Icon(Icons.nights_stay, size: 14, color: Color(0xFF8D84B0)),
          const SizedBox(width: 4),
          ValueListenableBuilder<int>(
            valueListenable: _clockListenable(engine),
            builder: (_, ts, _) {
              final left = (engine.dawnAt - ts).clamp(0, 1 << 30);
              final m = left ~/ 60, s = left % 60;
              return Text(
                '$m:${s.toString().padLeft(2, '0')}',
                key: const Key('dawnTimer'),
                style: const TextStyle(fontSize: 12, color: Color(0xFF8D84B0)),
              );
            },
          ),
          const SizedBox(width: 12),
          Text(
            engine.llm.name,
            style: const TextStyle(fontSize: 10, color: Color(0xFF5A5078)),
          ),
          const SizedBox(width: 12),
          _CuadernoChip(engine: engine),
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
}

/// The living one's notebook — what the night has taught them. What they
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
/// persona, stat stars, what it's carrying, and whether the night has
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
                    'the remembered — who walks tonight',
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
                // dossier — everything the night knows about this spirit
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
                    '(${d.initialSecrets} from the start, ${d.learnedSecrets.length} learned tonight)',
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
                    '🌱 grown tonight? ',
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
/// through quiet stretches of the night.
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
