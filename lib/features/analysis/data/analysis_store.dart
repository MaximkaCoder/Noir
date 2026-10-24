import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:noir/features/analysis/domain/track_analysis.dart';
import 'package:path/path.dart' as p;

/// Persists one JSON file per analysed track under `<support>/analysis/`,
/// plus `index.json` (track id → analysis version + source fingerprint) so
/// the queue can skip analysed tracks without opening every file.
///
/// Files instead of a Drift table: no schema migration to coordinate, beat
/// lists (a few KB per track) stay out of the database, and deleting the
/// folder simply re-runs the analysis.
class AnalysisStore {
  AnalysisStore(this.directory);

  final Directory directory;

  Map<String, _IndexEntry>? _index;
  Future<void> _writes = Future.value();

  File _fileFor(String trackId) => File(
    p.join(directory.path, '${sha1.convert(utf8.encode(trackId))}.json'),
  );

  File get _indexFile => File(p.join(directory.path, 'index.json'));

  /// The stored analysis for [trackId], or null (also when unreadable).
  /// Reads synchronously: the file is a few KB.
  Future<TrackAnalysis?> read(String trackId) async {
    final file = _fileFor(trackId);
    try {
      if (!file.existsSync()) return null;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      if (json['trackId'] != trackId) return null;
      return TrackAnalysis.fromJson(
        (json['analysis']! as Map).cast<String, Object?>(),
      );
    } on Object catch (e) {
      debugPrint('Analysis for $trackId unreadable: $e');
      return null;
    }
  }

  /// True when [trackId] was analysed by the current algorithm from a file
  /// with the same [fingerprint] (null skips the fingerprint check).
  Future<bool> isFresh(String trackId, String? fingerprint) async {
    final entry = (await _loadIndex())[trackId];
    return entry != null &&
        entry.version == TrackAnalysis.currentVersion &&
        (fingerprint == null || entry.fingerprint == fingerprint);
  }

  /// Ids of every stored analysis (any version).
  Future<Set<String>> analysedIds() async => (await _loadIndex()).keys.toSet();

  Future<void> write(String trackId, TrackAnalysis analysis) {
    final done = _writes.then((_) async {
      await directory.create(recursive: true);
      await _atomicWrite(
        _fileFor(trackId),
        jsonEncode({'trackId': trackId, 'analysis': analysis.toJson()}),
      );
      final index = await _loadIndex();
      index[trackId] = _IndexEntry(analysis.analysisVersion, analysis.source);
      await _atomicWrite(
        _indexFile,
        jsonEncode({
          for (final MapEntry(:key, :value) in index.entries)
            key: value.toJson(),
        }),
      );
    });
    _writes = done.catchError((Object _) {});
    return done;
  }

  Future<Map<String, _IndexEntry>> _loadIndex() async {
    if (_index case final index?) return index;
    final index = <String, _IndexEntry>{};
    try {
      if (_indexFile.existsSync()) {
        final json =
            jsonDecode(await _indexFile.readAsString()) as Map<String, Object?>;
        for (final MapEntry(:key, :value) in json.entries) {
          index[key] = _IndexEntry.fromJson(
            (value! as Map).cast<String, Object?>(),
          );
        }
      }
    } on Object catch (e) {
      // A corrupt index only costs re-analysis.
      debugPrint('Analysis index unreadable, starting fresh: $e');
    }
    return _index ??= index;
  }

  static Future<void> _atomicWrite(File file, String contents) async {
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(file.path);
  }
}

class _IndexEntry {
  const _IndexEntry(this.version, this.fingerprint);

  factory _IndexEntry.fromJson(Map<String, Object?> json) =>
      _IndexEntry(json['v']! as int, json['fp'] as String?);

  final int version;
  final String? fingerprint;

  Map<String, Object?> toJson() => {'v': version, 'fp': fingerprint};
}
