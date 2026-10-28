import 'package:vm_service/vm_service_io.dart';
void main(List<String> args) async {
  final s = await vmServiceConnectUri(args[0]);
  final vm = await s.getVM();
  for (final i in vm.isolates!) {
    final iso = await s.getIsolate(i.id!);
    print('${i.name}: ${(iso.extensionRPCs ?? []).where((e) => e.contains('pueblo'))}');
  }
  // count frames via ext.ui.window.scheduleFrame to see if rendering runs
  try {
    final r = await s.callServiceExtension('ext.ui.window.scheduleFrame',
        isolateId: vm.isolates!.first.id!, args: {});
    print('scheduleFrame: $r');
  } catch (e) { print('scheduleFrame FAIL: $e'); }
  await s.dispose();
}
