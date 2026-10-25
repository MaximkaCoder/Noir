import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/widgets/shelf_row.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/features/home/application/pinned_playlists.dart';
import 'package:noir/features/home/presentation/home_screen.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/library/presentation/library_screen.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/widgets/media_tiles.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';

Future<void> _play(TestApp app) async {
  final rows = await app.db.select(app.db.tracks).get();
  await app.container.read(playbackProvider.notifier).playTracks([
    for (final r in rows) r.toTrack(),
  ]);
}

/// One of everything: a local playlist, a favorite, a YouTube like and two
/// YouTube playlists; Favorites and "Gym" pinned (Gym last, so first).
Future<void> _seedCollections(TestApp app) async {
  await PlaylistRepository(app.db).create('Road Trip');
  final track = await app.db.select(app.db.tracks).get();
  await LibraryRepository(app.db).setFavorite(track.first.id, favorite: true);
  final youtube = YouTubeRepository(app.db);
  await youtube.saveLikes(const [
    YtVideo(
      id: 'm1',
      title: 'Ash & Ember (Official Audio)',
      channelTitle: 'Mara Vale - Topic',
      categoryId: '10',
    ),
  ]);
  await youtube.savePlaylists(const [
    YtPlaylist(id: 'PLc', title: 'Chill', itemCount: 4, etag: 'e1'),
    YtPlaylist(id: 'PLg', title: 'Gym', itemCount: 9, etag: 'e2'),
  ]);
  app.container.read(pinnedProvider.notifier)
    ..toggle(PinnedRef.favorites)
    ..toggle(const PinnedRef(PinKind.youtube, 'PLg'));
}

FakeInnerTubeClient _feed() => FakeInnerTubeClient()
  ..homePage = YtmHomePage(
    chips: [
      for (final mood in ['Relax', 'Focus', 'Workout', 'Energize', 'Sleep'])
        YtmChip(title: mood, params: 'P_$mood'),
    ],
    shelves: [
      YtmShelf(
        title: 'Quick picks',
        items: [
          for (var i = 0; i < 12; i++)
            YtmTrackItem(ytTrack('v$i', title: 'Song $i')),
        ],
      ),
    ],
  );

Finder _onHome(String text) =>
    find.descendant(of: find.byType(HomeScreen), matching: find.text(text));

Finder _row(String title) =>
    find.ancestor(of: find.text(title), matching: find.byType(ShelfRow));

List<String> _tiles(WidgetTester tester, Finder row) => [
  for (final t in tester.widgetList<MediaTile>(
    find.descendant(of: row, matching: find.byType(MediaTile)),
  ))
    t.title,
];

void main() {
  group('Home', () {
    testWidgets('no shuffle card, no hero, no local music', (tester) async {
      final app = await TestApp.pump(tester);
      await _play(app);
      await tester.pumpAndSettle();
      final home = find.byType(HomeScreen);
      expect(home, findsOneWidget);
      for (final gone in [
        'Shuffle library',
        'Recently played',
        'Albums',
        'Bring your music',
      ]) {
        expect(
          find.descendant(of: home, matching: find.text(gone)),
          findsNothing,
          reason: gone,
        );
      }
      expect(find.textContaining('now playing'), findsNothing);
      expect(
        find.bySemanticsLabel(RegExp('^Continue listening')),
        findsNothing,
      );
      expect(find.text("Here's what's playing today."), findsOneWidget);
    });

    testWidgets('an empty library gets no import pitch on Home', (
      tester,
    ) async {
      await TestApp.pump(tester, withMusic: false);
      expect(find.text("Here's what's playing today."), findsOneWidget);
      expect(find.text('Bring your music'), findsNothing);
      expect(find.text('Choose a music folder'), findsNothing);
      expect(find.text('Your playlists'), findsNothing, reason: 'none yet');
    });

    testWidgets('"Your playlists": pinned, liked, favorites, local, YouTube', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      await _seedCollections(app);
      await tester.pumpAndSettle();
      expect(_tiles(tester, _row('Your playlists')), [
        'Gym',
        'Favorites',
        'Liked music',
        'Road Trip',
        'Chill',
      ]);

      await tester.tap(_onHome('Road Trip'));
      await tester.pumpAndSettle();
      expect(
        app.container.read(routerProvider).state.uri.path,
        startsWith('/library/playlist/'),
      );
    });

    testWidgets('right-click unpins (and pins) a collection', (tester) async {
      final app = await TestApp.pump(tester);
      await _seedCollections(app);
      await tester.pumpAndSettle();

      await tester.tap(
        _onHome('Gym'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unpin from Home'));
      await tester.pumpAndSettle();
      expect(_tiles(tester, _row('Your playlists')), [
        'Favorites',
        'Liked music',
        'Road Trip',
        'Chill',
        'Gym',
      ]);
      expect(
        app.container.read(pinnedProvider),
        isNot(contains(const PinnedRef(PinKind.youtube, 'PLg'))),
      );

      await tester.tap(
        _onHome('Chill'),
        buttons: kSecondaryButton,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Pin to Home'));
      await tester.pumpAndSettle();
      expect(_tiles(tester, _row('Your playlists')).first, 'Chill');
    });

    testWidgets('Discover shelves and mood chips are ShelfRows', (
      tester,
    ) async {
      await TestApp.pump(tester, innerTube: _feed());
      expect(_row('Relax'), findsOneWidget);
      expect(_row('Quick picks'), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsNothing);
    });

    testWidgets('a Listen again song starts its radio', (tester) async {
      final ytm = FakeInnerTubeClient()
        ..radioPages['y1'] = YtmTrackPage(
          tracks: [ytTrack('y1'), ytTrack('r1'), ytTrack('r2')],
        );
      final app = await TestApp.pump(tester, innerTube: ytm);
      final log = app.container.read(youTubePlayLogProvider);
      await log.record(ytTrack('y2'));
      await log.record(ytTrack('y1'));
      app.container.invalidate(listenAgainProvider);
      await tester.pumpAndSettle();

      await tester.tap(
        find.descendant(
          of: _row('Listen again'),
          matching: find.text('Song y1'),
        ),
      );
      await tester.pumpAndSettle();
      final queue = app.container.read(playbackProvider).queue;
      expect([for (final q in queue) q.track.uri], ['y1', 'r1', 'r2']);
    });

    for (final size in const [
      Size(400, 800),
      Size(900, 700),
      Size(1360, 860),
      Size(1600, 1000),
    ]) {
      for (final scale in const [1.0, 2.0]) {
        testWidgets('fits at ${size.width}x${size.height}, text ${scale}x', (
          tester,
        ) async {
          final app = await TestApp.pump(
            tester,
            size: size,
            textScale: scale,
            innerTube: _feed(),
          );
          await _seedCollections(app);
          await _play(app);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          app.container.read(routerProvider).go('/library');
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Recently played'), findsOneWidget);
        });
      }
    }
  });

  group('Library', () {
    testWidgets('shows Recently played; an album tile opens the album', (
      tester,
    ) async {
      final app = await TestApp.pump(tester);
      app.container.read(routerProvider).go('/library');
      await tester.pumpAndSettle();
      expect(find.text('Recently played'), findsNothing, reason: 'no history');

      await _play(app);
      await tester.pumpAndSettle();
      expect(find.byType(LibraryScreen), findsOneWidget);
      final recent = _row('Recently played');
      expect(recent, findsOneWidget);
      // Distinct albums, not every track.
      expect(_tiles(tester, recent), ['Low Light']);

      await tester.tap(
        find.descendant(of: recent, matching: find.text('Low Light')),
      );
      await tester.pumpAndSettle();
      expect(
        app.container.read(routerProvider).state.uri.path,
        '/library/album',
      );
    });
  });
}
