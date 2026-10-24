// End-to-end tour on a real device/desktop engine:
//
//   flutter test integration_test -d windows \
//     --dart-define=NOIR_DEMO_DIR=<folder with music> \
//     --dart-define=NOIR_SHOT_DIR=<folder for screenshots>
//
// Without NOIR_DEMO_DIR it generates a few WAV files. Screenshots are only
// written when NOIR_SHOT_DIR is set.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:just_audio_media_kit/just_audio_media_kit.dart';
import 'package:noir/app/app.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/playback.dart';
import 'package:noir/shared/widgets/track_row.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import '../test/helpers/wav.dart';

const _demoDir = String.fromEnvironment('NOIR_DEMO_DIR');
const _shotDir = String.fromEnvironment('NOIR_SHOT_DIR');

final GlobalKey<State<StatefulWidget>> _shotKey = GlobalKey();

Future<void> _shot(WidgetTester tester, String name) async {
  if (_shotDir.isEmpty) return;
  await tester.pump(const Duration(milliseconds: 300));
  await tester.runAsync(() async {
    final boundary =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File(p.join(_shotDir, '$name.png'));
    await file.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
  });
}

/// pumpAndSettle never settles while audio is playing (position ticks).
Future<void> _settle(WidgetTester tester, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 50; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _resize(Size size) async {
  if (!Platform.isWindows && !Platform.isMacOS && !Platform.isLinux) return;
  await windowManager.setMinimumSize(const Size(360, 480));
  await windowManager.setSize(size);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('NOIR tour: library, playback, effects, layouts', (tester) async {
    JustAudioMediaKit.ensureInitialized();
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      await windowManager.ensureInitialized();
      // Same frameless window as the real app (see bootstrap.dart).
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    }
    final tmp = Directory.systemTemp.createTempSync('noir_tour_');
    addTearDown(() => tmp.deleteSync(recursive: true));

    var music = _demoDir;
    if (music.isEmpty) {
      music = p.join(tmp.path, 'music');
      for (final name in ['Dawn', 'Drift', 'Dusk']) {
        writeSineWav(
          File(p.join(music, '$name.wav')),
          duration: const Duration(seconds: 6),
        );
      }
    }

    final dbFile = File(p.join(tmp.path, 'noir.sqlite'));
    final db = AppDatabase(NativeDatabase(dbFile));
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            artwork: Directory(p.join(tmp.path, 'artwork')),
            importedMusic: Directory(p.join(tmp.path, 'imported')),
          ),
        ),
      ],
    );
    // Teardowns run in reverse: providers stop listening before the
    // database closes.
    addTearDown(container.dispose);

    await _resize(const Size(1360, 860));
    await tester.pumpWidget(
      RepaintBoundary(
        key: _shotKey,
        child: UncontrolledProviderScope(
          container: container,
          child: const NoirApp(),
        ),
      ),
    );
    await _settle(tester);

    // 1. First launch shows the welcome card.
    expect(find.text('Bring your music'), findsOneWidget);
    await _shot(tester, '01_first_launch');

    // 2. Index the folder (same code path as "Choose a music folder").
    await tester.runAsync(() async {
      await container.read(libraryRepositoryProvider).addFolder(music);
      await container.read(libraryIndexerProvider).scanFolder(music);
    });
    await _settle(tester, 1500);
    expect(find.text('Bring your music'), findsNothing);
    await _shot(tester, '02_home');

    // 3. Real playback: the position must advance, pause must hold.
    final router = container.read(routerProvider)..go('/library?tab=tracks');
    await _settle(tester);
    await _shot(tester, '03_library_tracks');

    await tester.tap(find.byType(TrackRow).first);
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    await _settle(tester);
    final engine = container.read(playbackEngineProvider);
    final state = container.read(playbackProvider);
    expect(state.current, isNotNull, reason: 'a track should be loaded');
    expect(state.status, PlaybackStatus.playing);
    expect(engine.currentPosition, greaterThan(const Duration(seconds: 1)));

    await container.read(playbackProvider.notifier).pause();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 600)),
    );
    final paused = engine.currentPosition;
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 1)),
    );
    expect(engine.currentPosition, paused);
    await container.read(playbackProvider.notifier).resume();
    await _settle(tester);
    await _shot(tester, '04_library_playing');

    // 4. Albums and album detail.
    router.go('/library?tab=albums');
    await _settle(tester);
    await _shot(tester, '05_library_albums');

    // 5. Search.
    router.go('/search');
    await _settle(tester);
    await tester.enterText(find.byType(TextField).first, 'a');
    await _settle(tester, 1200);
    await _shot(tester, '06_search');

    // 6. Now playing.
    unawaited(router.push('/now-playing'));
    await _settle(tester, 1200);
    await _shot(tester, '07_now_playing');
    router.pop();
    await _settle(tester);

    // 7. Settings, then Liquid Glass off: no backdrop blur anywhere.
    router.go('/settings');
    await _settle(tester);
    await _shot(tester, '08_settings');
    expect(find.byType(BackdropFilter), findsWidgets);
    container
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(liquidGlass: false));
    await _settle(tester);
    expect(find.byType(BackdropFilter), findsNothing);
    router.go('/');
    await _settle(tester);
    await _shot(tester, '09_home_glass_off');

    // 8. Settings persisted.
    final saved = await tester.runAsync(
      () => SettingsRepository(db).loadSettings(),
    );
    expect(saved!.liquidGlass, isFalse);

    // 9. Light theme, glass back on.
    container
        .read(settingsProvider.notifier)
        .update(
          (s) => s.copyWith(liquidGlass: true, themeMode: ThemeMode.light),
        );
    await _settle(tester);
    await _shot(tester, '10_home_light');
    container
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(themeMode: ThemeMode.dark));

    // 10. Narrower windows: rail, then phone-like layout.
    await _resize(const Size(900, 760));
    await _settle(tester, 1000);
    await _shot(tester, '11_medium');
    await _resize(const Size(420, 860));
    await _settle(tester, 1000);
    await _shot(tester, '12_compact');
    await _resize(const Size(1360, 860));
    await _settle(tester);
    await container.read(playbackProvider.notifier).pause();
  });
}
