import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/app.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

import 'fake_engine.dart';
import 'fake_innertube_client.dart';
import 'test_database.dart';

/// Pumps the full app (router, shell, theme) over an in-memory database and
/// a fake audio engine, at a given window size.
class TestApp {
  TestApp._(this.db, this.engine, this.innerTube, this.container);

  final AppDatabase db;
  final FakeEngine engine;

  /// YouTube Music stand-in; by default an empty home feed. Tests never
  /// reach the network.
  final FakeInnerTubeClient innerTube;
  final ProviderContainer container;

  static Future<TestApp> pump(
    WidgetTester tester, {
    Size size = const Size(1360, 860),
    AppSettings settings = const AppSettings(),
    bool withMusic = true,
    double textScale = 1,
    FakeInnerTubeClient? innerTube,
  }) async {
    tester.view
      ..physicalSize = size
      ..devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

    final db = inMemoryDatabase();
    final engine = FakeEngine();
    final ytm = innerTube ?? FakeInnerTubeClient();
    final tmp = Directory.systemTemp.createTempSync('noir_widget_');
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        innerTubeClientProvider.overrideWithValue(ytm),
        initialSettingsProvider.overrideWithValue(settings),
        // No YouTube Music lookups in widget tests: thumbnails stay.
        artworkResolverProvider.overrideWithValue(ArtworkResolver.offline()),
        appDirectoriesProvider.overrideWithValue(
          AppDirectories(
            artwork: Directory('${tmp.path}/artwork'),
            importedMusic: Directory('${tmp.path}/imported'),
          ),
        ),
      ],
    );
    if (withMusic) {
      await LibraryRepository(db).upsertScanned([
        trackRow(
          'a.mp3',
          title: 'Ash & Ember',
          artist: 'Mara Vale',
          album: 'Low Light',
          trackNumber: 1,
        ),
        trackRow(
          'b.mp3',
          title: 'Quiet Harbor',
          artist: 'Mara Vale',
          album: 'Low Light',
          trackNumber: 2,
        ),
        trackRow(
          'c.mp3',
          title: 'Signal',
          artist: 'Kei Aoto',
          album: 'Northern Static',
          trackNumber: 1,
        ),
      ]);
    }
    await tester.pumpWidget(
      UncontrolledProviderScope(container: container, child: const NoirApp()),
    );
    await tester.pumpAndSettle();

    addTearDown(() async {
      // Unmount first so stream queries stop before the database closes.
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      await db.close();
      tmp.deleteSync(recursive: true);
    });
    return TestApp._(db, engine, ytm, container);
  }
}
