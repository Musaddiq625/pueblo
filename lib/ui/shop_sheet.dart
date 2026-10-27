/// ShopSheet — stall purchase UI. Deterministic catalog (zero inference);
/// purchases commit atomically through engine.buyItem.
library;

import 'package:flutter/material.dart';

import '../sim/engine.dart';

class ShopSheet extends StatelessWidget {
  final SimEngine engine;
  final String stallId;
  final String stallName;
  final VoidCallback onClose;
  final VoidCallback onChanged;

  const ShopSheet({
    super.key,
    required this.engine,
    required this.stallId,
    required this.stallName,
    required this.onClose,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final items = engine.stallItems(stallId);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xF2201A38),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        border: Border.all(color: const Color(0xFFFFC233), width: 1.4),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          Expanded(
            child: Text(stallName,
                key: const Key('shopTitle'),
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFFFC233))),
          ),
          IconButton(
              key: const Key('closeShopButton'),
              icon: const Icon(Icons.close, color: Color(0xFFB0A6D8)),
              onPressed: onClose),
        ]),
        for (final it in items) _itemRow(context, it),
        if (items.isEmpty)
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text('Nothing for sale here.',
                style: TextStyle(color: Color(0xFF8D84B0), fontSize: 12)),
          ),
      ]),
    );
  }

  Widget _itemRow(BuildContext context, Map<String, Object?> it) {
    final locked = it['locked'] == true;
    final price = it['price'] as int;
    final afford = engine.playerPetals >= price;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${it['name']}',
                style: TextStyle(
                    fontSize: 13,
                    color: locked
                        ? const Color(0xFF5A5078)
                        : const Color(0xFFDCD4F0))),
            Text('${it['desc']}',
                style: const TextStyle(fontSize: 10.5, color: Color(0xFF8D84B0))),
          ]),
        ),
        const SizedBox(width: 10),
        TextButton(
          key: Key('buy_${it['id']}'),
          onPressed: locked || !afford
              ? null
              : () async {
                  final ok = await engine.buyItem(it['id'] as String);
                  onChanged();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      duration: const Duration(seconds: 2),
                      content: Text(ok
                          ? 'Bought ${it['name']}.'
                          : 'The sale fell through.'),
                    ));
                  }
                },
          style: TextButton.styleFrom(
            foregroundColor: const Color(0xFFFFC233),
            disabledForegroundColor: const Color(0xFF5A5078),
          ),
          child: Text(locked ? 'earn trust' : '🌼 $price',
              style: const TextStyle(fontSize: 12.5)),
        ),
      ]),
    );
  }
}
