/// Intro cinematic — a popup-sized Flame scene showing the theft.
///
/// Renders the REAL village: same baked ground, same props, same
/// character sheets — the camera just crops to the Great Ofrenda and
/// zooms in. A silhouette (hiding face and body, as it should) crosses
/// the altar, a portrait goes dark, and two villagers find it missing.
/// No video asset, no separate art — it can only ever look like the game.
library;

import 'dart:math';
import 'dart:ui' show BlendMode, ColorFilter, Paint;

import 'package:flame/components.dart';
import 'package:flame/game.dart';
import 'package:flutter/material.dart' show Color, TextStyle;

import 'sprites_manifest.dart';
import 'tilemap.dart';
import 'world_def.dart' show mapW, mapH;
import '../sim/world_map.dart' show poiTiles, tileX, tileY;

class IntroScene extends FlameGame {
  final void Function() onDone;
  IntroScene({required this.onDone});

  /// The ofrenda altar — where the crop centers.
  static final Vector2 _ofrenda =
      Vector2(tileX(poiTiles['ofrenda']!.$1), tileY(poiTiles['ofrenda']!.$2));

  double _t = 0;
  bool _done = false;

  late final SpriteAnimationComponent _shadow;
  late final SpriteAnimationComponent _walkA;
  late final SpriteAnimationComponent _walkB;
  late final RectangleComponent _frame;
  final _bubbles = <PositionComponent>[];

  Future<SpriteAnimation> _anim(SheetDef s) async {
    final img = await images.load(s.path);
    final vertical = s.frames > 1 && s.frameW >= img.width;
    if (vertical) {
      return SpriteAnimation.spriteList(
        [
          for (var i = 0; i < s.frames; i++)
            Sprite(
              img,
              srcPosition: Vector2(0, i * s.frameH),
              srcSize: Vector2(s.frameW, s.frameH),
            ),
        ],
        stepTime: s.stepTime,
      );
    }
    return SpriteAnimation.fromFrameData(
      img,
      SpriteAnimationData.sequenced(
        amount: s.frames,
        stepTime: s.stepTime,
        textureSize: Vector2(s.frameW, s.frameH),
        amountPerRow: max(1, (img.width / s.frameW).floor()),
      ),
    );
  }

  SpriteAnimationComponent _actor(
    String key,
    Vector2 pos, {
    Color? silhouette,
    Color? dye,
  }) {
    final def = chars[key]!;
    return SpriteAnimationComponent(
      animation: null,
      position: pos,
      size: Vector2(def.displayW, def.displayH),
      anchor: Anchor.bottomCenter,
      priority: pos.y.round(),
    )
      ..paint.colorFilter = silhouette != null
          ? ColorFilter.mode(silhouette, BlendMode.srcIn)
          : (dye != null ? ColorFilter.mode(dye, BlendMode.modulate) : null);
  }

  PositionComponent _bubble(String line, Vector2 pos) {
    final text = TextComponent(
      text: line,
      textRenderer: TextPaint(
        style: const TextStyle(
          fontSize: 7,
          color: Color(0xFFEDE6D6),
          fontFamily: 'monospace',
        ),
      ),
    );
    final w = text.size.x + 12;
    final h = text.size.y + 8;
    final box = RectangleComponent(
      position: pos,
      size: Vector2(w, h),
      priority: 9999,
      paint: Paint()..color = const Color(0xE6141226),
    );
    text.position = Vector2(6, 4);
    box.add(text);
    return box;
  }

  @override
  Future<void> onLoad() async {
    images.prefix = 'assets/sprites/';
    final tileAssets = await TileAssets.load(images);
    final ground = await bakeGround(tileAssets);
    await world.add(
      SpriteComponent(
        sprite: Sprite(ground),
        size: Vector2(mapW, mapH),
        priority: -999999999,
      ),
    );
    // Only the props near the altar — the crop is tight, the rest is wasted.
    for (final p in buildProps(tileAssets)) {
      if (p.position.distanceToSquared(_ofrenda) < 460 * 460) {
        await world.add(p);
      }
    }
    await world.add(
      CandleFlickerComponent(Vector2(tileX(19), tileY(22))),
    );

    // The portrait that will go missing — a warm lit panel hung on the
    // altar's middle tier.
    _frame = RectangleComponent(
      position: _ofrenda + Vector2(-26, -40),
      size: Vector2(15, 19),
      priority: _ofrenda.y.round() + 1,
      paint: Paint()..color = const Color(0xFFEBD9A8),
    );
    await world.add(_frame);

    // The shadow — a silhouette that keeps every pixel of animation but
    // gives away nothing of who it is.
    final shadowDef = chars['sk_rogue']!;
    _shadow = SpriteAnimationComponent(
      animation: await _anim(shadowDef.walk),
      position: _ofrenda + Vector2(230, 26),
      size: Vector2(shadowDef.displayW, shadowDef.displayH),
      anchor: Anchor.bottomCenter,
      priority: _ofrenda.y.round() + 40,
    )..paint.colorFilter =
        const ColorFilter.mode(Color(0xFF07050E), BlendMode.srcIn);
    await world.add(_shadow);

    final defA = chars['tavern_a']!, defB = chars['tavern_b']!;
    _walkA = _actor('tavern_a', _ofrenda + Vector2(300, 60),
        dye: const Color(0xFF9C6FC9));
    _walkA.animation = await _anim(defA.walk);
    _walkB = _actor('tavern_b', _ofrenda + Vector2(340, 84),
        dye: const Color(0xFFC9863C));
    _walkB.animation = await _anim(defB.walk);
    await world.add(_walkA);
    await world.add(_walkB);

    camera.viewfinder.position = _ofrenda + Vector2(30, 10);
    camera.viewfinder.zoom = 2.6;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (_done) return;
    _t += dt;
    final t = _t;

    // 0→2.6s: the shadow crosses to the altar (walking, facing left).
    if (t < 2.6) {
      _shadow.position.x -= 86 * dt;
      _shadow.scale.x = -1;
      _frame.paint.color = Color.lerp(
        const Color(0xFFEBD9A8),
        const Color(0xFFFFF6D8),
        (sin(t * 6) + 1) / 2,
      )!;
    } else if (t < 4.0) {
      // 2.6→4.0s: at the altar — the light of one frame dies.
      _shadow.animation = null;
      final k = ((t - 2.6) / 1.4).clamp(0.0, 1.0);
      _frame.paint.color = Color.lerp(
        const Color(0xFFEBD9A8),
        const Color(0xFF2A2038),
        k,
      )!;
    } else if (t < 6.4) {
      // 4.0→6.4s: it leaves the way it came, portrait in hand.
      if (_shadow.animation == null) {
        final def = chars['sk_rogue']!;
        _anim(def.walk).then((a) => _shadow.animation = a);
      }
      _shadow.position.x += 96 * dt;
      _shadow.scale.x = 1;
      _frame.position.y += 14 * dt; // carried off — the empty glow follows
      _frame.paint.color = const Color(
        0xFFEBD9A8,
      ).withValues(alpha: (1 - (t - 4.0) / 2).clamp(0.0, 1.0));
    } else if (t < 8.2) {
      // 6.4→8.2s: villagers arrive, notice.
      if (_walkA.position.x > _ofrenda.x + 66) _walkA.position.x -= 70 * dt;
      if (_walkB.position.x > _ofrenda.x + 96) _walkB.position.x -= 70 * dt;
      _walkA.scale.x = -1;
      _walkB.scale.x = -1;
    } else if (_bubbles.isEmpty) {
      // 8.2s+: the discovery, in their voices.
      _bubbles.addAll([
        _bubble('¡Ay! — a portrait is missing', _ofrenda + Vector2(-58, -70)),
        _bubble(
          'La Golondrina… her frame is bare.',
          _ofrenda + Vector2(6, -54),
        ),
      ]);
      for (final b in _bubbles) {
        world.add(b);
      }
    }
    if (t > 10.6) {
      _done = true;
      onDone();
    }
  }
}
