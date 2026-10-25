import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:path/path.dart' as p;

/// What smart transitions decided and why, for diagnosing them on a user's
/// machine: the last [capacity] lines in memory, every line in the debug
/// console and appended to [file] (trimmed to its newer half beyond
/// [maxBytes]).
class TransitionLog {
  TransitionLog({this.file, this.capacity = 200, this.maxBytes = 256 * 1024});

  final File? file;
  final int capacity;
  final int maxBytes;
  final _lines = ListQueue<String>();
  Future<void> _writing = Future.value();

  List<String> get lines => List.unmodifiable(_lines);

  void add(String message) {
    final line = '${DateTime.now().toIso8601String()} $message';
    _lines.add(line);
    while (_lines.length > capacity) {
      _lines.removeFirst();
    }
    debugPrint('[transition] $message');
    final f = file;
    if (f != null) _writing = _writing.then((_) => _append(f, line));
  }

  /// Completes when everything added so far is on disk.
  Future<void> flush() => _writing;

  Future<void> _append(File f, String line) async {
    try {
      await f.parent.create(recursive: true);
      if (f.existsSync() && f.lengthSync() > maxBytes) {
        final text = await f.readAsString();
        final keep = text.substring(text.length - maxBytes ~/ 2);
        final from = keep.indexOf('\n') + 1;
        await f.writeAsString(keep.substring(from));
      }
      await f.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } on Object catch (e) {
      // Diagnostics must never disturb playback.
      debugPrint('Transition log not written: ${e.runtimeType}');
    }
  }
}

/// `<app support>/logs/transitions.log`; in memory only where the app
/// directories are unknown (tests).
final transitionLogProvider = Provider<TransitionLog>((ref) {
  File? file;
  try {
    final support = ref.watch(appDirectoriesProvider).artwork.parent;
    file = File(p.join(support.path, 'logs', 'transitions.log'));
  } on Object {
    file = null;
  }
  return TransitionLog(file: file);
});
