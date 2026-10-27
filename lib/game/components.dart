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

final _nightPaint = Paint()..color = const Color(0xFF1A1430);
final _plazaPaint = Paint()..color = const Color(0xFF241B3E);
final _pathPaint = Paint()..color = const Color(0xFF3A2C50);

/// Painted ground — night bands + plaza circle + rough path blobs.
class GroundComponent extends PositionComponent {
  GroundComponent({required Vector2 size})
      : super(size: size, position: Vector2.zero(), priority: -10000);

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _nightPaint);
    // plaza
    canvas.drawCircle(Offset(700, 330), 150, _plazaPaint);
    // crude path blobs along waypoint links
    for (final p in const [
      Offset(700, 160), Offset(620, 330), Offset(800, 330),
      Offset(960, 360), Offset(820, 420), Offset(1050, 480),
      Offset(1150, 560), Offset(700, 480), Offset(700, 640),
      Offset(500, 470),
    ]) {
      canvas.drawCircle(p, 60, _pathPaint);
    }
  }
}

// ---------------------------------------------------------------------------

enum SpiritAnim { idle, walk }

class SpiritComponent extends SpriteAnimationGroupComponent<SpiritAnim>
    with TapCallbacks {
  final Agent agent;
  final String charKey;
  final void Function(Agent) onTapped;

  // Movement
  final List<Vector2> _path = [];
  final double _speed = 55;
  bool walking = false;

  // Visual state
  double _opacity = 1.0;
  bool _engaged = false;

  SpiritComponent({
    required this.agent,
    required this.charKey,
    required this.onTapped,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
  }) : super(
          animations: {SpiritAnim.idle: idle, SpiritAnim.walk: walk},
          current: SpiritAnim.idle,
          size: Vector2.all(56),
          anchor: Anchor.bottomCenter,
          position: Vector2(agent.x, agent.y),
          priority: -agent.y.round(),
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
    if (_path.isNotEmpty) walking = true;
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

  void setFaded(bool faded) => _opacity = faded ? 0.35 : 1.0;

  @override
  void update(double dt) {
    super.update(dt);
    if (walking && _path.isNotEmpty) {
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
        final step = delta.normalized() * _speed * dt;
        position += step;
        faceToward(target.x);
      }
    }
    // depth sort by foot y; engaged pins nothing visually
    priority = -position.y.round();
    // engaged → gentle glow tint pulse
    opacity = _engaged ? min(1.0, _opacity + 0.15) : _opacity;
  }
}

// ---------------------------------------------------------------------------

class PlayerComponent extends SpriteAnimationGroupComponent<SpiritAnim> {
  final List<Vector2> _path = [];
  final double _speed = 85;
  bool walking = false;

  PlayerComponent({
    required Vector2 pos,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
  }) : super(
          animations: {SpiritAnim.idle: idle, SpiritAnim.walk: walk},
          current: SpiritAnim.idle,
          size: Vector2.all(52),
          anchor: Anchor.bottomCenter,
          position: pos,
          priority: -pos.y.round(),
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
    priority = -position.y.round();
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
          priority: -poi.y.round(),
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
          Offset(size.x / 2, size.y / 2), size.x * 0.62,
          Paint()
            ..color = const Color(0x66FFC233)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18));
    }
  }
}

// ---------------------------------------------------------------------------

/// Speech/emote bubble floating over a component's head.
class BubbleComponent extends PositionComponent {
  final String text;
  final bool isEmote;
  double _ttl;

  BubbleComponent(this.text, {this.isEmote = false, Vector2? size})
      : _ttl = isEmote ? 1.8 : 3.6,
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
    final style = TextStyle(
      color: const Color(0xFFFFF4DC),
      fontSize: isEmote ? 26 : 12.5,
      fontFamily: 'monospace',
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
    final w = tp.width + 16, h = tp.height + 10;
    final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH((size.x - w) / 2, 0, w, h), const Radius.circular(8));
    canvas.drawRRect(
        rect, Paint()..color = const Color(0xE62B2145));
    canvas.drawRRect(
        rect,
        Paint()
          ..color = const Color(0xFFFFC233)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2);
    tp.paint(canvas, Offset((size.x - tp.width) / 2, 5));
  }
}

// ---------------------------------------------------------------------------

class PetalComponent extends PositionComponent {
  PetalComponent({required Vector2 pos})
      : super(position: pos, size: Vector2.all(14), priority: -pos.y.round());

  @override
  void render(Canvas canvas) {
    final c = Offset(size.x / 2, size.y / 2);
    canvas.drawCircle(c, 5, Paint()..color = const Color(0xFFFF8C1A));
    canvas.drawCircle(c + const Offset(3, -2), 2.5,
        Paint()..color = const Color(0xFFFFC233));
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
      : super(size: bounds, priority: -1) {
    for (var i = 0; i < count; i++) {
      _mot.add(Vector2(_rng.nextDouble() * bounds.x, _rng.nextDouble() * bounds.y));
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
      canvas.drawCircle(m.toOffset(), 1.6,
          Paint()..color = const Color(0x55FF8C1A));
    }
  }
}

/// Papel picado — fluttering paper flags strung between two points.
class PapelPicadoComponent extends PositionComponent {
  double _t = 0;
  final int flags;

  PapelPicadoComponent({required Vector2 pos, required Vector2 size, this.flags = 9})
      : super(position: pos, size: size, priority: -pos.y.round() + 1);

  static const _colors = [
    Color(0xFFE83D5C), Color(0xFF2EA88A), Color(0xFFEF8C1A),
    Color(0xFF7B4FD0), Color(0xFFEFD23F),
  ];

  @override
  void update(double dt) => _t += dt;

  @override
  void render(Canvas canvas) {
    final sag = size.y * 0.5;
    // string
    canvas.drawLine(Offset.zero, Offset(size.x, 0),
        Paint()..color = const Color(0xFF584A6E)..strokeWidth = 1);
    for (var i = 0; i < flags; i++) {
      final fx = (i + 0.5) * (size.x / flags);
      final flutter = sin(_t * 3 + i * 0.9) * 3;
      final fw = size.x / flags * 0.6;
      final fh = sag + flutter;
      final paint = Paint()..color = _colors[i % _colors.length].withValues(alpha: 0.92);
      final r = Rect.fromLTWH(fx - fw / 2, 0, fw, fh.clamp(8, 30));
      canvas.drawRect(r, paint);
      // cut-outs
      canvas.drawRect(Rect.fromLTWH(fx - 2, fh * 0.5, 4, 4),
          Paint()..color = const Color(0xFF1A1430));
    }
  }
}
