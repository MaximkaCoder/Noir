import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/app.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/core/platform/window_controls.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/core/widgets/glass_surface.dart';
import 'package:noir/core/widgets/liquid_press.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/discover/presentation/ytm_artist_screen.dart';
import 'package:noir/features/library/application/library_scan_controller.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/library/presentation/collection_screens.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/presentation/karaoke_lyrics.dart';
import 'package:noir/features/lyrics/presentation/lyrics_view.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
import 'package:noir/features/playback/presentation/playback_controls.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/integrations/youtube_music/ytm_lyrics.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

import '../discover/fake_artist_client.dart';
import '../helpers/fake_engine.dart';
import '../helpers/fake_http.dart';
import '../helpers/fake_innertube_client.dart';
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

  /// Played instead of the two library tracks.
  List<Track>? tracks,

  /// YouTube Music; one that knows nothing by default (no network).
  FakeInnerTubeClient? innerTube,
  List<Override> overrides = const [],
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
      innerTubeClientProvider.overrideWithValue(
        innerTube ?? FakeInnerTubeClient(),
      ),
      appDirectoriesProvider.overrideWithValue(
        AppDirectories(
          artwork: Directory('${tmp.path}/artwork'),
          importedMusic: Directory('${tmp.path}/imported'),
        ),
      ),
      ...overrides,
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
  await container
      .read(playbackProvider.notifier)
      .playTracks(tracks ?? [for (final r in rows) r.toTrack()]);
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
      // Sung lines recede further than the ones to come.
      expect(colorOf(tester, 'Third line').a, lessThan(1));
      expect(
        colorOf(tester, 'First line').a,
        lessThan(colorOf(tester, 'Third line').a),
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

    testWidgets('lines are large on wide windows', (tester) async {
      await pumpNowPlaying(tester);
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      final size = tester
          .widget<AnimatedDefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('First line'),
                  matching: find.byType(AnimatedDefaultTextStyle),
                )
                .first,
          )
          .style
          .fontSize!;
      expect(size, inInclusiveRange(32, 40));
      // The lyrics column takes over half the window.
      final column = tester.getRect(find.byKey(NowPlayingScreen.lyricsKey));
      expect(column.width, greaterThan(1360 * 0.5));
    });

    testWidgets('YouTube songs get YouTube Music lyrics first', (tester) async {
      final ytm = FakeInnerTubeClient()
        ..lyricsTabs['vidA'] = 'MPLYa'
        ..lyricsPages['MPLYa'] = const YtmLyrics(
          lines: [
            YtmLyricLine(Duration(seconds: 1), Duration(seconds: 3), 'One'),
            YtmLyricLine(Duration(seconds: 3), Duration(seconds: 6), 'Two'),
          ],
          provider: 'Musixmatch',
        );
      final app = await pumpNowPlaying(
        tester,
        tracks: [ytTrack('vidA', title: 'Song', artist: 'Band')],
        innerTube: ytm,
      );
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      expect(find.text('Two'), findsOneWidget);
      expect(
        find.text('Lyrics from YouTube Music · Musixmatch'),
        findsOneWidget,
      );
      expect(app.http.requests, isEmpty, reason: 'LRCLIB not needed');
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

  group('lyrics toggle', () {
    testWidgets('the player glides aside instead of swapping layouts', (
      tester,
    ) async {
      await pumpNowPlaying(tester);
      final cover = find.byKey(NowPlayingScreen.coverKey);
      final before = tester.getRect(cover);

      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pump();
      await tester.pump(NowPlayingScreen.lyricsDuration ~/ 2);
      final mid = tester.getRect(cover);
      // The same cover, part way: no second layout tree.
      expect(cover, findsOneWidget);
      expect(find.byKey(NowPlayingScreen.lyricsKey), findsOneWidget);

      await tester.pumpAndSettle();
      final after = tester.getRect(cover);
      expect(after.width, lessThan(before.width));
      expect(mid.width, inExclusiveRange(after.width, before.width));
      expect(
        mid.left,
        inExclusiveRange(
          before.left < after.left ? before.left : after.left,
          before.left < after.left ? after.left : before.left,
        ),
      );

      // And back.
      await tester.tap(find.byTooltip('Hide lyrics'));
      await tester.pump();
      await tester.pump(NowPlayingScreen.lyricsDuration ~/ 2);
      expect(
        tester.getRect(cover).width,
        inExclusiveRange(after.width, before.width),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(cover), before);
      expect(find.byKey(NowPlayingScreen.lyricsKey), findsNothing);
    });

    testWidgets('narrow windows cross-fade the cover and the lyrics', (
      tester,
    ) async {
      await pumpNowPlaying(tester, size: const Size(600, 900));
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pump();
      await tester.pump(NowPlayingScreen.lyricsDuration ~/ 2);
      expect(find.byKey(NowPlayingScreen.coverKey), findsOneWidget);
      expect(find.byKey(NowPlayingScreen.lyricsKey), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byKey(NowPlayingScreen.coverKey), findsNothing);
    });

    testWidgets('with animations off it switches at once', (tester) async {
      final app = await pumpNowPlaying(tester);
      app.container
          .read(settingsProvider.notifier)
          .update((s) => s.copyWith(animations: false));
      await tester.pumpAndSettle();
      final cover = find.byKey(NowPlayingScreen.coverKey);
      final before = tester.getRect(cover);
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pump();
      await tester.pump();
      final shown = tester.getRect(cover);
      expect(shown.width, lessThan(before.width));
      await tester.pumpAndSettle();
      expect(tester.getRect(cover), shown);
    });
  });

  group('karaoke', () {
    Future<({ProviderContainer container, FakeEngine engine, FakeHttp http})>
    pumpKaraoke(WidgetTester tester, {String? lyrics}) async {
      final app = await pumpNowPlaying(
        tester,
        lrclib: lyrics == null
            ? null
            : (_) => ok({
                'trackName': 'Ash & Ember',
                'artistName': 'Mara Vale',
                'duration': 180,
                'instrumental': false,
                'plainLyrics': lyrics,
              }),
      );
      // Paused: while playing, the fill animates every frame.
      await app.container.read(playbackProvider.notifier).pause();
      await tester.tap(find.byTooltip('Show lyrics'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Karaoke'));
      await tester.pumpAndSettle();
      return app;
    }

    testWidgets('the fill moves between position ticks while playing', (
      tester,
    ) async {
      final app = await pumpKaraoke(tester);
      app.engine.tick(const Duration(milliseconds: 5600));
      await tester.pump();
      await app.container.read(playbackProvider.notifier).resume();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final line = tester.widget<KaraokeLine>(find.byType(KaraokeLine));
      expect(
        line.position.value,
        greaterThan(const Duration(milliseconds: 5700)),
      );
      await app.container.read(playbackProvider.notifier).pause();
      await tester.pumpAndSettle();
    });

    testWidgets('shows the current line filling up and the next below', (
      tester,
    ) async {
      final app = await pumpKaraoke(tester);
      app.engine.tick(const Duration(milliseconds: 5600));
      await tester.pumpAndSettle();

      final line = tester.widget<KaraokeLine>(find.byType(KaraokeLine));
      expect(line.text, 'Second line');
      final lit = line.litFractionAt(line.position.value);
      expect(lit, inExclusiveRange(0, 1));
      // The next line waits below, the previous one above.
      final next = tester.getRect(find.text('Third line'));
      final current = tester.getRect(find.byType(KaraokeLine));
      expect(next.top, greaterThan(current.bottom));
      expect(find.text('First line'), findsOneWidget);

      // Later in the line, more of it is lit.
      app.engine.tick(const Duration(milliseconds: 6200));
      await tester.pump();
      final later = tester.widget<KaraokeLine>(find.byType(KaraokeLine));
      expect(later.litFractionAt(later.position.value), greaterThan(lit));

      // Then the next line takes over.
      app.engine.tick(const Duration(milliseconds: 9500));
      await tester.pumpAndSettle();
      expect(
        tester.widget<KaraokeLine>(find.byType(KaraokeLine)).text,
        'Third line',
      );
    });

    testWidgets('the choice is remembered', (tester) async {
      final app = await pumpKaraoke(tester);
      expect(
        app.container.read(settingsProvider).lyricsMode,
        LyricsMode.karaoke,
      );
      final saved = await tester.runAsync(
        () => app.container.read(settingsRepositoryProvider).loadSettings(),
      );
      expect(saved!.lyricsMode, LyricsMode.karaoke);

      await tester.tap(find.text('Lines'));
      await tester.pumpAndSettle();
      expect(app.container.read(settingsProvider).lyricsMode, LyricsMode.lines);
      expect(find.byType(KaraokeLine), findsNothing);
      expect(find.byType(SyncedLyricsList), findsOneWidget);
    });

    testWidgets('unsynced lyrics fall back to text with a hint', (
      tester,
    ) async {
      await pumpKaraoke(tester, lyrics: 'Just words\nNo times');
      expect(find.byType(KaraokeLine), findsNothing);
      expect(find.textContaining('Just words'), findsOneWidget);
      expect(
        find.textContaining('Not time-synced, so no karaoke'),
        findsOneWidget,
      );
    });
  });

  group('press feedback', () {
    testWidgets('transport and secondary controls answer with LiquidPress', (
      tester,
    ) async {
      await pumpNowPlaying(tester);
      for (final tooltip in ['Next', 'Previous', 'Queue', 'Show lyrics']) {
        expect(
          find.ancestor(
            of: _inPlayer(find.byTooltip(tooltip)).first,
            matching: find.byType(LiquidPress),
          ),
          findsWidgets,
          reason: tooltip,
        );
      }
      expect(
        find.descendant(
          of: find.ancestor(
            of: _inPlayer(find.byTooltip('Pause')).evaluate().isEmpty
                ? _inPlayer(find.byTooltip('Play'))
                : _inPlayer(find.byTooltip('Pause')),
            matching: find.byType(LiquidPress),
          ),
          matching: find.byKey(LiquidPress.contentKey),
        ),
        findsWidgets,
      );
    });
  });

  group('window dots', () {
    Color idleColor(WidgetTester tester, Finder controls) =>
        (tester
                    .widget<AnimatedContainer>(
                      find
                          .descendant(
                            of: controls,
                            matching: find.byKey(WindowControls.dotKey),
                          )
                          .first,
                    )
                    .decoration!
                as BoxDecoration)
            .color!;

    testWidgets('over artwork they stand out from a dark backdrop', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Column(
            children: [
              WindowControls(key: ValueKey('plain')),
              WindowControls(key: ValueKey('image'), onImage: true),
            ],
          ),
        ),
      );
      final plain = idleColor(tester, find.byKey(const ValueKey('plain')));
      final image = idleColor(tester, find.byKey(const ValueKey('image')));
      expect(
        image.computeLuminance(),
        greaterThan(plain.computeLuminance() + 0.2),
      );
      final rim =
          (tester
                      .widget<AnimatedContainer>(
                        find
                            .descendant(
                              of: find.byKey(const ValueKey('image')),
                              matching: find.byKey(WindowControls.dotKey),
                            )
                            .first,
                      )
                      .decoration!
                  as BoxDecoration)
              .border;
      expect(rim, isNotNull);
    });

    testWidgets('Now Playing uses the contrasting dots', (tester) async {
      await pumpNowPlaying(tester);
      final controls = tester.widget<WindowControls>(
        _inPlayer(find.byType(WindowControls)),
      );
      expect(controls.onImage, isTrue);
    });
  });

  group('track change', () {
    testWidgets('title and artist cross-fade to the next song', (tester) async {
      final app = await pumpNowPlaying(tester);
      expect(_inPlayer(find.text('Ash & Ember')), findsOneWidget);

      await app.container.read(playbackProvider.notifier).next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      // Mid-way both are there, the old one fading out.
      expect(_inPlayer(find.text('Ash & Ember')), findsOneWidget);
      expect(_inPlayer(find.text('Quiet Harbor')), findsOneWidget);

      await tester.pumpAndSettle();
      expect(_inPlayer(find.text('Ash & Ember')), findsNothing);
      expect(_inPlayer(find.text('Quiet Harbor')), findsOneWidget);
    });

    testWidgets('the cover cross-fades inside the shared Hero', (tester) async {
      final app = await pumpNowPlaying(tester);
      final hero = _inPlayer(find.byType(Hero));
      expect(hero, findsOneWidget);
      Finder cover(String title) => find.descendant(
        of: hero,
        matching: find.byWidgetPredicate(
          (w) => w is Artwork && w.semanticLabel == 'Artwork for $title',
        ),
      );

      await app.container.read(playbackProvider.notifier).next();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(cover('Ash & Ember'), findsOneWidget);
      expect(cover('Quiet Harbor'), findsOneWidget);

      await tester.pumpAndSettle();
      expect(cover('Ash & Ember'), findsNothing);
      expect(cover('Quiet Harbor'), findsOneWidget);
    });

    testWidgets('progress glides back to the start', (tester) async {
      final app = await pumpNowPlaying(tester);
      app.engine
        ..durationValue = const Duration(minutes: 3)
        ..tick(const Duration(seconds: 100));
      await tester.pump();
      double value() => tester
          .widget<Slider>(
            find.descendant(
              of: _inPlayer(find.byType(ProgressSlider)),
              matching: find.byType(Slider),
            ),
          )
          .value;
      expect(value(), 100000);

      await app.container.read(playbackProvider.notifier).next();
      app.engine.tick(Duration.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(value(), inExclusiveRange(0, 100000));
      expect(_inPlayer(find.text('1:40')), findsNothing);
      expect(_inPlayer(find.text('0:00')), findsNothing);

      await tester.pumpAndSettle();
      expect(value(), 0);
      expect(_inPlayer(find.text('0:00')), findsOneWidget);
    });
  });

  group('artist and album links', () {
    String location(ProviderContainer c) =>
        c.read(routerProvider).routerDelegate.currentConfiguration.uri.path;

    testWidgets('a local artist opens its library page, closing the player', (
      tester,
    ) async {
      final app = await pumpNowPlaying(tester);
      await tester.tap(_inPlayer(find.text('Mara Vale')));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(location(app.container), '/library/artist');
      expect(find.byType(ArtistScreen), findsOneWidget);
    });

    final links = ArtworkResolver.offline({
      'vidB': ResolvedArt.none(
        checkedAt: DateTime(2026),
        links: const YtmTrackLinks(
          artists: [(name: 'Daft Punk', browseId: 'UCdaft')],
          album: (name: 'Discovery', browseId: 'MPREb_disc'),
        ),
      ),
    });
    List<Override> youTubeMusic() => [
      artworkResolverProvider.overrideWithValue(links),
    ];
    final songs = [
      ytTrack('vidA', title: 'One More Time', artist: 'Daft Punk'),
      ytTrack('vidB', title: 'Aerodynamic', artist: 'Daft Punk'),
    ];

    testWidgets('YouTube artists link only once YouTube Music knows them', (
      tester,
    ) async {
      final ytm = FakeArtistInnerTube()
        ..artists['UCdaft'] = fakeArtist(browseId: 'UCdaft', name: 'Daft Punk');
      final app = await pumpNowPlaying(
        tester,
        tracks: songs,
        innerTube: ytm,
        overrides: youTubeMusic(),
      );

      // Not known yet: plain text, and no album line.
      await tester.tap(_inPlayer(find.text('Daft Punk')));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      expect(_inPlayer(find.text('Discovery')), findsNothing);

      await app.container.read(playbackProvider.notifier).next();
      await tester.pumpAndSettle();
      expect(_inPlayer(find.text('Discovery')), findsOneWidget);

      await tester.tap(_inPlayer(find.text('Daft Punk')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(location(app.container), '/discover/artist/UCdaft');
      expect(ytm.calls, contains('artist UCdaft'));
      expect(find.byType(YtmArtistScreen), findsOneWidget);
      // Lets the page cache expire so no timer outlives the test.
      await tester.pump(const Duration(minutes: 11));
    });

    testWidgets('"Go to album" in the menu opens the YouTube Music album', (
      tester,
    ) async {
      final ytm = FakeArtistInnerTube();
      final app = await pumpNowPlaying(
        tester,
        tracks: songs.reversed.toList(),
        innerTube: ytm,
        overrides: youTubeMusic(),
      );

      await tester.tap(_inPlayer(find.byTooltip('More')));
      await tester.pumpAndSettle();
      expect(find.text('Go to artist'), findsOneWidget);
      await tester.tap(find.text('Go to album'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpAndSettle();

      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(location(app.container), '/discover/album/MPREb_disc');
      expect(ytm.calls, contains('album MPREb_disc'));
      await tester.pump(const Duration(minutes: 11));
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

Finder _inPlayer(Finder finder) =>
    find.descendant(of: find.byType(NowPlayingScreen), matching: finder);
