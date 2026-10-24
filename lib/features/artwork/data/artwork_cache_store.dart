import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';

/// Where resolved YouTube artwork survives restarts.
abstract interface class ArtworkCacheStore {
  /// Saved entries, oldest first; empty when there is nothing (readable).
  Future<Map<String, ResolvedArt>> load();

  Future<void> save(Map<String, ResolvedArt> entries);
}

/// A small JSON file in the app support directory. Deliberately not the
/// app database: it is a disposable cache, and losing it only costs a few
/// lookups. Never throws.
class JsonFileArtworkCacheStore implements ArtworkCacheStore {
  JsonFileArtworkCacheStore(this._file);

  /// Resolved lazily: the directory comes from a platform channel.
  final Future<File> Function() _file;

  static const _version = 1;

  @override
  Future<Map<String, ResolvedArt>> load() async {
    try {
      final file = await _file();
      if (!file.existsSync()) return {};
      final json = jsonDecode(await file.readAsString());
      if (json is! Map || json['version'] != _version) return {};
      final entries = json['entries'];
      if (entries is! Map) return {};
      return {
        for (final e in entries.entries)
          if (e.key is String) e.key as String: ?ResolvedArt.fromJson(e.value),
      };
    } on Object catch (e) {
      debugPrint('Artwork cache unreadable: $e');
      return {};
    }
  }

  @override
  Future<void> save(Map<String, ResolvedArt> entries) async {
    try {
      final file = await _file();
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(
        jsonEncode({
          'version': _version,
          'entries': {for (final e in entries.entries) e.key: e.value.toJson()},
        }),
        flush: true,
      );
      await tmp.rename(file.path);
    } on Object catch (e) {
      debugPrint('Artwork cache not saved: $e');
    }
  }
}
