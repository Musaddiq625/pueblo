/// PuebloGame — Flame layer: camera (pinch zoom + pan), gesture arbitration,
/// sprite loading, SimEvent → component wiring.
library;

import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart' hide Image;

import '../sim/engine.dart';
import '../sim/models.dart';
import 'components.dart';
import 'sprites_manifest.dart';
import 'world_def.dart';

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

  PuebloGame({
    required this.engine,
    required this.onEngage,
    required this.onPoiInspect,
    required this.onPetalsChanged,
    required this.onEndRun,
  });

  double _startZoom = 1;

  @override
  Future<void> onLoad() async {
    images.prefix = 'assets/sprites/';

    // ---- world ----
    final floors = await images.load('town/floors.png');
    await world.add(
        GroundComponent(size: Vector2(mapW, mapH), floors: floors));
    await world.add(PetalDriftComponent(Vector2(mapW, mapH)));

    // papel picado strings across plaza + market
    for (final p in const [
      [560.0, 240.0, 280.0], [400.0, 300.0, 260.0], [900.0, 300.0, 260.0]
    ]) {
      await world.add(PapelPicadoComponent(
          pos: Vector2(p[0], p[1]), size: Vector2(p[2], 26)));
    }

    // ---- POIs ----
    for (final poi in engine.pois.values) {
      await world.add(await _buildPoi(poi));
    }

    // ---- player ----
    player = await _char(kPlayerChar, Vector2(700, 140), PlayerComponent.new);
    await world.add(player!);

    // ---- spirits ----
    for (final agent in engine.agents.values) {
      final comp = await _spirit(agent);
      spirits[agent.id] = comp;
      await world.add(comp);
    }

    // ---- chispa guide ----
    chispa = ChispaComponent(follow: player!);
    await world.add(chispa!);
    _chispa('¡Ay — a living one! Spirits fade when forgotten. Talk to them, mijo.');

    // ---- camera ----
    camera.viewfinder.zoom = 1.15;
    camera.follow(player!);

    // ---- sim wiring ----
    engine.events.listen(_onSimEvent);

    // scatter initial petals
    for (var i = 0; i < 10; i++) {
      _spawnPetal();
    }
  }

  static const kPlayerChar = 'knight';

  Future<PlayerComponent> _char(
      String key, Vector2 pos,
      PlayerComponent Function({required Vector2 pos,
          required SpriteAnimation idle,
          required SpriteAnimation walk}) ctor) async {
    final def = chars[key]!;
    final idle = await _anim(def.idle);
    final walk = await _anim(def.walk);
    return ctor(pos: pos, idle: idle, walk: walk);
  }

  Future<SpiritComponent> _spirit(Agent a) async {
    // pick sprite per persona def (stored in a map populated at bootstrap)
    final key = personaSprite[a.id] ?? 'sk_base';
    final def = chars[key]!;
    final idle = await _anim(def.idle);
    final walk = await _anim(def.walk);
    final c = SpiritComponent(
      agent: a,
      charKey: key,
      onTapped: onEngage,
      idle: idle,
      walk: walk,
    );
    if (a.faded) c.setFaded(true);
    return c;
  }

  static Map<String, String> personaSprite = {};

  Future<SpriteAnimation> _anim(SheetDef s) async {
    final img = await images.load(s.path);
    // Vertical sheets (frameW == img.width, frames > 1) are sliced manually —
    // sequenced+amountPerRow mis-slices them into a horizontal filmstrip.
    if (s.frames > 1 && s.frameW >= img.width) {
      final sprites = List.generate(
          s.frames,
          (i) => Sprite(img,
              srcPosition: Vector2(0, i * s.frameH),
              srcSize: Vector2(s.frameW, s.frameH)));
      return SpriteAnimation.spriteList(sprites,
          stepTime: s.stepTime, loop: true);
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

  int _perRow(int sheetW, double frameW) =>
      max(1, (sheetW / frameW).floor());

  Future<PoiComponent> _buildPoi(Poi p) async {
    PositionComponent? visual;
    switch (p.id) {
      case 'ancient_tree':
        // variant sheet: 4 cols × variants — the bare dead tree (col 2, row 0)
        // is the spirit-world ceiba. Crop just that frame, not the sheet.
        final img = await images.load(objects['ancient_tree']!.path);
        visual = SpriteComponent(
            sprite: Sprite(img,
                srcPosition: Vector2(224, 0), srcSize: Vector2(112, 160)),
            size: Vector2(140, 200),
            anchor: Anchor.bottomCenter, position: Vector2(0, 14));
      case 'curiosity_shop':
        visual = SpriteAnimationComponent(
            animation: await _anim(objects['alchemy_table']!),
            size: Vector2(40, 80), anchor: Anchor.bottomCenter,
            position: Vector2(0, 8));
      case 'ofrenda':
        visual = SpriteAnimationComponent(
            animation: await _anim(objects['bonfire']!),
            size: Vector2(70, 70), anchor: Anchor.bottomCenter,
            position: Vector2(0, 8));
      default:
        // small stone/marker placeholder — colored base
        visual = _PoiMarker(p);
    }
    return PoiComponent(poi: p, onInspect: onPoiInspect, visual: visual);
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
      // pan
      final zoom = camera.viewfinder.zoom;
      camera.moveBy((info.delta.global..negate()) / zoom);
    }
  }

  // Trackpad pinch arrives as PointerPanZoom events at the widget layer —
  // Flame 1.38 has no PanZoomDetector, so main.dart's Listener forwards here.
  void trackpadPinch(double scale, Offset panDelta) {
    if (scale != 1.0) {
      camera.viewfinder.zoom =
          (camera.viewfinder.zoom * scale).clamp(0.8, 2.5);
    }
    final d = Vector2(panDelta.dx, panDelta.dy);
    if (d.length2 > 0) camera.moveBy(-d / camera.viewfinder.zoom);
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
        _bubble(e.data['agent'], e.data['line']);
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
                key: 'first_engage');
          }
        }
        if (e.data.containsKey('faded')) {
          c.setFaded(e.data['faded'] as bool);
          if (e.data['faded'] as bool) {
            _chispa(
                '${a.name} is fading — forgotten things go translucent. Say their name.',
                key: 'first_fade');
          }
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
        if (t.startsWith('bought')) _chispa('A gift goes further than a question, mijo.');
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
    c.add(BubbleComponent(line,
        size: Vector2(220, 44))
      ..position = Vector2(0, -c.size.y - 6));
  }

  void _emote(String agentId, String glyph) {
    final c = spirits[agentId];
    if (c == null) return;
    c.add(BubbleComponent(glyph, isEmote: true, size: Vector2(60, 40))
      ..position = Vector2(0, -c.size.y - 4));
  }

  void _spawnPetal() {
    final r = engine.rng;
    final x = 300 + r.nextDouble() * 800;
    final y = 200 + r.nextDouble() * 450;
    world.add(PetalComponent(pos: Vector2(x, y)));
  }

  @override
  void update(double dt) {
    super.update(dt);
    engine.tick(dt);
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

/// A small shrine-stone marker + name label for POIs without custom art.
class _PoiMarker extends PositionComponent {
  _PoiMarker(this._p)
      : super(size: Vector2(48, 40), anchor: Anchor.bottomCenter);
  final Poi _p;

  @override
  void render(Canvas canvas) {
    // stone — rounded upright slab
    final slab = RRect.fromRectAndRadius(
        Rect.fromLTWH(14, 2, 20, 34), const Radius.circular(8));
    canvas.drawRRect(slab, Paint()..color = const Color(0xFF2E2450));
    canvas.drawRRect(
        slab,
        Paint()
          ..color = const Color(0xFF6A5A98)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    // candle glow dot
    canvas.drawCircle(
        Offset(24, 12), 3.5, Paint()..color = const Color(0xFFFFC233));
    // name label below the stone
    final tp = TextPainter(
      text: TextSpan(
          text: _p.name.toLowerCase(),
          style: const TextStyle(
              fontSize: 9, color: Color(0xCCBDB4E0), fontFamily: 'monospace')),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((size.x - tp.width) / 2, size.y - 6));
  }
}
