import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:noir/core/database/app_database.dart';

AppDatabase inMemoryDatabase() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  return AppDatabase(NativeDatabase.memory());
}

/// Minimal valid row for a local track.
TracksCompanion trackRow(
  String path, {
  String? title,
  String? artist,
  String? album,
  int? trackNumber,
  int durationMs = 180000,
  String? artworkPath,
}) => TracksCompanion.insert(
  path: path,
  title: title ?? path.split(r'\').last,
  artist: Value(artist),
  album: Value(album),
  trackNumber: Value(trackNumber),
  durationMs: Value(durationMs),
  artworkPath: Value(artworkPath),
  fileSize: 1000,
  modifiedAt: DateTime(2026),
  addedAt: DateTime(2026),
);
