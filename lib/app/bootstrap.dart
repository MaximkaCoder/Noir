import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:noir/app/app.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/media_session.dart';
import 'package:noir/features/playback/presentation/windows_media_controls.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:window_manager/window_manager.dart';

/// Everything that must happen before the first frame: native audio init,
/// window chrome, database, and persisted settings (so the first frame
/// already has the right theme and effects).
///
/// [overrides] lets an alternative entrypoint plug optional modules in.
Future<void> bootstrap({List<Override> overrides = const []}) async {
  WidgetsFlutterBinding.ensureInitialized();
  _registerLicenses();

  // just_audio has no Windows/Linux backend of its own; media_kit fills in.
  JustAudioMediaKit.ensureInitialized();

  if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
    await _setUpWindow();
  }

  final db = AppDatabase.open();
  final settings = await SettingsRepository(db).loadSettings();
  final dirs = await AppDirectories.resolve();

  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      initialSettingsProvider.overrideWithValue(settings),
      appDirectoriesProvider.overrideWithValue(dirs),
      ...overrides,
    ],
  );

  if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
    await startMediaSession(container);
  }
  if (Platform.isWindows) startWindowsMediaControls(container);
  unawaited(container.read(playbackProvider.notifier).restoreSession());
  // Keeps YouTube sync alive for the app's lifetime (Riverpod pauses
  // providers nobody listens to).
  container.listen(youTubeSyncProvider, (_, _) {});

  runApp(
    UncontrolledProviderScope(container: container, child: const NoirApp()),
  );
}

Future<void> _setUpWindow() async {
  await windowManager.ensureInitialized();
  const options = WindowOptions(
    size: Size(1360, 860),
    minimumSize: Size(720, 520),
    center: true,
    title: 'NOIR',
    backgroundColor: Color(0xFF090909),
    titleBarStyle: TitleBarStyle.hidden,
    windowButtonVisibility: true, // macOS keeps native traffic lights.
  );
  await windowManager.waitUntilReadyToShow(options, () async {
    await windowManager.show();
    await windowManager.focus();
  });
}

void _registerLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString('assets/fonts/Inter-LICENSE.txt');
    yield LicenseEntryWithLineBreaks(['Inter'], text);
  });
}
