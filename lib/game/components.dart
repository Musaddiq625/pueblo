/// Flame components — spirit, player, POI, bubbles, petals, ground.
/// Render layer only: consumes SimEvents, never owns sim state.
library;

import 'dart:async';
import 'dart:math';
import 'dart:ui' show Image;

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart' hide Image;

import '../sim/models.dart';

// ---------------------------------------------------------------------------

final _nightPaint = Paint()..color = const Color(0xFF14101F);

/// Solid tile regions inside floors.png (verified by crop-inspection).
const _brickRect = Rect.fromLTWH(245, 50, 32, 32); // gray cobblestone
const _tileSize = 44.0;

/// Tiled ground — the floors.png cobble tile tinted to night shades.
/// Base = darkest tint; waypoint edges and plaza get lighter tints so the
/// walkable network reads as streets under the sprites' feet.
class GroundComponent extends PositionComponent {
  GroundComponent({required Vector2 size, required this.floors})
      : super(size: size, position: Vector2.zero(), priority: -10000);

  final Image floors;

  static const _tintGround = Color(0xFF35294E);
  static const _tintPath = Color(0xFF584A78);
  static const _tintPlaza = Color(0xFF483A66);

  /// Waypoint graph edges to paint as streets — mirrors world_def.
  static const _nodePos = <List<double>>[
    [700, 90], [700, 220], [700, 330], [520, 330], [420, 330],
    [880, 330], [1030, 350], [820, 450], [1120, 450], [1120, 560],
    [1230, 660], [700, 560], [700, 700], [420, 560],
  ];
  static const _edges = <List<int>>[
    [0, 1], [1, 2], [2, 3], [3, 4], [2, 5], [5, 6], [2, 7], [5, 7],
    [7, 8], [6, 8], [8, 9], [9, 10], [2, 11], [7, 11], [11, 12],
    [11, 13], [3, 13],
  ];

  void _tileRect(Canvas c, Rect r, Color tint) {
    final paint = Paint()
      ..colorFilter = ColorFilter.mode(tint, BlendMode.modulate);
    for (var y = r.top; y < r.bottom; y += _tileSize) {
      for (var x = r.left; x < r.right; x += _tileSize) {
        c.drawImageRect(floors, _brickRect, Rect.fromLTWH(x, y, _tileSize, _tileSize), paint);
      }
    }
  }

  void _tileCircle(Canvas c, Offset center, double radius, Color tint) {
    final paint = Paint()
      ..colorFilter = ColorFilter.mode(tint, BlendMode.modulate);
    final step = _tileSize;
    for (var y = center.dy - radius; y < center.dy + radius; y += step) {
      for (var x = center.dx - radius; x < center.dx + radius; x += step) {
        final cx = x + step / 2, cy = y + step / 2;
        if ((cx - center.dx) * (cx - center.dx) +
                (cy - center.dy) * (cy - center.dy) <=
            radius * radius) {
          c.drawImageRect(floors, _brickRect,
              Rect.fromLTWH(x, y, step, step), paint);
        }
      }
    }
  }

  /// Paint a street: tiles along the segment between two waypoints,
  /// half-tile overlap both directions so corners don't show seams.
  void _tilePath(Canvas c, Offset a, Offset b, Color tint) {
    final paint = Paint()
      ..colorFilter = ColorFilter.mode(tint, BlendMode.modulate);
    final dir = b - a;
    final len = dir.distance;
    final n = dir / len;
    final w = 44.0; // street width in world units
    for (var d = 0.0; d < len; d += _tileSize / 2) {
      final p = a + n * d;
      // two tiles across the path width
      for (final off in const [-0.5, 0.5]) {
        final q = p + Offset(-n.dy, n.dx) * (off * w);
        c.drawImageRect(
            floors,
            _brickRect,
            Rect.fromCenter(
                center: q, width: _tileSize, height: _tileSize),
            paint);
      }
    }
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _nightPaint);
    // base: whole map tiled in the darkest night-cobble tint
    _tileRect(canvas, size.toRect(), _tintGround);
    // streets along waypoint edges
    for (final e in _edges) {
      _tilePath(canvas, Offset(_nodePos[e[0]][0], _nodePos[e[0]][1]),
          Offset(_nodePos[e[1]][0], _nodePos[e[1]][1]), _tintPath);
    }
    // plaza — big lighter cobble disc
    _tileCircle(canvas, const Offset(700, 330), 170, _tintPlaza);
    // ofrenda landing
    _tileCircle(canvas, const Offset(700, 700), 90, _tintPlaza);
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
        Offset(size.x / 2, size.y / 2), size.x / 2,
        Paint()
          ..color = const Color(0xFF7BE0C3).withValues(alpha: flicker)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
    canvas.drawCircle(
        Offset(size.x / 2, size.y / 2), size.x / 4,
        Paint()..color = const Color(0xFFE8FFF6).withValues(alpha: flicker));
  }

  /// Canned tutorial line in a bubble over Chispa.
  void say(String line) {
    for (final b in children.whereType<BubbleComponent>()) {
      b.removeFromParent();
    }
    add(BubbleComponent(line, size: Vector2(210, 44))
      ..position = Vector2(-size.x - 190, -34));
  }
}
