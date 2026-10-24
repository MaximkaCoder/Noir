import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/widgets/buttons.dart';
import 'package:noir/features/home/presentation/home_screen.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';

FakeInnerTubeClient _youTubeMusic() => FakeInnerTubeClient()
  ..homePage = YtmHomePage(
    chips: const [
      YtmChip(title: 'Relax', params: 'P_RELAX'),
      YtmChip(title: 'Focus', params: 'P_FOCUS'),
    ],
    shelves: [
      YtmShelf(
        title: 'Quick picks',
        items: [
          YtmTrackItem(ytTrack('v1', title: 'Neon Rain')),
          YtmTrackItem(ytTrack('v2', title: 'Paper Moon')),
          YtmTrackItem(ytTrack('v3', title: 'Live at Dusk'), isVideo: true),
        ],
      ),
      const YtmShelf(
        title: 'Mixed for you',
        strapline: 'Similar to Mara Vale',
        items: [
          YtmPlaylistItem(playlistId: 'RDCLAK1', title: 'Night Drive Mix'),
          YtmAlbumItem(
            browseId: 'MPREb_1',
            title: 'Glass Age',
            artist: 'Ilse North',
          ),
          YtmArtistItem(browseId: 'UC1', title: 'Kei Aoto'),
        ],
      ),
    ],
    continuation: 'C1',
  )
  ..homeMorePages['C1'] = YtmHomePage(
    shelves: [
      YtmShelf(
        title: 'Late night',
        items: [YtmTrackItem(ytTrack('v9', title: 'Afterglow'))],
      ),
    ],
  );

Finder _homeScroll() => find
    .descendant(of: find.byType(HomeScreen), matching: find.byType(Scrollable))
    .first;

Future<void> _scrollTo(
  WidgetTester tester,
  Finder finder, {
  bool up = false,
}) async {
  await tester.scrollUntilVisible(
    finder,
    up ? -300 : 300,
    scrollable: _homeScroll(),
  );
  await tester.pumpAndSettle();
}

/// Lets the providers' in-memory caches expire so no timer outlives the
/// test.
Future<void> _flushCaches(WidgetTester tester) =>
    tester.pump(const Duration(minutes: 11));

void main() {
  group('Discover on Home', () {
    testWidgets('shows shelves; a song plays its shelf from there', (
      tester,
    ) async {
      final app = await TestApp.pump(tester, innerTube: _youTubeMusic());
      // Local music lives in Library now.
      expect(find.text('Albums'), findsNothing);

      await _scrollTo(tester, find.text('Discover'));
      expect(find.text('From YouTube Music'), findsOneWidget);
      expect(find.text('Relax'), findsOneWidget);
      expect(find.text('Quick picks'), findsOneWidget);
      expect(find.text('Video · Artist'), findsOneWidget);

      await _scrollTo(tester, find.text('Paper Moon'));
      await tester.tap(find.text('Paper Moon'));
      await tester.pumpAndSettle();
      final playback = app.container.read(playbackProvider);
      expect([for (final q in playback.queue) q.track.uri], ['v1', 'v2', 'v3']);
      expect(playback.current!.track.uri, 'v2');
    });

    testWidgets('loads more shelves near the end and switches moods', (
      tester,
    ) async {
      final app = await TestApp.pump(tester, innerTube: _youTubeMusic());
      await _scrollTo(tester, find.text('SIMILAR TO MARA VALE'));
      await _scrollTo(tester, find.text('Afterglow'));
      expect(app.innerTube.calls, ['home', 'homeMore C1']);

      await _scrollTo(tester, find.text('Focus'), up: true);
      // Out from under the top bar.
      await tester.drag(_homeScroll(), const Offset(0, 250));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Focus'));
      await tester.pumpAndSettle();
      expect(app.innerTube.calls, contains('home P_FOCUS'));
      expect(
        tester
            .widget<PillChip>(
              find.ancestor(
                of: find.text('Focus'),
                matching: find.byType(PillChip),
              ),
            )
            .selected,
        isTrue,
      );
    });

    testWidgets('a failure stays inside Discover and can be retried', (
      tester,
    ) async {
      final ytm = _youTubeMusic()
        ..error = const InnerTubeException(
          InnerTubeErrorKind.network,
          "Couldn't reach YouTube Music. Check your internet connection.",
        );
      await TestApp.pump(tester, innerTube: ytm);
      await _scrollTo(tester, find.text('Try again'));

      expect(find.text("Discover couldn't load"), findsOneWidget);
      expect(find.text("Here's what's playing today."), findsOneWidget);
      expect(tester.takeException(), isNull);

      ytm.error = null;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(find.text("Discover couldn't load"), findsNothing);
      await _scrollTo(tester, find.text('Neon Rain'));
    });

    testWidgets('works with an empty library too', (tester) async {
      await TestApp.pump(tester, withMusic: false, innerTube: _youTubeMusic());
      // Home no longer pushes local import.
      expect(find.text('Bring your music'), findsNothing);
      await _scrollTo(tester, find.text('From YouTube Music'));
      await _scrollTo(tester, find.text('Neon Rain'));
    });

    testWidgets('an empty feed hides the section', (tester) async {
      await TestApp.pump(tester);
      expect(find.text('From YouTube Music'), findsNothing);
    });
  });

  group('YouTube Music playlist page', () {
    testWidgets('opens from a shelf, plays, and pages in more tracks', (
      tester,
    ) async {
      final ytm = _youTubeMusic()
        ..collections['RDCLAK1'] = YtmCollection(
          id: 'VLRDCLAK1',
          title: 'Night Drive Mix',
          subtitle: 'Playlist • 2026',
          author: 'YouTube Music',
          tracks: [
            ytTrack('p1', title: 'First Light'),
            ytTrack('p2', title: 'Second Wind'),
          ],
          continuation: 'PLAYLIST_C1',
        )
        ..playlistMorePages['PLAYLIST_C1'] = YtmTrackPage(
          tracks: [ytTrack('p3', title: 'Third Rail')],
        );
      final app = await TestApp.pump(tester, innerTube: ytm);
      await _scrollTo(tester, find.text('Night Drive Mix'));
      await tester.tap(find.text('Night Drive Mix'));
      await tester.pumpAndSettle();

      final router = app.container.read(routerProvider);
      expect(router.state.uri.path, '/discover/playlist/RDCLAK1');
      expect(find.text('Playlist · 2026'), findsOneWidget);
      expect(find.text('Third Rail'), findsOneWidget);
      expect(find.byTooltip('Open in YouTube Music'), findsOneWidget);

      await tester.tap(find.text('Second Wind'));
      await tester.pumpAndSettle();
      final playback = app.container.read(playbackProvider);
      expect([for (final q in playback.queue) q.track.uri], ['p1', 'p2', 'p3']);
      expect(playback.current!.track.uri, 'p2');

      router.pop();
      await tester.pumpAndSettle();
      expect(router.state.uri.path, '/');
      await _flushCaches(tester);
    });

    testWidgets('an album that fails to open offers a retry', (tester) async {
      final app = await TestApp.pump(tester, innerTube: _youTubeMusic());
      app.container.read(routerProvider).go('/discover/album/MPREb_404');
      await tester.pumpAndSettle();
      expect(find.text("This album couldn't be opened"), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
      await _flushCaches(tester);
    });
  });
}
