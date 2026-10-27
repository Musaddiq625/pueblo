/// Golden-frame test — pumps the real app (mock LLM, deterministic seed)
/// and captures a golden image. `flutter test --update-goldens` writes
/// test/goldens/pueblo_main.png — that's how we see the game headless.
library;

import 'dart:io';
import 'dart:math';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:pueblo/game/world_def.dart';
import 'package:pueblo/main.dart';
import 'package:pueblo/sim/bootstrap.dart';
import 'package:pueblo/sim/llm.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  testWidgets('game frame renders', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;

    final personasJson = File('assets/data/personas.json').readAsStringSync();
    final secretsJson = File('assets/data/secrets.json').readAsStringSync();
    final bundle = await bootstrap(
      personasJson: personasJson,
      secretsJson: secretsJson,
      pois: poiDefs,
      waypointsIdx: waypoints,
      waypointPos: waypointPos,
      homePos: homePositions({for (final p in poiDefs) p.id: p}),
      llm: MockLLMClient(seed: 7),
      rng: Random(7),
      timeScale: 6.0,
      freshDb: true,
      dbPath: '${Directory.systemTemp.path}/shot_test.db',
    );

    await tester.binding.setSurfaceSize(const Size(1280, 800));
    await tester.pumpWidget(PuebloApp(bundle: bundle));
    await tester.pump(const Duration(seconds: 3)); // let sim + anims settle
    await tester.pump(const Duration(milliseconds: 300));

    await expectLater(
      find.byType(PuebloApp),
      matchesGoldenFile('goldens/pueblo_main.png'),
    );
    // Skipped: the live Flame ticker prevents the tester from ever settling,
    // so this golden capture hangs. Use --dart-define=SHOT=<sec> in-app instead.
  }, skip: true);
}
