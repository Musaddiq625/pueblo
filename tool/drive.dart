// Driver bridge — calls ext.pueblo.cmd on a running app.
// Usage: dart tool/drive.dart <ws-vm-service-uri> <cmd...>
//   dart tool/drive.dart ws://127.0.0.1:PORT/xxx=/ws shot
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: drive.dart <ws-uri> <cmd...>');
    exit(64);
  }
  final service = await vmServiceConnectUri(args[0]);
  final vm = await service.getVM();
  final isolate = vm.isolates!.firstWhere(
    (i) => (i.name ?? '').contains('main'),
    orElse: () => vm.isolates!.first,
  );
  // Service extensions live on the isolate.
  final res = await service.callServiceExtension(
    'ext.pueblo.cmd',
    isolateId: isolate.id!,
    args: {'cmd': args.sublist(1).join(' ')},
  );
  final json = res.json?['result'];
  if (json is String) {
    try {
      print(jsonEncode(jsonDecode(json)));
    } catch (_) {
      print(json);
    }
  } else {
    print(res.json);
  }
  await service.dispose();
  exit(0);
}
