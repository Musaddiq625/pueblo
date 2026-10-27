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
  bool sheetOpen = false;

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
    await world.add(GroundComponent(size: Vector2(mapW, mapH)));
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
        final img = await images.load(objects['ancient_tree']!.path);
        visual = SpriteComponent(
            sprite: Sprite(img), size: Vector2(190, 156),
            anchor: Anchor.bottomCenter, position: Vector2(0, 8));
      case 'curiosity_shop':
        visual = SpriteAnimationComponent(
            animation: await _anim(objects['alchemy_table']!),
            size: Vector2(110, 40), anchor: Anchor.bottomCenter,
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
          if (e.data['engaged'] as bool) c.faceToward(player!.position.x);
        }
        if (e.data.containsKey('faded')) c.setFaded(e.data['faded'] as bool);
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
      case SimEventType.endRun:
        onEndRun(e.data['remembered'], e.data['faded']);
      default:
        break;
    }
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

/// Simple colored marker for POIs without custom art yet.
class _PoiMarker extends PositionComponent {
  _PoiMarker(Poi p) : super(size: Vector2(56, 34), anchor: Anchor.bottomCenter);

  @override
  void render(Canvas canvas) {
    canvas.drawRRect(
        RRect.fromRectAndRadius(size.toRect(), const Radius.circular(6)),
        Paint()..color = const Color(0xFF3A2C50));
    canvas.drawRRect(
        RRect.fromRectAndRadius(size.toRect(), const Radius.circular(6)),
        Paint()
          ..color = const Color(0xFF8A6FC0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);
  }
}
