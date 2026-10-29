/// InspectCard — bottom sheet shown while a spirit is engaged.
/// Shows name/role/persona/mood/condition + portrait + chat.
/// Release is user-driven ONLY: End button or engaging another spirit.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../sim/engine.dart';
import '../sim/models.dart';

class InspectCard extends StatefulWidget {
  final SimEngine engine;
  final String spiritSprite;
  final int? spiritDye;
  final VoidCallback onEnd;

  const InspectCard({
    super.key,
    required this.engine,
    required this.spiritSprite,
    required this.onEnd,
    this.spiritDye,
  });

  @override
  State<InspectCard> createState() => _InspectCardState();
}

class _InspectCardState extends State<InspectCard> {
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  final List<(bool user, String text)> _msgs = [];
  String _streaming = '';
  bool _busy = false;

  Agent get a => widget.engine.agents[widget.engine.engagedId]!;

  @override
  void dispose() {
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _ctrl.text.trim();
    if (text.isEmpty || _busy) return;
    _ctrl.clear();
    setState(() {
      _msgs.add((true, text));
      _busy = true;
      _streaming = '';
    });
    _toBottom();
    final buf = StringBuffer();
    await for (final chunk in widget.engine.sendPlayerMessage(text)) {
      buf.write(chunk);
      if (mounted) setState(() => _streaming = buf.toString());
      _toBottom();
    }
    if (mounted) {
      setState(() {
        _msgs.add((false, buf.toString().trim()));
        _streaming = '';
        _busy = false;
      });
      _toBottom();
    }
  }

  void _toBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = a.stats;
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF2201A38),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border.all(color: const Color(0xFFFFC233), width: 1.4),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // header: portrait + name/role/persona/mood/condition
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Portrait(sprite: widget.spiritSprite, dye: widget.spiritDye),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(a.name,
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.bold,
                            color: Color(0xFFFFC233))),
                    Text('${a.role} · ${a.condition}',
                        style: const TextStyle(
                            fontSize: 12, color: Color(0xFFB0A6D8))),
                    const SizedBox(height: 4),
                    Text(a.persona,
                        maxLines: 2, overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11.5, color: Color(0xFF8D84B0),
                            fontStyle: FontStyle.italic)),
                    const SizedBox(height: 6),
                    _StatRow(s),
                  ],
                ),
              ),
              IconButton(
                key: const Key('endInteractionButton'),
                tooltip: 'End interaction',
                icon: const Icon(Icons.close, color: Color(0xFFB0A6D8)),
                onPressed: widget.onEnd,
              ),
            ],
          ),
          const Divider(color: Color(0xFF3A2C50), height: 18),
          // gifts — owned consumables the player can hand over
          Builder(builder: (context) {
            final gifts = widget.engine.playerInventory.entries
                .where((e) => e.value > 0 &&
                    SimEngine.shopItems[e.key]?['secret'] == null)
                .toList();
            if (gifts.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(spacing: 6, children: [
                for (final g in gifts)
                  ActionChip(
                    key: Key('gift_${g.key}'),
                    label: Text(
                        '${SimEngine.shopItems[g.key]?['name']} ×${g.value}',
                        style: const TextStyle(fontSize: 11)),
                    backgroundColor: const Color(0xFF2A2145),
                    side: const BorderSide(color: Color(0xFF8A6FC0)),
                    labelStyle: const TextStyle(color: Color(0xFFFFC233)),
                    onPressed: () async {
                      await widget.engine.giveGift(a.id, g.key);
                      if (mounted) setState(() {});
                    },
                  ),
              ]),
            );
          }),
          // tell them about… — secrets the player knows that this spirit
          // lacks. Persona decides what happens to your words (D1).
          Builder(builder: (context) {
            final teachable = widget.engine.playerKnown
                .where((sid) => !a.knownSecrets.contains(sid))
                .map((sid) => widget.engine.secrets[sid])
                .whereType<Secret>()
                .toList();
            if (teachable.isEmpty) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(spacing: 6, children: [
                for (final s in teachable)
                  ActionChip(
                    key: Key('teach_${s.id}'),
                    avatar: const Icon(Icons.tips_and_updates,
                        size: 13, color: Color(0xFFF5A95B)),
                    label: Text(
                      s.shareText.length > 34
                          ? '${s.shareText.substring(0, 31)}…'
                          : s.shareText,
                      style: const TextStyle(fontSize: 10.5),
                    ),
                    tooltip: s.shareText,
                    backgroundColor: const Color(0xFF2A2145),
                    side: const BorderSide(color: Color(0xFFF5A95B)),
                    labelStyle: const TextStyle(color: Color(0xFFF5E3C8)),
                    onPressed: () async {
                      final note = await widget.engine.teachSpirit(a.id, s.id);
                      if (mounted) {
                        setState(() => _msgs.add((false, '· $note')));
                      }
                    },
                  ),
              ]),
            );
          }),
          // chat
          SizedBox(
            height: 130,
            child: ListView(
              controller: _scroll,
              children: [
                for (final m in _msgs) _ChatLine(user: m.$1, text: m.$2),
                if (_streaming.isNotEmpty)
                  _ChatLine(user: false, text: _streaming, streaming: true),
                if (_msgs.isEmpty && _streaming.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: Text('Say something…',
                        style: TextStyle(color: Color(0xFF6A6088), fontSize: 12)),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const Key('playerChatField'),
                  controller: _ctrl,
                  onSubmitted: (_) => _send(),
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    hintText: 'Talk to ${a.name.split(' ').first}…',
                    hintStyle: const TextStyle(fontSize: 12, color: Color(0xFF6A6088)),
                    filled: true, fillColor: const Color(0xFF2A2145),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const Key('sendChatButton'),
                icon: const Icon(Icons.send, color: Color(0xFFFFC233), size: 20),
                onPressed: _busy ? null : _send,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Portrait extends StatelessWidget {
  final String sprite;
  final int? dye;
  const _Portrait({required this.sprite, this.dye});
  @override
  Widget build(BuildContext context) {
    Widget img = Image.asset('assets/sprites/chars/${sprite}_idle.png',
        fit: BoxFit.cover,
        alignment: Alignment.centerLeft,
        filterQuality: FilterQuality.none);
    final d = dye;
    if (d != null) {
      img = ColorFiltered(
        colorFilter: ColorFilter.mode(Color(d), BlendMode.modulate),
        child: img,
      );
    }
    return Container(
      width: 52, height: 52,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2145),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF8A6FC0)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: img,
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  final Stats s;
  const _StatRow(this.s);
  @override
  Widget build(BuildContext context) {
    Widget chip(String label, int v) => Padding(
          padding: const EdgeInsets.only(right: 6),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text('$label ',
                style: const TextStyle(fontSize: 9, color: Color(0xFF8D84B0))),
            Text('★' * v + '☆' * (5 - v),
                style: const TextStyle(fontSize: 9, color: Color(0xFFFFC233))),
          ]),
        );
    return Wrap(children: [
      chip('cur', s.curiosity), chip('wit', s.wit), chip('warm', s.warmth),
      chip('sight', s.spiritSight), chip('misc', s.mischief), chip('grump', s.grump),
    ]);
  }
}

class _ChatLine extends StatelessWidget {
  final bool user;
  final String text;
  final bool streaming;
  const _ChatLine({required this.user, required this.text, this.streaming = false});
  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: user ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        constraints: const BoxConstraints(maxWidth: 260),
        decoration: BoxDecoration(
          color: user ? const Color(0xFF4A3A72) : const Color(0xFF2A2145),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: user ? const Color(0xFF8A6FC0) : const Color(0xFF3A2C50)),
        ),
        child: Text(
          text + (streaming ? '▌' : ''),
          style: TextStyle(
              fontSize: 12.5,
              color: user ? const Color(0xFFDCD4F0) : const Color(0xFFFFF4DC)),
        ),
      ),
    );
  }
}
