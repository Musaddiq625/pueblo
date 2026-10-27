/// ModelGate — the on-device model checkpoint (P6, Pixel build).
/// Verifies a Gemma 3n .task exists, offers download (HF token via
/// --dart-define HF_TOKEN), installs + warms it, then opens the game.
/// The gate only opens for a model that actually generates.
library;

import 'dart:async';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart' as bd;
import 'package:flutter/material.dart';
import 'package:flutter_gemma/flutter_gemma.dart';
import 'package:path_provider/path_provider.dart';

enum GateStatus { checking, missing, downloading, warming, ready, failed }

class ModelGate extends StatefulWidget {
  final VoidCallback onReady;
  const ModelGate({super.key, required this.onReady});

  @override
  State<ModelGate> createState() => _ModelGateState();
}

class _ModelGateState extends State<ModelGate> {
  static const _modelFile = 'gemma-3n-E2B-it-int4.task';
  static const _modelUrl =
      'https://huggingface.co/google/gemma-3n-E2B-it-litert-preview/resolve/main/gemma-3n-E2B-it-int4.task';
  static const _hfToken = String.fromEnvironment('HF_TOKEN');
  static const _minBytes = 2000000000; // ~3 GB real file
  static const _taskId = 'pueblo_gemma';

  GateStatus _status = GateStatus.checking;
  double _progress = 0;
  String? _error;
  StreamSubscription<bd.TaskUpdate>? _sub;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    setState(() => _status = GateStatus.checking);
    try {
      await FlutterGemma.initialize(
          huggingFaceToken: _hfToken.isEmpty ? null : _hfToken);
      await _wireDownloader();
      if (await _reactivate()) {
        await _warmup();
      } else {
        setState(() => _status = GateStatus.missing);
      }
    } catch (e) {
      setState(() {
        _status = GateStatus.failed;
        _error = '$e';
      });
    }
  }

  Future<void> _wireDownloader() async {
    await bd.FileDownloader().trackTasks();
    _sub ??= bd.FileDownloader().updates.listen((u) {
      if (u.task.taskId != _taskId) return;
      switch (u) {
        case bd.TaskStatusUpdate s:
          switch (s.status) {
            case bd.TaskStatus.complete:
              unawaited(_installFrom(u.task));
            case bd.TaskStatus.failed:
              setState(() {
                _status = GateStatus.failed;
                _error = 'download failed (http ${s.responseStatusCode ?? '?'})';
              });
            case _:
              setState(() => _status = GateStatus.downloading);
          }
        case bd.TaskProgressUpdate p:
          if (p.progress >= 0 && p.progress < 1) {
            setState(() {
              _status = GateStatus.downloading;
              _progress = p.progress;
            });
          }
      }
    });
  }

  Future<bool> _reactivate() async {
    final installed = await FlutterGemma.listInstalledModels();
    final dir = await getApplicationDocumentsDirectory();
    for (final f in installed) {
      if (!f.endsWith('.task')) continue;
      if (await File('${dir.path}/$f').length() < _minBytes) continue;
      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromFile('${dir.path}/$f')
          .install();
      return true;
    }
    return false;
  }

  Future<void> _download() async {
    setState(() {
      _status = GateStatus.downloading;
      _error = null;
    });
    final task = bd.DownloadTask(
      taskId: _taskId,
      url: _modelUrl,
      filename: _modelFile,
      headers: {if (_hfToken.isNotEmpty) 'Authorization': 'Bearer $_hfToken'},
      allowPause: true,
      retries: 3,
      updates: bd.Updates.statusAndProgress,
    );
    if (!await bd.FileDownloader().enqueue(task)) {
      setState(() {
        _status = GateStatus.failed;
        _error = 'download rejected by platform';
      });
    }
  }

  Future<void> _installFrom(bd.Task task) async {
    setState(() => _status = GateStatus.warming);
    try {
      final path = await (task as bd.DownloadTask).filePath();
      await FlutterGemma.installModel(modelType: ModelType.gemmaIt)
          .fromFile(path)
          .install();
      await _warmup();
    } catch (e) {
      setState(() {
        _status = GateStatus.failed;
        _error = 'install failed: $e';
      });
    }
  }

  /// Prove the model generates — the gate only opens for a working brain.
  Future<void> _warmup() async {
    setState(() => _status = GateStatus.warming);
    try {
      final model = await FlutterGemma.getActiveModel(
        preferredBackend: PreferredBackend.gpu,
        maxTokens: 512,
      );
      final s = await model.createSession(temperature: 0.5, topK: 40);
      try {
        await s.addQueryChunk(Message.text(text: 'say ok', isUser: true));
        await s.getResponse();
      } finally {
        try {
          await s.close();
        } catch (_) {}
      }
      setState(() => _status = GateStatus.ready);
      widget.onReady();
    } catch (e) {
      setState(() {
        _status = GateStatus.failed;
        _error = 'warmup failed: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFF120E20),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Text('🕯️', style: TextStyle(fontSize: 44)),
            const SizedBox(height: 14),
            const Text('Pueblo de las Velas',
                style: TextStyle(fontSize: 20, color: Color(0xFFFFC233))),
            const SizedBox(height: 8),
            Text(switch (_status) {
              GateStatus.checking => 'checking for the town\'s brain…',
              GateStatus.missing =>
                'the spirits need a brain — Gemma 3n E2B (~3 GB)',
              GateStatus.downloading =>
                'downloading ${(100 * _progress).toStringAsFixed(0)}%',
              GateStatus.warming => 'waking the spirits…',
              GateStatus.ready => 'ready!',
              GateStatus.failed => 'something went wrong',
            },
                textAlign: TextAlign.center,
                style:
                    const TextStyle(fontSize: 13, color: Color(0xFFB0A6D8))),
            const SizedBox(height: 18),
            if (_status == GateStatus.missing || _status == GateStatus.failed)
              ElevatedButton(
                key: const Key('downloadModelButton'),
                onPressed: _download,
                child: const Text('Download the model'),
              ),
            if (_status == GateStatus.downloading)
              SizedBox(
                width: 220,
                child: LinearProgressIndicator(
                    value: _progress, color: const Color(0xFFFFC233)),
              ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 11, color: Color(0xFFE08A8A))),
            ],
            if (_status == GateStatus.missing)
              const Padding(
                padding: EdgeInsets.only(top: 14),
                child: Text(
                    'needs a HuggingFace token: rebuild with\n--dart-define HF_TOKEN=hf_…',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: Color(0xFF6A6088))),
              ),
          ]),
        ),
      ),
    );
  }
}
