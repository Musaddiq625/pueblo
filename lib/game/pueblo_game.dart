/// PuebloGame — Flame layer: camera (pinch zoom + pan), gesture arbitration,
/// sprite loading, SimEvent → component wiring.
library;

import 'dart:async' as async_;
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart' hide Image;

import '../sim/engine.dart';
import '../sim/models.dart';
import 'components.dart';
import 'sprites_manifest.dart';
import 'tilemap.dart';
import 'world_def.dart';
import '../sim/world_map.dart';

class PuebloGame extends FlameGame with ScaleDetector, TapCallbacks {
  final SimEngine engine;
  final void Function(Agent) onEngage;
  final void Function(Poi) onPoiInspect;
  final void Function() onPetalsChanged;
  final void Function(int remembered, int faded) onEndRun;

  final Map<String, SpiritComponent> spirits = {};
  PlayerComponent? player;
  ChispaComponent? chispa;
  bool sheetOpen = false;
  final Set<String> _chispaSeen = {};
  List<(int, int)> _walkTiles = [];

  /// Recent spirit speech — (speakerName, line), newest last, capped.
  /// The Flutter overlay renders this as the town log so dialogue is
  /// never lost when a bubble is missed.
  final townLog = ValueNotifier<List<(String, String)>>([]);

  /// Lines that arrived while the spirit was mid-stride — delivered
  /// once they stop walking (speech never drops silently).
  final _speechQueue = <String, List<String>>{};

  PuebloGame({
    required this.engine,
    required this.onEngage,
    required this.onPoiInspect,
    required this.onPetalsChanged,
    required this.onEndRun,
  });

  double _startZoom = 1;

  bool worldLoaded = false;

  @override
  Future<void> onLoad() async {
    activeGame = this;
    images.prefix = 'assets/sprites/';
    try {
      await _loadAll();
      worldLoaded = true;
    } catch (e, st) {
      debugPrint('PUEBLO onLoad FAILED: $e\n$st');
      rethrow;
    }
  }

  Future<void> _loadAll() async {

    // ---- world (authored tilemap) ----
    final tileAssets = await TileAssets.load(images);
    final groundImg = await bakeGround(tileAssets);
    await world.add(
      SpriteComponent(
        sprite: Sprite(groundImg),
        size: Vector2(mapW, mapH),
        priority: -999999999,
      ),
    );
    await world.add(RiverComponent());
    // candles breathing on the great ofrenda + the nameless grave
    await world.add(CandleFlickerComponent(Vector2(tileX(19), tileY(22))));
    await world.add(
      CandleFlickerComponent(Vector2(tileX(40), tileY(17)), count: 2),
    );
    for (final p in buildProps(tileAssets)) {
      await world.add(p);
    }
    // collect walkable tiles once — petal scatter + spawn checks use them
    _walkTiles = [
      for (var y = 0; y < kMapTilesH; y++)
        for (var x = 0; x < kMapTilesW; x++)
          if (engine.nav.walkable(x, y)) (x, y),
    ];
    await world.add(PetalDriftComponent(Vector2(mapW, mapH)));

    // papel picado strings across the market street
    for (final p in const [
      [180.0, 315.0, 240.0],
      [450.0, 315.0, 240.0],
      [730.0, 315.0, 240.0],
      [1000.0, 315.0, 240.0],
      // one across the plaza's north rim
      [540.0, 400.0, 250.0],
    ]) {
      await world.add(
        PapelPicadoComponent(pos: Vector2(p[0], p[1]), size: Vector2(p[2], 26)),
      );
    }

    // ---- POIs ----
    for (final poi in engine.pois.values) {
      await world.add(await _buildPoi(poi));
    }

    // ---- player — spawns on the bridge landing, walking south ----
    player = await _char(
      kPlayerChar,
      Vector2(tileX(21), tileY(3)),
      PlayerComponent.new,
    );
    await world.add(player!);

    // ---- spirits ----
    for (final agent in engine.agents.values) {
      final comp = await _spirit(agent);
      spirits[agent.id] = comp;
      await world.add(comp);
      // name tag at world level — never occluded by depth sorting
      await world.add(SpiritLabelComponent(comp));
    }

    // ---- chispa guide ----
    chispa = ChispaComponent(follow: player!);
    await world.add(chispa!);
    _chispa(
      '¡Ay — a living one! Spirits fade when forgotten. Talk to them, mijo.',
    );

    // ---- camera ----
    camera.viewfinder.zoom = 1.15;
    camera.follow(player!);

    // ---- sim wiring ----
    engine.events.listen(_onSimEvent);

    // The town must live even when the window is occluded — macOS pauses
    // the display link, so Flame's update() stops. Fall back to a timer
    // that ticks the sim whenever the render loop has stalled.
    _lastFrameAt = DateTime.now();
    _simPump = async_.Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (DateTime.now().difference(_lastFrameAt).inMilliseconds > 300) {
        try {
          engine.tick(0.1);
        } catch (e, st) {
          debugPrint('PUEBLO pump FAILED: $e\n$st');
        }
      }
    });

    // scatter initial petals
    for (var i = 0; i < 10; i++) {
      _spawnPetal();
    }
  }

  static const kPlayerChar = 'knight';

  Future<PlayerComponent> _char(
    String key,
    Vector2 pos,
    PlayerComponent Function({
      required Vector2 pos,
      required SpriteAnimation idle,
      required SpriteAnimation walk,
      required Vector2 displaySize,
    })
    ctor,
  ) async {
    final def = chars[key]!;
    final idle = await _anim(def.idle);
    final walk = await _anim(def.walk);
    return ctor(
      pos: pos,
      idle: idle,
      walk: walk,
      displaySize: Vector2(def.displayW, def.displayH),
    );
  }

  Future<SpiritComponent> _spirit(Agent a) async {
    // pick sprite per persona def (stored in a map populated at bootstrap)
    final key = personaSprite[a.id] ?? 'sk_base';
    final def = chars[key]!;
    final idle = await _anim(def.idle);
    final walk = await _anim(def.walk);
    final death = def.death == null
        ? null
        : await _anim(def.death!, loop: false);
    final c = SpiritComponent(
      agent: a,
      charKey: key,
      onTapped: onEngage,
      idle: idle,
      walk: walk,
      death: death,
      displaySize: Vector2(def.displayW, def.displayH),
      // short name under the feet — "Ramón el Trovador" reads as "Ramón"
      // in-world; the full name lives in the inspect card + town log
      displayName: a.name.split(' ').first,
      auraColor: personaTint[a.id] != null ? Color(personaTint[a.id]!) : null,
    );
    if (a.faded) c.setFaded(true);
    return c;
  }

  static Map<String, String> personaSprite = {};
  static Map<String, int> personaTint = {};

  /// Set in onLoad — lets the driver extension reach the live game.
  static PuebloGame? activeGame;

  /// DRIVER 'shot' command → writes a frame PNG, returns its path.
  /// Wired to _PuebloAppState._dumpFrame in main.dart.
  static Future<String> Function()? shotHook;

  // ---------------- driver bridge (DRIVER=true runs only) ----------------
  //
  // The game world's "element keys": every entity is addressable by
  // name/id — no coordinate guessing. Wired by main.dart to both the
  // flutter_driver requestData channel and an `ext.pueblo.cmd` VM
  // service extension.

  Map<String, dynamic> driverState() {
    Vector2 screen(Vector2 w) => camera.localToGlobal(Vector2.copy(w));
    return {
      'simTs': engine.simTs,
      'petals': engine.playerPetals,
      'engaged': engine.engagedId,
      'llm': engine.llm.name,
      'camera': {
        'zoom': camera.viewfinder.zoom,
        'center': [
          camera.viewfinder.position.x.round(),
          camera.viewfinder.position.y.round(),
        ],
      },
      'spirits': [
        for (final a in engine.agents.values)
          {
            'id': a.id,
            'name': a.name,
            'x': a.x.round(),
            'y': a.y.round(),
            'screen': screen(Vector2(a.x, a.y))
                .toString()
                .replaceAll('Vector2', 's'),
            'engaged': a.engaged,
            'inConvo': a.inConvo,
            'faded': a.faded,
            'solidified': a.solidified,
            'battery': a.battery.round(),
          },
      ],
      'pois': [
        for (final p in engine.pois.values)
          {
            'id': p.id,
            'name': p.name,
            'x': p.x.round(),
            'y': p.y.round(),
            'screen': screen(Vector2(p.x, p.y))
                .toString()
                .replaceAll('Vector2', 's'),
          },
      ],
    };
  }

  String? _agentIdFor(String nameOrId) {
    final q = nameOrId.toLowerCase();
    for (final a in engine.agents.values) {
      if (a.id.toLowerCase() == q || a.name.toLowerCase().contains(q)) {
        return a.id;
      }
    }
    return null;
  }

  String? _poiIdFor(String nameOrId) {
    final q = nameOrId.toLowerCase();
    for (final p in engine.pois.values) {
      if (p.id.toLowerCase() == q || p.name.toLowerCase().contains(q)) {
        return p.id;
      }
    }
    return null;
  }

  /// String command → string response. Commands mirror real user input
  /// paths (engage uses the same callback a real tap does).
  Future<String> driverCommand(String? raw) async {
    final cmd = (raw ?? '').trim();
    final parts = cmd.split(RegExp(r'\s+'));
    final arg = parts.length > 1 ? parts.sublist(1).join(' ') : '';
    switch (parts.first) {
      case 'state':
        return jsonEncode(driverState());
      case 'world':
        final lc = WidgetsBinding.instance.lifecycleState;
        return 'loaded=$worldLoaded children=${world.children.length} '
            'mounts=${world.children.where((c) => c.isMounted).length} '
            'spirits=${spirits.length} player=${player != null} '
            'paused=$paused lifecycle=$lc ticks=$_tickCount';
      case 'tap_spirit':
        final id = _agentIdFor(arg);
        if (id == null) return 'ERR no spirit "$arg"';
        onEngage(engine.agents[id]!);
        return 'ok engaged $id';
      case 'tap_poi':
        final id = _poiIdFor(arg);
        if (id == null) return 'ERR no poi "$arg"';
        onPoiInspect(engine.pois[id]!);
        return 'ok poi $id';
      case 'release':
        engine.disengage();
        return 'ok released';
      case 'chat':
        if (engine.engagedId == null) return 'ERR nobody engaged';
        final sb = StringBuffer();
        await for (final c in engine.sendPlayerMessage(arg)) {
          sb.write(c);
        }
        return 'reply: ${sb.toString()}';
      case 'zoom':
        final z = double.tryParse(arg);
        if (z == null) return 'ERR bad zoom';
        camera.viewfinder.zoom = z.clamp(0.8, 2.5);
        return 'ok zoom ${camera.viewfinder.zoom}';
      case 'center':
        if (player != null) camera.follow(player!);
        return 'ok centered';
      case 'look':
        // stop following + jump the viewfinder to world coords (tiles*32)
        camera.stop();
        final ps = arg.split(' ');
        if (ps.length != 2) return 'ERR look <tx> <ty>';
        final tx = double.tryParse(ps[0]), ty = double.tryParse(ps[1]);
        if (tx == null || ty == null) return 'ERR look <tx> <ty>';
        camera.viewfinder.position = Vector2(tx * 32 + 16, ty * 32 + 16);
        return 'ok look $tx $ty';
      case 'shot':
        final hook = shotHook;
        if (hook == null) return 'ERR shot hook not wired';
        return 'ok ${await hook()}';
      default:
        return 'ERR unknown command: $cmd '
            '(state|tap_spirit|tap_poi|release|chat|zoom|center)';
    }
  }

  Future<SpriteAnimation> _anim(SheetDef s, {bool loop = true}) async {
    final img = await images.load(s.path);
    // Vertical sheets (frameW == img.width, frames > 1) are sliced manually —
    // sequenced+amountPerRow mis-slices them into a horizontal filmstrip.
    final vertical = s.frames > 1 && s.frameW >= img.width;
    if (vertical || !loop) {
      final sprites = List.generate(
        s.frames,
        (i) => Sprite(
          img,
          srcPosition: vertical
              ? Vector2(0, i * s.frameH)
              : Vector2(i * s.frameW, 0),
          srcSize: Vector2(s.frameW, s.frameH),
        ),
      );
      return SpriteAnimation.spriteList(
        sprites,
        stepTime: s.stepTime,
        loop: loop,
      );
    }
    return SpriteAnimation.fromFrameData(
      img,
      SpriteAnimationData.sequenced(
        amount: s.frames,
        stepTime: s.stepTime,
        textureSize: Vector2(s.frameW, s.frameH),
        amountPerRow: _perRow(img.width, s.frameW),
      ),
    );
  }

  int _perRow(int sheetW, double frameW) => max(1, (sheetW / frameW).floor());

  /// POIs: the tilemap props draw the structures — the component adds
  /// the inspect glow + tap target; the nameplate is a world-level overlay
  /// so props standing in front can't clip it.
  Future<PoiComponent> _buildPoi(Poi p) async {
    await world.add(_PoiLabel(p));
    return PoiComponent(poi: p, onInspect: onPoiInspect);
  }

  // ---------------------------- gestures -----------------------------------

  @override
  void onScaleStart(ScaleStartInfo info) => _startZoom = camera.viewfinder.zoom;

  @override
  void onScaleUpdate(ScaleUpdateInfo info) {
    final s = info.scale.global;
    if (!s.isIdentity()) {
      camera.viewfinder.zoom = (_startZoom * s.y).clamp(0.8, 2.5);
    } else {
      // pan — manual pan takes camera off follow mode
      camera.stop();
      final zoom = camera.viewfinder.zoom;
      camera.moveBy((info.delta.global..negate()) / zoom);
    }
  }

  // Trackpad pinch arrives as PointerPanZoom events at the widget layer —
  // Flame 1.38 has no PanZoomDetector, so main.dart's Listener forwards here.
  void trackpadPinch(double scale, Offset panDelta) {
    if (scale != 1.0) {
      camera.viewfinder.zoom = (camera.viewfinder.zoom * scale).clamp(0.8, 2.5);
    }
    final d = Vector2(panDelta.dx, panDelta.dy);
    if (d.length2 > 0) {
      camera.stop();
      camera.moveBy(-d / camera.viewfinder.zoom);
    }
  }

  /// Keep the viewport inside the map — no void past the village border.
  /// (viewfinder.position is a computed getter — assign, don't mutate.)
  void _clampCamera() {
    final r = camera.visibleWorldRect;
    final p = camera.viewfinder.position;
    final x = r.width >= mapW
        ? mapW / 2
        : p.x.clamp(r.width / 2, mapW - r.width / 2);
    final y = r.height >= mapH
        ? mapH / 2
        : p.y.clamp(r.height / 2, mapH - r.height / 2);
    if (x != p.x || y != p.y) camera.viewfinder.position = Vector2(x, y);
  }

  @override
  void onTapUp(TapUpEvent event) {
    final p = camera.globalToLocal(event.canvasPosition);
    // Arbitration: spirits > POIs > ground move. Sheet open blocks ground.
    final spirit = _spiritAt(p);
    if (spirit != null) {
      onEngage(spirit.agent);
      return;
    }
    if (sheetOpen) return; // while engaged, world taps do nothing
    final poi = _poiAt(p);
    if (poi != null) {
      onPoiInspect(poi.poi);
      return;
    }
    world.add(ClickMarker(p));
    player?.walkTo(p);
  }

  SpiritComponent? _spiritAt(Vector2 p) {
    SpiritComponent? best;
    var bd = 42.0 * 42.0;
    for (final s in spirits.values) {
      final d = s.position.distanceToSquared(p);
      if (d < bd) {
        bd = d;
        best = s;
      }
    }
    return best;
  }

  PoiComponent? _poiAt(Vector2 p) {
    for (final c in world.children.whereType<PoiComponent>()) {
      if (c.position.distanceToSquared(p) < c.poi.radius * c.poi.radius) {
        return c;
      }
    }
    return null;
  }

  // ---------------------------- sim events ---------------------------------

  void _onSimEvent(SimEvent e) {
    switch (e.type) {
      case SimEventType.move:
        final c = spirits[e.data['agent']];
        if (c != null && !c.agent.engaged) {
          c.movePath(List<List<double>>.from(e.data['path']));
        }
      case SimEventType.say:
        // town log — every line lands here even if a bubble can't show
        final id = e.data['agent'] as String;
        final line = e.data['line'] as String;
        if (line.isNotEmpty) {
          final name = engine.agents[id]?.name ?? id;
          final log = townLog.value;
          // skip consecutive duplicates — the same line said twice in a
          // row reads as a bug, not emphasis
          if (log.isEmpty ||
              log.last != (name, line)) {
            townLog.value = [...log, (name, line)]
                .reversed
                .take(5)
                .toList()
                .reversed
                .toList();
          }
        }
        _bubble(id, line);
      case SimEventType.emote:
        _emote(e.data['agent'], e.data['glyph']);
      case SimEventType.state:
        final a = engine.agents[e.data['agent']]!;
        final c = spirits[a.id];
        if (c == null) return;
        if (e.data.containsKey('engaged')) {
          c.setEngaged(e.data['engaged'] as bool);
          if (e.data['engaged'] as bool) {
            c.faceToward(player!.position.x);
            _chispa(
              'That\'s ${a.name}. They\'ll stay as long as you listen.',
              key: 'first_engage',
            );
          }
        }
        if (e.data.containsKey('faded')) {
          c.setFaded(e.data['faded'] as bool);
          if (e.data['faded'] as bool) {
            _chispa(
              '${a.name} is fading — forgotten things go translucent. Say their name.',
              key: 'first_fade',
            );
          }
        }
        // arrival facing — spirit turns toward its activity target.
        // Side-view sprites only have left/right; pure vertical facing
        // (fountain rim, ofrenda) keeps the last horizontal heading.
        if (e.data.containsKey('fx')) {
          final fx = (e.data['fx'] as num).toDouble();
          if (fx != 0) c.faceToward(c.position.x + fx);
        }
      case SimEventType.pairStart:
        for (final id in [e.data['a'], e.data['b']]) {
          spirits[id]?.walking = false;
          _emote(id as String, '💬');
        }
      case SimEventType.poiGlow:
        for (final c in world.children.whereType<PoiComponent>()) {
          if (c.poi.id == e.data['poi']) {
            c.glowing = e.data['on'] as bool;
          }
        }
      case SimEventType.petalSpawn:
        _spawnPetal();
      case SimEventType.log:
        final t = e.data['text'] as String;
        // Narration ("X tells Y: …", unheard mutters) lands in the town
        // log too — quieter than a bubble, but still visible to the player.
        if (t.contains(': ')) {
          townLog.value = [...townLog.value, ('·', t)]
              .reversed
              .take(5)
              .toList()
              .reversed
              .toList();
        }
        if (t.startsWith('bought')) {
          _chispa('A gift goes further than a question, mijo.');
        }
        if (t.contains('solidifies')) {
          _chispa('Look — the town remembered. That\'s resurrection.');
        }
      case SimEventType.endRun:
        onEndRun(e.data['remembered'], e.data['faded']);
      default:
        break;
    }
  }

  /// Chispa speaks — each trigger fires once per run (canned, zero inference).
  void _chispa(String line, {String? key}) {
    final k = key ?? line;
    if (!_chispaSeen.add(k)) return;
    chispa?.say(line);
  }

  void _bubble(String agentId, String line) {
    final c = spirits[agentId];
    if (c == null || line.isEmpty) return;
    if (c.walking) {
      // hold the line — delivered in update() when they stop
      final q = _speechQueue[agentId] ??= [];
      q.add(line);
      if (q.length > 2) q.removeAt(0);
      return;
    }
    for (final b in c.children.whereType<BubbleComponent>()) {
      b.removeFromParent();
    }
    c.add(
      BubbleComponent(
        line,
        speaker: engine.agents[agentId]?.name.split(' ').first ?? '',
        size: Vector2(220, 44),
      )..position = Vector2(0, -c.size.y - 6),
    );
  }

  void _emote(String agentId, String glyph) {
    final c = spirits[agentId];
    if (c == null) return;
    c.add(
      BubbleComponent(glyph, isEmote: true, size: Vector2(60, 40))
        ..position = Vector2(0, -c.size.y - 4),
    );
  }

  void _spawnPetal() {
    final r = engine.rng;
    if (_walkTiles.isEmpty) return;
    final t = _walkTiles[r.nextInt(_walkTiles.length)];
    world.add(
      PetalComponent(
        pos: Vector2(
          tileX(t.$1) + r.nextDouble() * 16 - 8,
          tileY(t.$2) + r.nextDouble() * 16 - 8,
        ),
      ),
    );
  }

  int _tickCount = 0;
  DateTime _lastFrameAt = DateTime.now();
  async_.Timer? _simPump;

  @override
  void onRemove() {
    _simPump?.cancel();
    super.onRemove();
  }

  @override
  void update(double dt) {
    super.update(dt);
    _lastFrameAt = DateTime.now();
    _tickCount++;
    try {
      engine.tick(dt);
    } catch (e, st) {
      debugPrint('PUEBLO tick FAILED: $e\n$st');
    }
    _clampCamera();
    // deliver speech held while the spirit was walking
    for (final id in _speechQueue.keys.toList()) {
      final c = spirits[id];
      final q = _speechQueue[id]!;
      if (c == null || c.walking || q.isEmpty) continue;
      final line = q.removeAt(0);
      if (q.isEmpty) _speechQueue.remove(id);
      _bubble(id, line);
    }
    // petal pickup on walk-over
    if (player != null) {
      for (final petal in world.children.whereType<PetalComponent>().toList()) {
        if (petal.position.distanceToSquared(player!.position) < 900) {
          petal.removeFromParent();
          engine.playerPetals++;
          onPetalsChanged();
        }
      }
    }
  }
}

/// Floating name label for a POI — lives at world level so it draws above
/// nearby props; nameplate sits just above the structure's base.
class _PoiLabel extends PositionComponent {
  _PoiLabel(Poi p)
    : _p = p,
      super(
        size: Vector2(140, 20),
        anchor: Anchor.bottomCenter,
        position: Vector2(p.x, p.y - 20),
        priority: 3000000,
      );
  final Poi _p;

  @override
  void render(Canvas canvas) {
    final tp = TextPainter(
      text: TextSpan(
        text: _p.name.toLowerCase(),
        style: const TextStyle(
          fontSize: 10,
          color: Color(0xE6D9D2C8),
          fontFamily: 'monospace',
          shadows: [Shadow(color: Color(0xFF000000), blurRadius: 3)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.x - tp.width) / 2, 0));
  }
}
