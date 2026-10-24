import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/app.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

import '../helpers/fake_engine.dart';
import '../helpers/fake_http.dart';
import '../helpers/test_database.dart';

const synced =
    '[00:01.00] First line\n[00:05.00] Second line\n'
    '[00:09.00] Third line';

/// The full app with a fake engine and fake network, playing two local
/// tracks, with Now Playing open.
Future<({ProviderContainer container, FakeEngine engine, FakeHttp http})>
pumpNowPlaying(
  WidgetTester tester, {
  Size size = const Size(1360, 860),
  double textScale = 1,
  FakeReply Function(FakeRequest request)? lrclib,
}) async {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);

  final db = inMemoryDatabase();
  final engine = FakeEngine();
  final http = FakeHttp(
    lrclib ??
        (_) => ok({
          'id': 1,
          'trackName': 'Ash & Ember',
          'artistName': 'Mara Vale',
          'duration': 180,
          'instrumental': false,
          'plainLyrics': 'First line\nSecond line\nThird line',
          'syncedLyrics': synced,
        }),
  );
  final tmp = Directory.systemTemp.createTempSync('noir_np_');
  final container = ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      playbackEngineProvider.overrideWithValue(engine),
      initialSettingsProvider.overrideWithValue(const AppSettings()),
      httpClientProvider.overrideWithValue(http.dio()),
      appDirectoriesProvider.overrideWithValue(
        AppDirectories(
          artwork: Directory('${tmp.path}/artwork'),
          importedMusic: Directory('${tmp.path}/imported'),
        ),
      ),
    ],
  );
  await LibraryRepository(db).upsertScanned([
    trackRow('a.mp3', title: 'Ash & Ember', artist: 'Mara Vale'),
    trackRow('b.mp3', title: 'Quiet Harbor', artist: 'Mara Vale'),
  ]);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const NoirApp()),
  );
  await tester.pumpAndSettle();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  final rows = await db.select(db.tracks).get();
  rows.sort((a, b) => a.path.compareTo(b.path));
  await container.read(playbackProvider.notifier).playTracks([
    for (final r in rows) r.toTrack(),
  ]);
  unawaited(container.read(routerProvider).push<void>('/now-playing'));
  await tester.pumpAndSettle();
  expect(find.byTooltip('Close player (Esc)'), findsOneWidget);
  return (container: container, engine: engine, http: http);
}

void main() {
  group('queue sheet', () {
    testWidgets('no inline "Up next" card; the queue button opens a sheet', (
      tester,
    ) async {
      await pumpNowPlaying(tester);
      expect(find.text('Up next'), findsNothing);

      await tester.tap(_nowPlayingQueue);
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsOneWidget);
      expect(find.byTooltip('Close queue (Esc)'), findsOneWidget);
      // Slid in at the right edge, at most 400 px wide.
      final sheet = tester.getRect(
        find
            .ancestor(
              of: find.text('Up next'),
              matching: find.byType(GlassSurface),
            )
            .first,
      );
      expect(sheet.right, 1360);
      expect(sheet.width, lessThanOrEqualTo(400));

      // Esc closes the sheet only; the player stays.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsNothing);
      expect(find.byTooltip('Close player (Esc)'), findsOneWidget);
    });

    testWidgets('maybePop closes the sheet first, then the player', (
      tester,
    ) async {
      final app = await pumpNowPlaying(tester);
      final navigator = app.container
          .read(routerProvider)
          .routerDelegate
          .navigatorKey;

      await tester.tap(_nowPlayingQueue);
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsOneWidget);

      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsNothing);
      expect(find.byTooltip('Close player (Esc)'), findsOneWidget);

      await navigator.currentState!.maybePop();
      await tester.pumpAndSettle();
      expect(find.byTooltip('Close player (Esc)'), findsNothing);
    });

    testWidgets('tapping outside closes the sheet', (tester) async {
      await pumpNowPlaying(tester);
      await tester.tap(_nowPlayingQueue);
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(200, 400));
      await tester.pumpAndSettle();
      expect(find.text('Up next'), findsNothing);
      expect(find.byTooltip('Close player (Esc)'), findsOneWidget);
    });
  });

  group('lyrics', () {
    Color colorOf(WidgetTester tester, String line) => tester
        .widget<AnimatedDefaultTextStyle>(
          find
              .ancestor(
                of: find.text(line),
                matching: find.byType(AnimatedDefaultTextStyle),
              )
              .first,
        )
        .style
        .color!;

    testWidgets('synced lines follow playback; tapping a line seeks', (
      tester,
    ) async {
      final app = await pumpNowPlaying(tester);
      expect(app.http.requests, isEmpty, reason: 'nothing sent until shown');

      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(app.container.read(lyricsVisibleProvider), isTrue);
      expect(find.text('Second line'), findsOneWidget);
      expect(find.text('Lyrics from LRCLIB'), findsOneWidget);
      final query = app.http.requests.first.uri.queryParameters;
      expect(query['track_name'], 'Ash & Ember');
      expect(query['artist_name'], 'Mara Vale');

      app.engine.tick(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(colorOf(tester, 'Second line').a, 1);
      expect(colorOf(tester, 'First line').a, lessThan(1));
      expect(
        colorOf(tester, 'Third line').a,
        lessThan(colorOf(tester, 'First line').a),
      );

      await tester.tap(find.text('Third line'));
      await tester.pumpAndSettle();
      expect(app.engine.calls, contains('seek 9'));
      expect(colorOf(tester, 'Third line').a, 1);

      // Toggling off restores the cover layout.
      await tester.tap(find.byTooltip('Hide lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Second line'), findsNothing);
    });

    testWidgets('narrow windows show lyrics in place of the cover', (
      tester,
    ) async {
      await pumpNowPlaying(tester, size: const Size(600, 900));
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('First line'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(NowPlayingScreen),
          matching: find.byType(Hero),
        ),
        findsNothing,
      );
    });

    testWidgets('says when there are none', (tester) async {
      await pumpNowPlaying(
        tester,
        lrclib: (r) => r.uri.path.endsWith('/get')
            ? error(404, {'name': 'TrackNotFound'})
            : ok(<Object>[]),
      );
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('No lyrics found'), findsOneWidget);
    });

    testWidgets('network errors offer a retry', (tester) async {
      final app = await pumpNowPlaying(tester, lrclib: (_) => error(500, {}));
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load lyrics"), findsOneWidget);

      app.http.handler = (_) => ok({
        'trackName': 'Ash & Ember',
        'artistName': 'Mara Vale',
        'duration': 180,
        'instrumental': true,
      });
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Instrumental'), findsOneWidget);
    });
  });

  // Medium widths (640–1080) are left out: the shell's player bar under
  // this screen overflows there by itself, at any text size.
  for (final (size, scale) in const [
    (Size(400, 800), 2.0),
    (Size(1360, 860), 2.0),
    (Size(1100, 600), 1.0),
  ]) {
    testWidgets('fits at ${size.width}x${size.height}, text ${scale}x', (
      tester,
    ) async {
      await pumpNowPlaying(tester, size: size, textScale: scale);
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      await tester.tap(_nowPlayingQueue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }
}

/// The Now Playing queue button (the shell's player island has one too).
final _nowPlayingQueue = find.descendant(
  of: find.byType(NowPlayingScreen),
  matching: find.byTooltip('Queue'),
);
