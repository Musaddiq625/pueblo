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

/// Tiled ground — a readable village: dark earth base, cobble streets one
/// tile wide along the waypoint graph, a plaza disc, and painted decor
/// (gravestones, stall counters, spirit trees, ofrenda candles).
class GroundComponent extends PositionComponent {
  GroundComponent({required Vector2 size, required this.floors,
      this.treeImg})
      : super(size: size, position: Vector2.zero(), priority: -10000);

  final Image floors;
  final Image? treeImg;

  static const _streetEdge = Color(0xFF443A5E); // curb/outer band
  static const _streetFill = Color(0xFF554870); // walkable strip
  static const _tintTree = Color(0xFF9A88D8);

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

  /// Flat earth base — solid dark fill + a faint deterministic speckle so
  /// the ground reads as night soil, not a wall or a checkerboard.
  void _baseFill(Canvas c, Rect r) {
    c.drawRect(r, Paint()..color = const Color(0xFF241B34));
    final dot = Paint()..color = const Color(0xFF2E2540);
    for (var y = r.top + 8; y < r.bottom; y += 18) {
      for (var x = r.left + 8; x < r.right; x += 18) {
        if (((x * 31 + y * 17).toInt() & 7) == 0) {
          c.drawRect(Rect.fromLTWH(x, y, 2, 2), dot);
        }
      }
    }
  }

  /// Street — dark curb band + lighter fill + subtle cross-ticks, drawn as
  /// strokes so the walkable strip reads cleanly on the dark earth.
  void _street(Canvas c, Offset a, Offset b) {
    c.drawLine(
        a,
        b,
        Paint()
          ..color = _streetEdge
          ..strokeWidth = 46
          ..strokeCap = StrokeCap.round);
    c.drawLine(
        a,
        b,
        Paint()
          ..color = _streetFill
          ..strokeWidth = 38
          ..strokeCap = StrokeCap.round);
    // cobble suggestion: faint ticks across the strip every ~22 units
    final dir = b - a;
    final len = dir.distance;
    final n = dir / len;
    final tick = Paint()
      ..color = const Color(0xFF655884)
      ..strokeWidth = 2;
    for (var d = 20.0; d < len; d += 22) {
      final p = a + n * d;
      c.drawLine(p - Offset(-n.dy, n.dx) * 16, p + Offset(-n.dy, n.dx) * 16,
          tick);
    }
  }

  void _plaza(Canvas c, Offset center, double r) {
    c.drawCircle(center, r, Paint()..color = _streetEdge);
    c.drawCircle(center, r - 8, Paint()..color = _streetFill);
    final tick = Paint()
      ..color = const Color(0xFF655884)
      ..strokeWidth = 2;
    for (var i = 0; i < 14; i++) {
      final ang = i * pi / 7;
      final p1 = center + Offset(cos(ang), sin(ang)) * (r - 20);
      final p2 = center + Offset(cos(ang), sin(ang)) * (r - 34);
      c.drawLine(p1, p2, tick);
    }
  }

  void _gravestone(Canvas c, double x, double y) {
    final slab = RRect.fromRectAndRadius(
        Rect.fromLTWH(x - 8, y - 20, 16, 22), const Radius.circular(6));
    c.drawRRect(slab, Paint()..color = const Color(0xFF3A2F55));
    c.drawRRect(
        slab,
        Paint()
          ..color = const Color(0xFF71629B)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _stall(Canvas c, double x, double y, Color awning) {
    // counter
    c.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(x - 34, y - 26, 68, 14),
            const Radius.circular(3)),
        Paint()..color = const Color(0xFF6B4A2E));
    // posts
    for (final px in [x - 30, x + 30]) {
      c.drawRect(Rect.fromLTWH(px - 2, y - 56, 4, 30),
          Paint()..color = const Color(0xFF4E3520));
    }
    // awning — alternating stripes
    for (var i = 0; i < 6; i++) {
      c.drawRect(
          Rect.fromLTWH(x - 36 + i * 12, y - 62, 12, 10),
          Paint()
            ..color = i.isEven ? awning : const Color(0xFFEFE4CE));
    }
    c.drawRect(Rect.fromLTWH(x - 36, y - 52, 72, 3),
        Paint()..color = const Color(0xFF2A1E10));
  }

  void _candles(Canvas c, double x0, double y0, int n) {
    for (var i = 0; i < n; i++) {
      final x = x0 + (i % 8) * 22, y = y0 + (i ~/ 8) * 20;
      c.drawCircle(Offset(x, y), 4,
          Paint()
            ..color = const Color(0x55FFC233)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
      c.drawRect(Rect.fromLTWH(x - 1.5, y - 4, 3, 8),
          Paint()..color = const Color(0xFFEFE4CE));
      c.drawCircle(Offset(x, y - 5), 1.6,
          Paint()..color = const Color(0xFFFFC233));
    }
  }

  void _tree(Canvas c, double x, double y, double srcX) {
    final img = treeImg;
    if (img == null) return;
    c.drawImageRect(
        img,
        Rect.fromLTWH(srcX, 0, 112, 160),
        Rect.fromLTWH(x - 42, y - 96, 84, 120),
        Paint()
          ..colorFilter =
              const ColorFilter.mode(_tintTree, BlendMode.modulate));
  }

  @override
  void render(Canvas canvas) {
    canvas.drawRect(size.toRect(), _nightPaint);
    // base: flat dark earth — stones sit on this like set paving
    _baseFill(canvas, size.toRect());
    // streets — clean walkable strips along the waypoint edges
    for (final e in _edges) {
      _street(canvas, Offset(_nodePos[e[0]][0], _nodePos[e[0]][1]),
          Offset(_nodePos[e[1]][0], _nodePos[e[1]][1]));
    }
    // plaza + ofrenda landings
    _plaza(canvas, const Offset(700, 330), 125);
    _plaza(canvas, const Offset(700, 715), 80);
    // gravestone field (cemetery lane, east side)
    for (var y = 520.0; y <= 640; y += 52) {
      for (var x = 1040.0; x <= 1350; x += 56) {
        if ((x - 1180).abs() < 34 && (y - 590).abs() < 40) continue; // grave 37
        _gravestone(canvas, x + ((y / 52).round() % 2) * 18, y);
      }
    }
    // market stalls
    _stall(canvas, 420, 292, const Color(0xFFEF8C1A)); // flower stall
    _stall(canvas, 540, 272, const Color(0xFF7B4FD0)); // cantina
    // ofrenda candle field
    _candles(canvas, 624, 690, 16);
    // spirit trees along the dark edges
    _tree(canvas, 90, 160, 224);
    _tree(canvas, 1240, 130, 0);
    _tree(canvas, 80, 600, 224);
    _tree(canvas, 1340, 330, 336);
    _tree(canvas, 300, 770, 0);
    _tree(canvas, 1080, 770, 224);
    // vignette — darken map borders
    for (final r in [
      Rect.fromLTWH(0, 0, size.x, 14),
      Rect.fromLTWH(0, size.y - 14, size.x, 14),
      Rect.fromLTWH(0, 0, 14, size.y),
      Rect.fromLTWH(size.x - 14, 0, 14, size.y),
    ]) {
      canvas.drawRect(r, Paint()..color = const Color(0x660A0714));
    }
  }
}

// ---------------------------------------------------------------------------

enum SpiritAnim { idle, walk }

class SpiritComponent extends SpriteAnimationGroupComponent<SpiritAnim>
    with TapCallbacks {
  final Agent agent;
  final String charKey;
  final String displayName;
  final Color? spriteTint;
  final void Function(Agent) onTapped;

  // Movement
  final List<Vector2> _path = [];
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
    this.displayName = '',
    this.spriteTint,
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
        final step = delta.normalized() * kSpiritSpeed * dt;
        position += step;
        faceToward(target.x);
      }
    }
    // depth sort by foot y; engaged pins nothing visually
    priority = -position.y.round();
    // engaged → gentle glow tint pulse
    opacity = _engaged ? min(1.0, _opacity + 0.15) : _opacity;
  }

  @override
  Future<void> onLoad() async {
    if (spriteTint != null) tint(spriteTint!);
  }

  @override
  void render(Canvas canvas) {
    super.render(canvas);
    // name tag under the feet — counter-flip so text stays readable when
    // the sprite flips horizontally to face walk direction
    if (displayName.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
            text: displayName,
            style: const TextStyle(
                fontSize: 9,
                color: Color(0xDDEFE4CE),
                fontFamily: 'monospace',
                shadows: [Shadow(color: Color(0xFF000000), blurRadius: 3)])),
        textDirection: TextDirection.ltr,
      )..layout();
      if (scale.x.isNegative) {
        canvas.save();
        canvas.translate(size.x, 0);
        canvas.scale(-1, 1);
        tp.paint(canvas, Offset((size.x - tp.width) / 2, size.y + 2));
        canvas.restore();
      } else {
        tp.paint(canvas, Offset((size.x - tp.width) / 2, size.y + 2));
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
  }) : super(
          animations: {SpiritAnim.idle: idle, SpiritAnim.walk: walk},
          current: SpiritAnim.idle,
          size: Vector2.all(56),
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
