import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/library/data/library_indexer.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Where NOIR keeps derived data (artwork) and, on mobile, imported copies.
final appDirectoriesProvider = Provider<AppDirectories>(
  (ref) =>
      throw UnimplementedError('appDirectoriesProvider must be overridden'),
);

class AppDirectories {
  const AppDirectories({required this.artwork, required this.importedMusic});

  static Future<AppDirectories> resolve() async {
    final support = await getApplicationSupportDirectory();
    final docs = await getApplicationDocumentsDirectory();
    return AppDirectories(
      artwork: Directory(p.join(support.path, 'artwork')),
      importedMusic: Directory(p.join(docs.path, 'NOIR Music')),
    );
  }

  final Directory artwork;
  final Directory importedMusic;
}

final libraryIndexerProvider = Provider<LibraryIndexer>(
  (ref) => LibraryIndexer(
    ref.watch(libraryRepositoryProvider),
    ref.watch(appDirectoriesProvider).artwork,
  ),
);

sealed class ScanState {
  const ScanState();
}

final class ScanIdle extends ScanState {
  const ScanIdle();
}

final class Scanning extends ScanState {
  const Scanning(this.label);
  final String label;
}

final class ScanFinished extends ScanState {
  const ScanFinished(this.summary);
  final ScanSummary summary;
}

final class ScanFailed extends ScanState {
  const ScanFailed(this.message);
  final String message;
}

final libraryScanProvider = NotifierProvider<LibraryScanController, ScanState>(
  LibraryScanController.new,
);

/// User-initiated library changes: add/remove folders, import files, rescan.
class LibraryScanController extends Notifier<ScanState> {
  @override
  ScanState build() => const ScanIdle();

  bool get _busy => state is Scanning;

  static bool get supportsFolders =>
      Platform.isWindows || Platform.isMacOS || Platform.isAndroid;

  /// Picks a folder, remembers it and indexes it.
  Future<void> addFolder() async {
    if (_busy || !await _ensureAudioPermission()) return;
    final folder = await FilePicker.getDirectoryPath(
      dialogTitle: 'Choose a music folder',
    );
    if (folder == null) return; // Cancelled.
    if (folder.startsWith('content://')) {
      state = const ScanFailed(
        "NOIR can't read that location directly. Pick a folder in internal "
        'storage, or use "Add files" instead.',
      );
      return;
    }
    await ref.read(libraryRepositoryProvider).addFolder(folder);
    await _run(
      'Scanning ${p.basename(folder)}',
      () => ref.read(libraryIndexerProvider).scanFolder(folder),
    );
  }

  Future<void> removeFolder(String folder) =>
      ref.read(libraryRepositoryProvider).removeFolder(folder);

  Future<void> rescanAll() async {
    if (_busy) return;
    final folders = await ref.read(libraryRepositoryProvider).folders();
    if (folders.isEmpty) return;
    await _run('Rescanning library', () async {
      var indexed = 0;
      var unchanged = 0;
      var removed = 0;
      var unreadable = 0;
      for (final f in folders) {
        final s = await ref.read(libraryIndexerProvider).scanFolder(f.path);
        indexed += s.indexed;
        unchanged += s.unchanged;
        removed += s.removed;
        unreadable += s.unreadableTags;
      }
      return ScanSummary(
        indexed: indexed,
        unchanged: unchanged,
        removed: removed,
        unreadableTags: unreadable,
      );
    });
  }

  /// Picks audio files. Desktop indexes them in place; mobile platforms copy
  /// them into NOIR's own folder because picker paths there are temporary.
  Future<void> importFiles() async {
    if (_busy) return;
    final picked = await FilePicker.pickFiles(
      type: FileType.audio,
      dialogTitle: 'Add music files',
    );
    if (picked.isEmpty) return; // Cancelled.
    await _run('Adding ${picked.length} files', () async {
      final paths = Platform.isAndroid || Platform.isIOS
          ? await _copyIntoLibrary(picked)
          : [for (final f in picked) ?f.path];
      return await ref.read(libraryIndexerProvider).indexFiles(paths);
    });
  }

  void dismissResult() => state = const ScanIdle();

  /// Mobile pickers may hand out content URIs; copy the bytes into NOIR's
  /// own folder so the library keeps working after the picker cache is gone.
  Future<List<String>> _copyIntoLibrary(List<PlatformFile> files) async {
    final dir = ref.read(appDirectoriesProvider).importedMusic;
    await dir.create(recursive: true);
    final paths = <String>[];
    for (final f in files) {
      final target = File(_freeName(dir.path, f.name));
      final sink = target.openWrite();
      await sink.addStream(f.readAsByteStream());
      await sink.close();
      paths.add(target.path);
    }
    return paths;
  }

  /// `Song.mp3` -> `Song (2).mp3` when the name is taken.
  static String _freeName(String dir, String name) {
    var candidate = p.join(dir, name);
    for (var i = 2; File(candidate).existsSync(); i++) {
      candidate = p.join(
        dir,
        '${p.basenameWithoutExtension(name)} ($i)${p.extension(name)}',
      );
    }
    return candidate;
  }

  Future<void> _run(String label, Future<ScanSummary> Function() job) async {
    state = Scanning(label);
    try {
      state = ScanFinished(await job());
    } on Object catch (e) {
      debugPrint('Library scan failed: ${e.runtimeType}');
      state = const ScanFailed(
        "NOIR couldn't read that location. Check that it still exists and "
        'that NOIR has permission to open it.',
      );
    }
  }

  /// Android needs a media permission to read music in shared storage.
  Future<bool> _ensureAudioPermission() async {
    if (!Platform.isAndroid) return true;
    // READ_MEDIA_AUDIO on Android 13+, READ_EXTERNAL_STORAGE before that.
    final statuses = await [Permission.audio, Permission.storage].request();
    if (statuses.values.any((s) => s.isGranted || s.isLimited)) return true;
    state = const ScanFailed(
      'NOIR needs access to your music to index a folder. You can allow it in '
      'system settings.',
    );
    return false;
  }
}
