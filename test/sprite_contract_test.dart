/// Sprite contract — the walk-shrink bug's regression guard.
/// Every animation of a character must share one cell geometry; frames
/// are foot-anchored by the repack tool so scale can't drift per-anim.
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/game/chars_norm_manifest.g.dart';
import 'package:pueblo/game/sprites_manifest.dart';

void main() {
  test('normalized sheets exist on disk for every declared anim', () {
    for (final entry in normChars.entries) {
      for (final anim in entry.value.anims.entries) {
        final f = File('assets/sprites/${anim.value.path}');
        expect(
          f.existsSync(),
          isTrue,
          reason: 'missing ${anim.value.path} — run tool/repack_chars.dart',
        );
      }
    }
  });

  test('all anims of a character share the same cell size', () {
    for (final entry in normChars.entries) {
      final c = entry.value;
      for (final anim in c.anims.entries) {
        expect(
          anim.value.cellW == c.cellW && anim.value.cellH == c.cellH,
          isTrue,
          reason:
              '${entry.key}.${anim.key} cell ${anim.value.cellW}x'
              '${anim.value.cellH} != shared ${c.cellW}x${c.cellH}',
        );
      }
    }
  });

  test('every manifested char resolves a display size', () {
    for (final key in normChars.keys) {
      final def = chars[key];
      expect(
        def,
        isNotNull,
        reason: 'no CharDef for $key in sprites_manifest',
      );
      if (def != null) {
        expect(def.displayH, greaterThan(0));
        expect(def.displayW, greaterThan(0));
      }
    }
  });
}
