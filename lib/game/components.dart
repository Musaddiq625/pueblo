/// Flame components — spirit, player, POI, bubbles, petals, ground.
/// Render layer only: consumes SimEvents, never owns sim state.
library;

import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart' hide Image;

import '../sim/models.dart';

// ---------------------------------------------------------------------------

enum SpiritAnim { idle, walk, death }

class SpiritComponent extends SpriteAnimationGroupComponent<SpiritAnim>
    with TapCallbacks {
  final Agent agent;
  final String charKey;
  final String displayName;
  final Color? auraColor;
  final void Function(Agent) onTapped;

  // Movement
  final List<Vector2> _path = [];
  bool walking = false;

  // Visual state
  double _opacity = 1.0;
  bool _engaged = false;
  bool _faded = false;

  SpiritComponent({
    required this.agent,
    required this.charKey,
    required this.onTapped,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
    required Vector2 displaySize,
    SpriteAnimation? death,
    this.displayName = '',
    this.auraColor,
  }) : super(
         animations: {
           SpiritAnim.idle: idle,
           SpiritAnim.walk: walk,
           SpiritAnim.death: ?death,
         },
         current: SpiritAnim.idle,
         size: displaySize,
         anchor: Anchor.bottomCenter,
         position: Vector2(agent.x, agent.y),
         priority: agent.y.round(),
       );

  @override
  bool onTapUp(TapUpEvent event) {
    onTapped(agent);
    return true; // consume — prevents ground-move under this spirit
  }

  /// Queue a path (world-space points). Component lerps along it.
  void movePath(List<List<double>> pts) {
    _path
      ..clear()
      ..addAll(pts.map((p) => Vector2(p[0], p[1])));
    walking = _path.isNotEmpty;
    if (!walking) current = SpiritAnim.idle;
  }

  void faceToward(double x) {
    // flipX toward target — facing is horizontal in stage view.
    final faceLeft = x < position.x;
    if (faceLeft != scale.x.isNegative) flipHorizontallyAroundCenter();
  }

  void setEngaged(bool v) {
    _engaged = v;
    if (v) {
      walking = false;
      _path.clear();
      current = SpiritAnim.idle;
    }
  }

  void setFaded(bool faded) {
    _faded = faded;
    _opacity = faded ? 0.35 : 1.0;
    // play the death anim once when the spirit is forgotten — the sheets
    // exist for all sk_* chars; loop:false parks on the last frame
    if (faded && animations?.containsKey(SpiritAnim.death) == true) {
      current = SpiritAnim.death;
    } else if (!faded && current == SpiritAnim.death) {
      current = SpiritAnim.idle;
      _opacity = 1.0;
    }
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (walking && _path.isNotEmpty && !_faded) {
      current = SpiritAnim.walk;
      final target = _path.first;
      final delta = target - position;
      final dist = delta.length;
      if (dist < 4) {
        _path.removeAt(0);
        if (_path.isEmpty) {
          walking = false;
          current = SpiritAnim.idle;
        }
      } else {
        final step = delta.normalized() * kSpiritSpeed * dt;
        position += step;
        faceToward(target.x);
      }
    }
    // depth sort by foot y; engaged pins nothing visually
    priority = position.y.round();
    // engaged → gentle glow tint pulse
    opacity = _engaged ? min(1.0, _opacity + 0.15) : _opacity;
  }

  @override
  void render(Canvas canvas) {
    // aura ring under the feet — the persona color distinguishes spirits
    // without painting over the sprite art itself
    final aura = auraColor;
    if (aura != null) {
      final cx = size.x / 2, cy = size.y - 5;
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: 46, height: 13),
        Paint()
          ..color = aura.withValues(alpha: 0.32 * _opacity)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx, cy), width: 40, height: 10),
        Paint()
          ..color = aura.withValues(alpha: 0.85 * _opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4,
      );
    }
    super.render(canvas);
    // name tag under the feet — persona color, counter-flip so text stays
    // readable when the sprite flips to face walk direction
    if (displayName.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: displayName,
          style: TextStyle(
            fontSize: 9,
            color: aura ?? const Color(0xDDEFE4CE),
            fontFamily: 'monospace',
            shadows: const [Shadow(color: Color(0xFF000000), blurRadius: 3)],
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      if (scale.x.isNegative) {
        canvas.save();
        canvas.translate(size.x, 0);
        canvas.scale(-1, 1);
        tp.paint(canvas, Offset((size.x - tp.width) / 2, size.y + 4));
        canvas.restore();
      } else {
        tp.paint(canvas, Offset((size.x - tp.width) / 2, size.y + 4));
      }
    }
  }
}

// ---------------------------------------------------------------------------

class PlayerComponent extends SpriteAnimationGroupComponent<SpiritAnim> {
  final List<Vector2> _path = [];
  final double _speed = 95;
  bool walking = false;

  PlayerComponent({
    required Vector2 pos,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
    required Vector2 displaySize,
  }) : super(
         animations: {SpiritAnim.idle: idle, SpiritAnim.walk: walk},
         current: SpiritAnim.idle,
         size: displaySize,
         anchor: Anchor.bottomCenter,
         position: pos,
         priority: pos.y.round(),
       );

  void walkTo(Vector2 target) {
    _path
      ..clear()
      ..add(target);
    walking = true;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (walking && _path.isNotEmpty) {
      current = SpiritAnim.walk;
      final target = _path.first;
      final delta = target - position;
      if (delta.length < 5) {
        _path.removeAt(0);
        if (_path.isEmpty) {
          walking = false;
          current = SpiritAnim.idle;
        }
      } else {
        position += delta.normalized() * _speed * dt;
        final faceLeft = target.x < position.x;
        if (faceLeft != scale.x.isNegative) flipHorizontallyAroundCenter();
      }
    }
    priority = position.y.round();
  }
}

// ---------------------------------------------------------------------------

class PoiComponent extends PositionComponent with TapCallbacks {
  final Poi poi;
  final void Function(Poi) onInspect;
  PositionComponent? visual;
  bool glowing = false;

  PoiComponent({
    required this.poi,
    required this.onInspect,
    this.visual,
    Vector2? size,
    Vector2? pos,
  }) : super(
         position: pos ?? Vector2(poi.x, poi.y),
         size: size ?? Vector2.all(90),
         anchor: Anchor.bottomCenter,
         priority: poi.y.round(),
       );

  @override
  Future<void> onLoad() async {
    if (visual != null) add(visual!);
  }

  @override
  bool onTapUp(TapUpEvent event) {
    onInspect(poi);
    return true;
  }

  @override
  void render(Canvas canvas) {
    if (glowing) {
      canvas.drawCircle(
        Offset(size.x / 2, size.y / 2),
        size.x * 0.62,
        Paint()
          ..color = const Color(0x66FFC233)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
      );
    }
  }
}

// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------

/// Speech/emote bubble floating over a component's head. [speaker] shows a
/// small name chip over the line — who is talking should never be a guess.
class BubbleComponent extends PositionComponent {
  final String text;
  final String speaker;
  final bool isEmote;
  double _ttl;

  BubbleComponent(
    this.text, {
    this.speaker = '',
    this.isEmote = false,
    Vector2? size,
  }) : _ttl = isEmote ? 1.8 : 3.6,
       super(
         size: size ?? Vector2(220, 44),
         anchor: Anchor.bottomCenter,
         priority: 9999,
       );

  @override
  void update(double dt) {
    _ttl -= dt;
    if (_ttl <= 0) removeFromParent();
    // float up gently
    position.y -= dt * 6;
  }

  @override
  void render(Canvas canvas) {
    // parent spirit flips horizontally when walking left — counter-flip
    // so text never renders mirrored
    final p = parent;
    if (p is PositionComponent && p.scale.x.isNegative) {
      canvas.save();
      canvas.translate(size.x, 0);
      canvas.scale(-1, 1);
      _draw(canvas);
      canvas.restore();
    } else {
      _draw(canvas);
    }
  }

  void _draw(Canvas canvas) {
    final style = TextStyle(
      color: const Color(0xFFFFF4DC),
      fontSize: isEmote ? 22 : 12.5,
      // default font for emotes — monospace lacks emoji glyphs (blank box)
      fontFamily: isEmote ? null : 'monospace',
      height: 1.25,
    );
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      maxLines: 3,
      ellipsis: '…',
    )..layout(maxWidth: size.x - 16);
    if (isEmote) {
      tp.paint(canvas, Offset((size.x - tp.width) / 2, 0));
      return;
    }
    TextPainter? name;
    if (speaker.isNotEmpty) {
      name = TextPainter(
        text: TextSpan(
          text: speaker,
          style: const TextStyle(
            color: Color(0xFFFFC233),
            fontSize: 9,
            fontFamily: 'monospace',
            height: 1.2,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: size.x - 16);
    }
    final nameH = name == null ? 0.0 : name.height + 2;
    final w = (name == null ? tp.width : max(tp.width, name.width)) + 16;
    final h = nameH + tp.height + 10;
    final rect = RRect.fromRectAndRadius(
      Rect.fromLTWH((size.x - w) / 2, 0, w, h),
      const Radius.circular(8),
    );
    canvas.drawRRect(rect, Paint()..color = const Color(0xE62B2145));
    canvas.drawRRect(
      rect,
      Paint()
        ..color = const Color(0xFFFFC233)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
    name?.paint(canvas, Offset((size.x - name.width) / 2, 4));
    tp.paint(canvas, Offset((size.x - tp.width) / 2, 5 + nameH));
  }
}

// ---------------------------------------------------------------------------

class PetalComponent extends PositionComponent {
  PetalComponent({required Vector2 pos})
    : super(position: pos, size: Vector2.all(14), priority: -50);

  @override
  void render(Canvas canvas) {
    final c = Offset(size.x / 2, size.y / 2);
    canvas.drawCircle(c, 5, Paint()..color = const Color(0xFFFF8C1A));
    canvas.drawCircle(
      c + const Offset(3, -2),
      2.5,
      Paint()..color = const Color(0xFFFFC233),
    );
  }
}

// ---------------------------------------------------------------------------

/// Ambient drifting petals / papel picado flags / candle flickers — pure
/// ambience, no sim dependence.
class PetalDriftComponent extends PositionComponent {
  final Random _rng = Random();
  final List<Vector2> _mot = [];
  final Vector2 bounds;

  PetalDriftComponent(this.bounds, {int count = 26})
    : super(size: bounds, priority: 50000) {
    for (var i = 0; i < count; i++) {
      _mot.add(
        Vector2(_rng.nextDouble() * bounds.x, _rng.nextDouble() * bounds.y),
      );
    }
  }

  @override
  void update(double dt) {
    for (final m in _mot) {
      m.x += 14 * dt + sin(m.y / 40) * 6 * dt;
      m.y += 4 * dt;
      if (m.x > bounds.x + 10) m.x = -10;
      if (m.y > bounds.y + 10) m.y = -10;
    }
  }

  @override
  void render(Canvas canvas) {
    for (final m in _mot) {
      canvas.drawCircle(
        m.toOffset(),
        1.6,
        Paint()..color = const Color(0x55FF8C1A),
      );
    }
  }
}

/// Papel picado — fluttering paper flags strung between two points.
class PapelPicadoComponent extends PositionComponent {
  double _t = 0;
  final int flags;

  PapelPicadoComponent({
    required Vector2 pos,
    required Vector2 size,
    this.flags = 9,
  }) : super(position: pos, size: size, priority: 60000);

  static const _colors = [
    Color(0xFFE83D5C),
    Color(0xFF2EA88A),
    Color(0xFFEF8C1A),
    Color(0xFF7B4FD0),
    Color(0xFFEFD23F),
  ];

  @override
  void update(double dt) => _t += dt;

  @override
  void render(Canvas canvas) {
    final sag = size.y * 0.5;
    // string
    canvas.drawLine(
      Offset.zero,
      Offset(size.x, 0),
      Paint()
        ..color = const Color(0xFF584A6E)
        ..strokeWidth = 1,
    );
    for (var i = 0; i < flags; i++) {
      final fx = (i + 0.5) * (size.x / flags);
      final flutter = sin(_t * 3 + i * 0.9) * 3;
      final fw = size.x / flags * 0.6;
      final fh = sag + flutter;
      final paint = Paint()
        ..color = _colors[i % _colors.length].withValues(alpha: 0.92);
      final r = Rect.fromLTWH(fx - fw / 2, 0, fw, fh.clamp(8, 30));
      canvas.drawRect(r, paint);
      // cut-outs
      canvas.drawRect(
        Rect.fromLTWH(fx - 2, fh * 0.5, 4, 4),
        Paint()..color = const Color(0xFF1A1430),
      );
    }
  }
}

/// Chispa — the alebrije guide. A tiny ember that floats near the player.
/// Zero inference: it only shows canned tutorial lines fed by the game.
class ChispaComponent extends PositionComponent {
  ChispaComponent({required this.follow})
    : super(size: Vector2(14, 14), anchor: Anchor.center);

  final PositionComponent follow;
  double _t = 0;

  @override
  void update(double dt) {
    super.update(dt);
    _t += dt;
    // hover slightly above-right of the player with a gentle bob
    position = follow.position + Vector2(26, -30 + 4 * sin(_t * 3));
  }

  @override
  void render(Canvas canvas) {
    final flicker = 0.75 + 0.25 * sin(_t * 9);
    canvas.drawCircle(
      Offset(size.x / 2, size.y / 2),
      size.x / 2,
      Paint()
        ..color = const Color(0xFF7BE0C3).withValues(alpha: flicker)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      Offset(size.x / 2, size.y / 2),
      size.x / 4,
      Paint()..color = const Color(0xFFE8FFF6).withValues(alpha: flicker),
    );
  }

  /// Canned tutorial line in a bubble over Chispa.
  void say(String line) {
    for (final b in children.whereType<BubbleComponent>()) {
      b.removeFromParent();
    }
    add(
      BubbleComponent(line, size: Vector2(210, 44))
        ..position = Vector2(-size.x - 190, -34),
    );
  }
}
