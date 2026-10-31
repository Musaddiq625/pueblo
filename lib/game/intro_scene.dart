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
  late final CharDef _defA, _defB;
  final _villagerAnim = <int, String>{};

  /// The altar's portrait wall — a row of framed dead, one of them hers.
  /// Each entry: outer wood frame → lit panel → face disc.
  final _portraits = <_Portrait>[];
  _Portrait? _golondrina;
  RectangleComponent? _emptySlot;
  bool _portraitTaken = false;
  bool? _grabbing;
  late final CircleComponent _glow;
  late final RectangleComponent _groundShadow;
  final _bubbles = <PositionComponent>[];
  bool _reacted = false;

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
          ? ColorFilter.mode(silhouette, BlendMode.modulate)
          : (dye != null ? ColorFilter.mode(dye, BlendMode.modulate) : null);
  }

  PositionComponent _bubble(String line, Vector2 pos) {
    final text = TextComponent(
      text: line,
      textRenderer: TextPaint(
        style: const TextStyle(
          fontSize: 8,
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

    // The portrait wall — five framed dead hung in a row on the altar's
    // face. La Golondrina's is the middle one: bigger, golden, the one
    // that will go missing. The rest keep burning — witnesses that
    // stayed behind.
    for (var i = 0; i < 5; i++) {
      final isHer = i == 2;
      final p = _Portrait(
        _ofrenda +
            Vector2(-52.0 + i * 21, isHer ? -22.0 : -18.0),
        isHer ? Vector2(17, 21) : Vector2(13, 17),
        panel: isHer ? const Color(0xFFFFD96A) : const Color(0xFFEBD9A8),
        baseY: _ofrenda.y.round() + 5,
      );
      _portraits.add(p);
      await world.addAll(p.parts);
      if (isHer) _golondrina = p;
    }
    // The dark socket the stolen frame leaves behind — visible the
    // moment it's gone, because an empty rectangle says "theft" louder
    // than a missing sprite ever could.
    _emptySlot = RectangleComponent(
      position: _golondrina!.frame.position.clone(),
      size: _golondrina!.frame.size.clone(),
      priority: _ofrenda.y.round() + 4,
      paint: Paint()..color = const Color(0xFF140F1E),
    );

    // The shadow — a silhouette that keeps every pixel of animation but
    // gives away nothing of who it is.
    final shadowDef = chars['sk_rogue']!;
    // The shadow rides a FIXED high priority — the cinematic choreographs
    // its own depth, and a foreground garden bed must never swallow him
    // mid-theft (the "walking under the tiles" bug this used to cause).
    // A warm back-glow rides with him: a near-black sprite on a dark
    // altar reads as NOTHING — the glow is what makes the figure a
    // silhouette instead of a hole in the frame.
    _shadow = SpriteAnimationComponent(
      animation: await _anim(shadowDef.walk),
      position: _ofrenda + Vector2(230, 56),
      size: Vector2(shadowDef.displayW, shadowDef.displayH),
      anchor: Anchor.bottomCenter,
      priority: 5000,
    )..paint.colorFilter =
        const ColorFilter.mode(Color(0xFF241A44), BlendMode.modulate);
    await world.add(_shadow);
    _glow = CircleComponent(
      radius: 34,
      position: _ofrenda + Vector2(230, 30),
      anchor: Anchor.center,
      priority: 4999,
      paint: Paint()..color = const Color(0x40FFB35A),
    );
    _groundShadow = RectangleComponent(
      size: Vector2(40, 12),
      position: _ofrenda + Vector2(230, 50),
      anchor: Anchor.center,
      priority: 4998,
      paint: Paint()..color = const Color(0x66000000),
    );
    await world.add(_glow);
    await world.add(_groundShadow);

    // The pair who find it — the flower woman and the fountain crone.
    // Off the right crop edge; they walk in during the thief's exit and
    // literally pass him on screen — the night nobody looked. IDLE until
    // they move — walking-in-place was the "standing but walking" bug.
    _defA = chars['peasant']!;
    _defB = chars['wizzard']!;
    _walkA = _actor('peasant', _ofrenda + Vector2(280, 60));
    _walkA.animation = await _anim(_defA.idle);
    _walkB = _actor('wizzard', _ofrenda + Vector2(310, 84));
    _walkB.animation = await _anim(_defB.idle);
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
    final g = _golondrina!;

    // Depth — the villagers sort by feet among the props; the shadow's
    // priority is fixed above them all (a silhouette in a scripted beat).
    _walkA.priority = _walkA.position.y.round();
    _walkB.priority = _walkB.position.y.round();
    // glow + ground shadow ride the thief — he owns the frame wherever
    // he goes, the way a lantern owns the dark
    _glow.position = _shadow.position - Vector2(0, 26);
    _groundShadow.position = _shadow.position - Vector2(0, 6);

    // 0→2.6s: the shadow crosses to the altar (walking, facing left).
    if (t < 2.6) {
      _shadow.position.x -= 86 * dt;
      _shadow.scale.x = -1;
      // her portrait flickers — the only light that knows what's coming
      g.panel.paint.color = Color.lerp(
        const Color(0xFFFFD96A),
        const Color(0xFFFFF6D8),
        (sin(t * 6) + 1) / 2,
      )!;
    } else if (t < 4.0) {
      // 2.6→4.0s: at the altar — hands on the golden frame. It dims,
      // then comes off the wall.
      if (_grabbing == null) {
        _grabbing = true;
        _anim(chars['sk_rogue']!.idle).then((a) => _shadow.animation = a);
      }
      final k = ((t - 2.6) / 1.4).clamp(0.0, 1.0);
      g.panel.paint.color = Color.lerp(
        const Color(0xFFFFD96A),
        const Color(0xFF8A7A55),
        k,
      )!;
      if (t > 3.4 && !_portraitTaken) {
        _portraitTaken = true;
        world.add(_emptySlot!);
        _golondrina!.carriedBy = _shadow;
      }
    }
    // 4.0→6.4s: the thief leaves the way he came, portrait in hand.
    if (t >= 4.0 && t < 6.4) {
      if (_grabbing == true) {
        _grabbing = false;
        _anim(chars['sk_rogue']!.walk).then((a) => _shadow.animation = a);
      }
      _shadow.position.x += 96 * dt;
      _shadow.scale.x = 1;
    }
    // 4.8s→arrival: the villagers walk in from the right and pass him on
    // the path — both looking the wrong way as the frame goes by. Idle
    // while standing, walk while moving, idle when they arrive. The gate
    // only opens the stroll; it never CLOSES on a straggler — a villager
    // still mid-path after 8.6s keeps walking until she lands, else she
    // would freeze mid-stride forever (the "standing but walking" bug).
    if (t >= 4.8 && t < 12.0) {
      void stroll(SpriteAnimationComponent v, CharDef def, double tx,
          int flagSlot) {
        final moving = v.position.x > tx;
        if (moving) {
          if (_villagerAnim[flagSlot] != 'walk') {
            _villagerAnim[flagSlot] = 'walk';
            _anim(def.walk).then((a) => v.animation = a);
          }
          v.position.x -= 70 * dt;
          v.scale.x = -1;
        } else if (_villagerAnim[flagSlot] != 'idle') {
          _villagerAnim[flagSlot] = 'idle';
          _anim(def.idle).then((a) => v.animation = a);
        }
      }

      stroll(_walkA, _defA, _ofrenda.x + 66, 0);
      stroll(_walkB, _defB, _ofrenda.x + 96, 1);
    }
    // The discovery — call, then response. Each bubble rides just above
    // its speaker's head (she lands at +66, the crone at +96), staggered
    // so it reads as one spirit answering the other.
    if (t >= 8.4 && _bubbles.isEmpty) {
      final b = _bubble(
        "Oh! La Golondrina's picture is gone!",
        _ofrenda + Vector2(-48, -8),
      );
      _bubbles.add(b);
      world.add(b);
    }
    if (t >= 9.8 && !_reacted) {
      _reacted = true;
      final b = _bubble(
        'Who would take her face?',
        _ofrenda + Vector2(0, 14),
      );
      _bubbles.add(b);
      world.add(b);
    }
    // A stolen portrait rides in the thief's hands — follow his body,
    // not the wall it used to hang on.
    if (g.carriedBy != null) {
      final s = g.carriedBy!;
      g.frame.position =
          Vector2(s.position.x - g.frame.size.x / 2, s.position.y - 34);
      g.frame.priority = 5001; // rides just over the thief's head
    }
    if (t > 12.2) {
      _done = true;
      onDone();
    }
  }
}

/// One framed portrait — outer wood, lit panel, a face. When carried,
/// the frame's inner contents ride along as a single rect (the theft
/// reads as a glowing rectangle in the thief's hands at this crop).
class _Portrait {
  final RectangleComponent frame;
  final RectangleComponent panel;
  SpriteAnimationComponent? carriedBy;

  _Portrait(Vector2 pos, Vector2 size, {required Color panel, int baseY = 0})
      : frame = RectangleComponent(
          position: pos.clone(),
          size: size.clone(),
          priority: baseY,
          paint: Paint()..color = const Color(0xFF4A2E18),
        ),
        panel = RectangleComponent(
          position: Vector2.all(2),
          size: size - Vector2.all(4),
          paint: Paint()..color = panel,
        ) {
    frame.add(this.panel);
    // the remembered — a head-and-shoulders portrait inside every lit
    // panel, so each frame reads as somebody's face, not a blank card.
    final iw = size.x - 4, ih = size.y - 4;
    const skin = Color(0xFFB98A62), hair = Color(0xFF3A2416);
    frame.add(
      RectangleComponent(
        // shoulders first — the head overlaps them like any portrait
        position: Vector2(2 + iw * 0.18, 2 + ih * 0.62),
        size: Vector2(iw * 0.64, ih * 0.34),
        paint: Paint()..color = const Color(0xFF6A4A58),
      ),
    );
    frame.add(
      RectangleComponent(
        // head
        position: Vector2(2 + iw * 0.28, 2 + ih * 0.22),
        size: Vector2(iw * 0.44, ih * 0.44),
        paint: Paint()..color = skin,
      ),
    );
    frame.add(
      RectangleComponent(
        // hair cap across the top of the head
        position: Vector2(2 + iw * 0.26, 2 + ih * 0.20),
        size: Vector2(iw * 0.48, ih * 0.16),
        paint: Paint()..color = hair,
      ),
    );
  }

  List<PositionComponent> get parts => [frame];
}
