import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/settings/domain/app_settings.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

/// Persists small JSON documents (settings, playback session) in the
/// `key_values` table.
class SettingsRepository {
  SettingsRepository(this._db);

  final AppDatabase _db;

  static const _settingsKey = 'app_settings';

  Future<AppSettings> loadSettings() async {
    final json = await readJson(_settingsKey);
    if (json == null) return const AppSettings();
    try {
      return AppSettings.fromJson(migrateSettingsJson(json));
    } on Object catch (e) {
      // Corrupted or incompatible settings must never block startup.
      debugPrint('Settings could not be read, using defaults: $e');
      return const AppSettings();
    }
  }

  /// Settings saved before transitions had a mode used `crossfadeSeconds`
  /// = 0 for "off".
  @visibleForTesting
  static Map<String, Object?> migrateSettingsJson(Map<String, Object?> json) {
    if (json.containsKey('transitionMode')) return json;
    final seconds = json['crossfadeSeconds'];
    final fading = seconds is int && seconds > 0;
    return {
      ...json,
      'transitionMode': fading ? 'crossfade' : 'off',
      'crossfadeSeconds': fading ? seconds : 6,
    };
  }

  Future<void> saveSettings(AppSettings settings) =>
      writeJson(_settingsKey, settings.toJson());

  Future<Map<String, Object?>?> readJson(String key) async {
    final row = await (_db.select(
      _db.keyValues,
    )..where((t) => t.key.equals(key))).getSingleOrNull();
    if (row == null) return null;
    try {
      return jsonDecode(row.value) as Map<String, Object?>;
    } on FormatException {
      return null;
    }
  }

  Future<void> writeJson(String key, Map<String, Object?> value) => _db
      .into(_db.keyValues)
      .insertOnConflictUpdate(
        KeyValuesCompanion.insert(key: key, value: jsonEncode(value)),
      );

  Future<void> delete(String key) =>
      (_db.delete(_db.keyValues)..where((t) => t.key.equals(key))).go();
}
