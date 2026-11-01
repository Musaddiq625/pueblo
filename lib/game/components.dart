/// Flame components — spirit, player, POI, bubbles, petals, ground.
/// Render layer only: consumes SimEvents, never owns sim state.
library;

import 'dart:async';
import 'dart:math';

import 'package:flame/components.dart';
import 'package:flame/events.dart';
import 'package:flutter/material.dart' hide Image;

import '../sim/engine.dart';
import '../sim/models.dart';

// ---------------------------------------------------------------------------

enum SpiritAnim { idle, walk, walkDown, walkUp, death }

class SpiritComponent extends SpriteAnimationGroupComponent<SpiritAnim>
    with TapCallbacks {
  final Agent agent;
  final String charKey;
  final String displayName;
  final Color? auraColor;
  final void Function(Agent) onTapped;

  /// Time-scale hook (engine.timeScale) — the speed chip is a real
  /// fast-forward: legs accelerate with decisions and gossip.
  final double Function()? speedScale;

  /// Ghost form — the bare skeleton every spirit collapses into when
  /// forgotten. When set, fading swaps the whole animation group (and the
  /// cell's display size) rather than just dimming the person sprite.
  final Map<SpiritAnim, SpriteAnimation>? ghostAnims;
  final Vector2? ghostSize;

  // Movement
  final List<Vector2> _path = [];
  bool walking = false;

  /// Driver introspection — why a spirit looks stuck is a path question.
  int get pathLen => _path.length;
  bool get compFaded => _faded;
  bool get collapsing => _collapsing;

  // Visual state
  double _opacity = 1.0;
  bool _engaged = false;
  bool _faded = false;
  bool _collapsing = false; // ghost death anim playing → then ghost idle
  late final Map<SpiritAnim, SpriteAnimation> _personAnims = {
    for (final e in animations!.entries) e.key: e.value,
  };
  late final Vector2 _personSize = size.clone();

  SpiritComponent({
    required this.agent,
    required this.charKey,
    required this.onTapped,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
    required Vector2 displaySize,
    SpriteAnimation? walkDown,
    SpriteAnimation? walkUp,
    SpriteAnimation? death,
    this.displayName = '',
    this.auraColor,
    this.ghostAnims,
    this.ghostSize,
    this.speedScale,
  }) : super(
         animations: {
           SpiritAnim.idle: idle,
           SpiritAnim.walk: walk,
           SpiritAnim.walkDown: ?walkDown,
           SpiritAnim.walkUp: ?walkUp,
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
    if (faded && ghostAnims != null) {
      // the person dissolves into bare bone — ghost collapse plays once,
      // then the skeleton stands and wanders translucent
      walking = false;
      _path.clear();
      animations = ghostAnims;
      if (ghostSize != null) size = ghostSize!.clone();
      if (animations!.containsKey(SpiritAnim.death)) {
        _collapsing = true;
        current = SpiritAnim.death;
      } else {
        current = SpiritAnim.idle;
      }
    } else if (faded && animations?.containsKey(SpiritAnim.death) == true) {
      current = SpiritAnim.death;
    } else if (!faded) {
      // name spoken — the spirit is a person again
      _collapsing = false;
      if (ghostAnims != null) {
        animations = _personAnims;
        size = _personSize.clone();
      }
      current = SpiritAnim.idle;
      _opacity = 1.0;
    }
  }

  /// For the world-level name label — mirrors fade/engaged tint.
  double get labelOpacity => opacity;

  bool _isWalkAnim(SpiritAnim? a) =>
      a == SpiritAnim.walk ||
      a == SpiritAnim.walkDown ||
      a == SpiritAnim.walkUp;

  /// Pick the walk cycle for this step — directional sheets (trp) face
  /// the way they move; side-view sheets stay on the flipped `walk`.
  SpiritAnim _walkAnimFor(Vector2 delta) {
    if (delta.y.abs() > delta.x.abs()) {
      final v = delta.y < 0 ? SpiritAnim.walkUp : SpiritAnim.walkDown;
      if (animations?.containsKey(v) == true) return v;
    }
    return SpiritAnim.walk;
  }

  @override
  void update(double dt) {
    super.update(dt);
    if (walking && _path.isNotEmpty && !_faded) {
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
        current = _walkAnimFor(delta);
        final step =
            delta.normalized() * kSpiritSpeed * (speedScale?.call() ?? 1.0) * dt;
        position += step;
        // flip only on the horizontal axis — vertical-dominant legs would
        // flicker the sprite every frame as dx jitters around zero
        if (delta.x.abs() > delta.y.abs()) faceToward(target.x);
      }
    }
    // ghost collapse finished → the skeleton stands
    if (_collapsing && animationTicker?.done() == true) {
      _collapsing = false;
      current = SpiritAnim.idle;
    }
    // Safety net — any path that ended without flipping `walking` must
    // not leave the run cycle playing under a standing figure.
    if (!walking && !_collapsing && _isWalkAnim(current)) {
      current = SpiritAnim.idle;
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
  }
}

/// World-level spirit name tag. Lives OUTSIDE the sprite component so
/// depth sorting never paints another spirit's body over the text —
/// half-hidden names ("Doñ", "Ramó") read as bugs, not layering.
class SpiritLabelComponent extends PositionComponent {
  final SpiritComponent spirit;
  final SimEngine? engine;
  SpiritLabelComponent(this.spirit, [this.engine])
    : super(
        size: Vector2(140, 14),
        anchor: Anchor.topCenter,
        priority: 3000000, // same stratum as POI nameplates
      );

  @override
  void update(double dt) {
    super.update(dt);
    position = Vector2(spirit.position.x, spirit.position.y + 12);
  }

  @override
  void render(Canvas canvas) {
    final name = spirit.displayName;
    if (name.isEmpty) return;
    final hasNews =
        engine != null && spirit.agent.newsUntil > engine!.simTs;
    final tp = TextPainter(
      text: TextSpan(
        text: hasNews ? '💡 $name' : name,
        style: TextStyle(
          fontSize: 9,
          color: (spirit.auraColor ?? const Color(0xDDEFE4CE))
              .withValues(alpha: spirit.labelOpacity),
          fontFamily: 'monospace',
          shadows: const [Shadow(color: Color(0xFF000000), blurRadius: 3)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.x);
    tp.paint(canvas, Offset((size.x - tp.width) / 2, 0));
    if (hasNews) {
      // a gold diamond under the name — the "has news, ask them" cue
      final p = Path()
        ..moveTo(size.x / 2, 12)
        ..lineTo(size.x / 2 + 3, 15)
        ..lineTo(size.x / 2, 18)
        ..lineTo(size.x / 2 - 3, 15)
        ..close();
      canvas.drawPath(p, Paint()..color = const Color(0xFFFFC233));
    }
  }
}

// ---------------------------------------------------------------------------

class PlayerComponent extends SpriteAnimationGroupComponent<SpiritAnim> {
  final List<Vector2> _path = [];
  final double _speed = 95;

  /// Time-scale hook (engine.timeScale) — set post-construction by the
  /// game; fast-forward applies to the living one's legs too.
  double Function()? speedScale;
  bool walking = false;

  PlayerComponent({
    required Vector2 pos,
    required SpriteAnimation idle,
    required SpriteAnimation walk,
    required Vector2 displaySize,
    SpriteAnimation? walkDown,
    SpriteAnimation? walkUp,
  }) : super(
         animations: {
           SpiritAnim.idle: idle,
           SpiritAnim.walk: walk,
           SpiritAnim.walkDown: ?walkDown,
           SpiritAnim.walkUp: ?walkUp,
         },
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
      final target = _path.first;
      final delta = target - position;
      if (delta.length < 5) {
        _path.removeAt(0);
        if (_path.isEmpty) {
          walking = false;
          current = SpiritAnim.idle;
        }
      } else {
        final vertical = delta.y.abs() > delta.x.abs();
        final v = delta.y < 0 ? SpiritAnim.walkUp : SpiritAnim.walkDown;
        current =
            vertical && animations?.containsKey(v) == true ? v : SpiritAnim.walk;
        position +=
            delta.normalized() * _speed * (speedScale?.call() ?? 1.0) * dt;
        if (!vertical) {
          final faceLeft = target.x < position.x;
          if (faceLeft != scale.x.isNegative) {
            flipHorizontallyAroundCenter();
          }
        }
      }
    }
    // Same safety net as the spirits — a path that ends without flipping
    // `walking` must not leave the run cycle under a standing figure.
    if (!walking &&
        (current == SpiritAnim.walk ||
            current == SpiritAnim.walkDown ||
            current == SpiritAnim.walkUp)) {
      current = SpiritAnim.idle;
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

/// Destination ripple — brief expanding ring where the player clicked, so a
/// click-to-move reads as a deliberate walk order, not a wander.
class ClickMarker extends PositionComponent {
  double _t = 0;
  ClickMarker(Vector2 pos)
    : super(
        position: pos,
        size: Vector2.all(36),
        anchor: Anchor.center,
        priority: 9000,
      );

  @override
  void update(double dt) {
    _t += dt;
    if (_t > 0.55) removeFromParent();
  }

  @override
  void render(Canvas canvas) {
    final p = _t / 0.55;
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(size.x / 2, size.y / 2),
        width: 8 + p * 40,
        height: 4 + p * 20,
      ),
      Paint()
        ..color = Color.fromRGBO(255, 194, 51, 0.75 * (1 - p))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }
}

// ---------------------------------------------------------------------------

/// Speech/emote bubble floating over a component's head. [speaker] shows a
/// small name chip over the line — who is talking should never be a guess.
///
/// Lives at WORLD level, not parented to the spirit: a child bubble's
/// priority sorts inside the parent's subtree, so any sprite or prop
/// standing in front would swallow the line. World-level + tracking keeps
/// it pinned above the head and above every nameplate in the world.
class BubbleComponent extends PositionComponent {
  final String text;
  final String speaker;
  final bool isEmote;

  /// Thought bubble — dimmer, borderless, drifts faster than speech.
  final bool isThought;

  /// The component whose head this floats over — re-anchored every frame
  /// so the bubble rides a moving speaker instead of a fixed spot.
  final PositionComponent? track;

  /// Headroom above the tracked sprite's top edge (world px).
  final double gap;
  double _ttl;

  BubbleComponent(
    this.text, {
    this.speaker = '',
    this.isEmote = false,
    this.isThought = false,
    this.track,
    this.gap = 6,
    Vector2? size,
  }) : _ttl = isEmote
           ? kBubbleLifeEmote
           : (isThought ? kBubbleLifeThought : kBubbleLifeSay),
       super(
         size: size ?? Vector2(220, 44),
         anchor: Anchor.bottomCenter,
         // above nameplates (3000000); speech outranks emotes, which
         // outrank thoughts — words are the content, the rest is garnish
         priority: isEmote
             ? 3000002
             : (isThought ? 3000001 : 3000003),
       );

  @override
  void update(double dt) {
    _ttl -= dt;
    if (_ttl <= 0) removeFromParent();
    final t = track;
    if (t != null) {
      position = Vector2(t.position.x, t.position.y - t.size.y - gap);
    }
    // float up gently — thoughts drift faster and fade with the drift
    position.y -= dt * (isThought ? 12 : 6);
  }

  @override
  void render(Canvas canvas) => _draw(canvas);

  void _draw(Canvas canvas) {
    final style = TextStyle(
      color: isThought ? const Color(0xCCDCD4F0) : const Color(0xFFFFF4DC),
      fontSize: isEmote ? 22 : (isThought ? 11 : 12.5),
      fontStyle: isThought ? FontStyle.italic : FontStyle.normal,
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
    if (isThought) {
      // inner voice — a wisp, but it still needs a backing panel or it
      // camouflages into whatever sprite/prop is behind it
      final w = tp.width + 14;
      final h = tp.height + 8;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH((size.x - w) / 2, 0, w, h),
        const Radius.circular(8),
      );
      canvas.drawRRect(rect, Paint()..color = const Color(0xB32B2145));
      canvas.drawRRect(
        rect,
        Paint()
          ..color = const Color(0x66998BE0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );
      tp.paint(canvas, Offset((size.x - tp.width) / 2, 4));
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
