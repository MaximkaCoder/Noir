import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:package_info_plus/package_info_plus.dart';

final FutureProvider<int> artworkCacheSizeProvider =
    FutureProvider.autoDispose<int>((ref) {
      final dir = ref.watch(appDirectoriesProvider).artwork.path;
      return Isolate.run(() {
        final d = Directory(dir);
        if (!d.existsSync()) return 0;
        return d.listSync().whereType<File>().fold<int>(
          0,
          (sum, f) => sum + f.lengthSync(),
        );
      });
    });

final packageInfoProvider = FutureProvider<PackageInfo>(
  (ref) => PackageInfo.fromPlatform(),
);

/// Deletes extracted artwork and re-extracts it from the library folders.
Future<void> clearArtworkCache(WidgetRef ref) async {
  final dir = ref.read(appDirectoriesProvider).artwork;
  if (dir.existsSync()) await dir.delete(recursive: true);
  await ref.read(libraryRepositoryProvider).resetArtwork();
  ref.invalidate(artworkCacheSizeProvider);
  await ref.read(libraryScanProvider.notifier).rescanAll();
  ref.invalidate(artworkCacheSizeProvider);
}

/// Diagnostics for support. Deliberately excludes file paths, titles, search
/// history, account data and anything else personal.
Future<String> buildDiagnostics(WidgetRef ref) async {
  final info = await ref.read(packageInfoProvider.future);
  final db = ref.read(databaseProvider);
  Future<int> count(String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM $table').getSingle())
          .read<int>('n');
  final settings = ref.read(settingsProvider);
  final report = {
    'app': info.appName,
    'version': info.version,
    'build': info.buildNumber,
    'os': Platform.operatingSystem,
    'osVersion': Platform.operatingSystemVersion,
    'dart': Platform.version.split(' ').first,
    'locale': Platform.localeName,
    'schemaVersion': db.schemaVersion,
    'counts': {
      'tracks': await count('tracks'),
      'playlists': await count('playlists'),
      'folders': await count('library_folders'),
    },
    'settings': settings.toJson(),
  };
  return const JsonEncoder.withIndent('  ').convert(report);
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
