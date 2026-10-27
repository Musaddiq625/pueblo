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
  final VoidCallback onEnd;

  const InspectCard({
    super.key,
    required this.engine,
    required this.spiritSprite,
    required this.onEnd,
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
              _Portrait(sprite: widget.spiritSprite),
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
  const _Portrait({required this.sprite});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52, height: 52,
      decoration: BoxDecoration(
        color: const Color(0xFF2A2145),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF8A6FC0)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(9),
        child: Image.asset('assets/sprites/chars/${sprite}_idle.png',
            fit: BoxFit.cover,
            alignment: Alignment.centerLeft,
            filterQuality: FilterQuality.none),
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
