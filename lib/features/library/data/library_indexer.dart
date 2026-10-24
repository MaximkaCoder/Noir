import 'dart:io';
import 'dart:isolate';

import 'package:audio_metadata_reader/audio_metadata_reader.dart';
import 'package:drift/drift.dart' show Value;
import 'package:noir/core/database/app_database.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:path/path.dart' as p;

const supportedAudioExtensions = {
  '.mp3',
  '.m4a',
  '.aac',
  '.flac',
  '.ogg',
  '.oga',
  '.opus',
  '.wav',
};

/// Outcome of one scan, shown to the user.
class ScanSummary {
  const ScanSummary({
    required this.indexed,
    required this.unchanged,
    required this.removed,
    required this.unreadableTags,
  });

  /// New or changed files written to the library.
  final int indexed;
  final int unchanged;

  /// Files that disappeared from disk and were dropped from the library.
  final int removed;

  /// Files added with a filename-based title because their tags could not be
  /// read (they may still play).
  final int unreadableTags;
}

/// Turns folders/files the user chose into library rows. Heavy work (directory
/// walk, tag parsing, artwork extraction) runs on a background isolate.
class LibraryIndexer {
  LibraryIndexer(this._repo, this._artworkDir);

  final LibraryRepository _repo;
  final Directory _artworkDir;

  Future<ScanSummary> scanFolder(String folder) async {
    final known = await _repo.knownFilesUnder(folder);
    final knownMs = {
      for (final e in known.entries) e.key: e.value.millisecondsSinceEpoch,
    };
    final artworkDir = _artworkDir.path;
    final result = await Isolate.run(
      () => _scan(_listAudioFiles(folder), knownMs, artworkDir),
    );
    await _repo.upsertScanned(result.rows);
    final missing = known.keys.toSet().difference(result.seen);
    await _repo.removePaths(missing);
    await _repo.markScanned(folder);
    return ScanSummary(
      indexed: result.rows.length,
      unchanged: result.unchanged,
      removed: missing.length,
      unreadableTags: result.unreadable,
    );
  }

  /// Indexes individual files (desktop: in place; mobile: app-owned copies).
  Future<ScanSummary> indexFiles(List<String> paths) async {
    final files = [
      for (final path in paths)
        if (supportedAudioExtensions.contains(p.extension(path).toLowerCase()))
          path,
    ];
    final artworkDir = _artworkDir.path;
    final result = await Isolate.run(() => _scan(files, const {}, artworkDir));
    await _repo.upsertScanned(result.rows);
    return ScanSummary(
      indexed: result.rows.length,
      unchanged: 0,
      removed: 0,
      unreadableTags: result.unreadable,
    );
  }
}

class _ScanResult {
  _ScanResult(this.rows, this.seen, this.unchanged, this.unreadable);

  final List<TracksCompanion> rows;
  final Set<String> seen;
  final int unchanged;
  final int unreadable;
}

List<String> _listAudioFiles(String folder) {
  final dir = Directory(folder);
  if (!dir.existsSync()) return const [];
  final files = <String>[];
  // Unreadable subfolders are skipped rather than aborting the whole scan.
  void walk(Directory d) {
    List<FileSystemEntity> children;
    try {
      children = d.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final entity in children) {
      if (entity is Directory) {
        walk(entity);
      } else if (entity is File &&
          supportedAudioExtensions.contains(
            p.extension(entity.path).toLowerCase(),
          )) {
        files.add(entity.path);
      }
    }
  }

  walk(dir);
  return files;
}

/// Runs on a background isolate.
_ScanResult _scan(
  List<String> files,
  Map<String, int> knownModifiedMs,
  String artworkDir,
) {
  final rows = <TracksCompanion>[];
  final seen = <String>{};
  final artworkByKey = <String, String?>{};
  var unchanged = 0;
  var unreadable = 0;
  final now = DateTime.now();

  for (final path in files) {
    final file = File(path);
    FileStat stat;
    try {
      stat = file.statSync();
    } on FileSystemException {
      continue;
    }
    seen.add(path);
    // The database stores timestamps with one-second precision.
    final known = knownModifiedMs[path];
    if (known != null &&
        known ~/ 1000 == stat.modified.millisecondsSinceEpoch ~/ 1000) {
      unchanged++;
      continue;
    }

    AudioMetadata? meta;
    try {
      meta = readMetadata(file, getImage: true);
    } on Object {
      unreadable++;
    }

    final artist = _clean(meta?.artist);
    final album = _clean(meta?.album);
    final albumArtist = _clean(meta?.albumArtist);
    String? artworkPath;
    final pictures = meta?.pictures ?? const <Picture>[];
    if (pictures.isNotEmpty) {
      // One artwork file per album; per file when the album is unknown.
      final key = album == null
          ? path
          : '${albumArtist ?? artist ?? ''}\u0000$album';
      artworkPath = artworkByKey.putIfAbsent(
        key,
        () => _writeArtwork(artworkDir, key, pictures.first),
      );
    }

    rows.add(
      TracksCompanion.insert(
        path: path,
        title: _clean(meta?.title) ?? p.basenameWithoutExtension(path),
        artist: Value(artist),
        album: Value(album),
        albumArtist: Value(albumArtist),
        trackNumber: Value(meta?.trackNumber),
        discNumber: Value(meta?.discNumber),
        year: Value(meta?.year?.year),
        durationMs: Value(meta?.duration?.inMilliseconds),
        artworkPath: Value(artworkPath),
        fileSize: stat.size,
        modifiedAt: stat.modified,
        addedAt: now,
      ),
    );
  }
  return _ScanResult(rows, seen, unchanged, unreadable);
}

String? _clean(String? value) {
  final v = value?.replaceAll('\u0000', '').trim();
  return v == null || v.isEmpty ? null : v;
}

String? _writeArtwork(String dir, String key, Picture picture) {
  try {
    final ext = picture.mimetype.contains('png') ? 'png' : 'jpg';
    final file = File(p.join(dir, '${fnv1a64(key)}.$ext'));
    if (!file.existsSync()) {
      file
        ..createSync(recursive: true)
        ..writeAsBytesSync(picture.bytes);
    }
    return file.path;
  } on FileSystemException {
    return null;
  }
}

/// Stable across runs, unlike `String.hashCode`.
String fnv1a64(String input) {
  // Native-only (no web target), so 64-bit literals are exact.
  // ignore: avoid_js_rounded_ints
  var hash = 0xcbf29ce484222325;
  for (final unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF;
  }
  String hex32(int v) => (v & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
  return '${hex32(hash >>> 32)}${hex32(hash)}';
}
