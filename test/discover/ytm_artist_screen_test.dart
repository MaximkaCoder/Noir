import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/discover/presentation/ytm_artist_screen.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';
import 'fake_artist_client.dart';

String _location(TestApp app) => app.container
    .read(routerProvider)
    .routerDelegate
    .currentConfiguration
    .uri
    .path;

Future<TestApp> _openArtist(
  WidgetTester tester,
  FakeArtistInnerTube ytm, {
  String location = '/discover/artist/UCmara',
}) async {
  final app = await TestApp.pump(tester, innerTube: ytm, withMusic: false);
  app.container.read(routerProvider).go(location);
  await tester.pumpAndSettle();
  return app;
}

/// Scrolls the page until [text] is fully on screen.
Future<void> _reveal(WidgetTester tester, String text) async {
  final target = _inPage(find.text(text));
  await tester.scrollUntilVisible(
    target,
    300,
    scrollable: _inPage(find.byType(Scrollable)).first,
  );
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

/// Lets the providers' in-memory caches expire so no timer outlives the
/// test.
Future<void> _flushCaches(WidgetTester tester) =>
    tester.pump(const Duration(minutes: 11));

Finder get _page => find.byType(YtmArtistScreen);

Finder _inPage(Finder f) => find.descendant(of: _page, matching: f);

void main() {
  testWidgets('shows the header, top songs and shelves', (tester) async {
    final ytm = FakeArtistInnerTube()..artists['UCmara'] = fakeArtist();
    await _openArtist(tester, ytm);

    expect(ytm.calls, contains('artist UCmara'));
    expect(_inPage(find.text('Mara Vale')), findsWidgets);
    expect(_inPage(find.text('Artist')), findsOneWidget);
    expect(
      _inPage(find.text('1.2M subscribers · 3M monthly audience')),
      findsOneWidget,
    );
    expect(_inPage(find.text('Top songs')), findsOneWidget);
    for (var i = 1; i <= 5; i++) {
      expect(_inPage(find.text('Top song $i')), findsOneWidget);
    }
    await _reveal(tester, 'Kei Aoto');
    expect(_inPage(find.text('Albums')), findsOneWidget);
    expect(_inPage(find.text('Low Light')), findsOneWidget);
    expect(_inPage(find.text('Fans might also like')), findsOneWidget);
    await _flushCaches(tester);
  });

  testWidgets('play, shuffle and radio use the top songs', (tester) async {
    final ytm = FakeArtistInnerTube()..artists['UCmara'] = fakeArtist();
    final app = await _openArtist(tester, ytm);

    await tester.tap(_inPage(find.byTooltip('Start radio')));
    await tester.pumpAndSettle();
    expect(ytm.calls, contains('radio top1'));
    final playing = app.container.read(playbackProvider);
    expect(playing.current?.track.uri, 'top1');

    await tester.tap(_inPage(find.byTooltip('Play')).first);
    await tester.pumpAndSettle();
    expect(app.container.read(playbackProvider).queue.map((q) => q.track.uri), [
      'top1',
      'top2',
      'top3',
      'top4',
      'top5',
    ]);
    await _flushCaches(tester);
  });

  testWidgets('"Show all" loads every song from the songs playlist', (
    tester,
  ) async {
    final ytm = FakeArtistInnerTube()
      ..artists['UCmara'] = fakeArtist()
      ..collections['OLAK_all'] = YtmCollection(
        id: 'VLOLAK_all',
        title: 'Songs',
        tracks: [
          for (var i = 1; i <= 8; i++)
            ytTrack('all$i', title: 'Any song $i', artist: 'Mara Vale'),
        ],
      );
    await _openArtist(tester, ytm);

    await tester.tap(_inPage(find.text('Show all')));
    await tester.pumpAndSettle();
    expect(ytm.calls, contains('playlist OLAK_all'));
    expect(_inPage(find.text('Any song 8')), findsOneWidget);
    expect(_inPage(find.text('Top song 1')), findsNothing);

    await tester.tap(_inPage(find.text('Show less')));
    await tester.pumpAndSettle();
    expect(_inPage(find.text('Top song 1')), findsOneWidget);
    expect(_inPage(find.text('Any song 8')), findsNothing);
    await _flushCaches(tester);
  });

  testWidgets('related artists open their page in the same branch', (
    tester,
  ) async {
    final ytm = FakeArtistInnerTube()
      ..artists['UCmara'] = fakeArtist()
      ..artists['UCkei'] = fakeArtist(browseId: 'UCkei', name: 'Kei Aoto');
    final app = await _openArtist(
      tester,
      ytm,
      location: '/search/artist/UCmara',
    );

    await _reveal(tester, 'Kei Aoto');
    await tester.tap(_inPage(find.text('Kei Aoto')));
    await tester.pumpAndSettle();
    // The new page's request answers after the route settled.
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();

    expect(_location(app), '/search/artist/UCkei');
    expect(ytm.calls, contains('artist UCkei'));
    expect(
      find.descendant(
        of: find.byType(YtmArtistScreen),
        matching: find.text('Top song 1'),
      ),
      findsOneWidget,
    );
    await _flushCaches(tester);
  });

  testWidgets('albums open under the branch the page is in', (tester) async {
    final ytm = FakeArtistInnerTube()
      ..artists['UCmara'] = fakeArtist()
      ..collections['MPREb_low'] = YtmCollection(
        id: 'MPREb_low',
        title: 'Low Light',
        tracks: [ytTrack('l1', title: 'Opening')],
      );
    final app = await _openArtist(tester, ytm);

    await _reveal(tester, 'Low Light');
    await tester.tap(_inPage(find.text('Low Light')));
    await tester.pumpAndSettle();
    expect(_location(app), '/discover/album/MPREb_low');
    expect(find.text('Opening'), findsOneWidget);
    await _flushCaches(tester);
  });

  testWidgets('a failure offers a retry', (tester) async {
    final ytm = FakeArtistInnerTube()
      ..error = const InnerTubeException(
        InnerTubeErrorKind.network,
        "Couldn't reach YouTube Music.",
      );
    await _openArtist(tester, ytm);
    expect(find.text("This artist couldn't be opened"), findsOneWidget);

    ytm
      ..error = null
      ..artists['UCmara'] = fakeArtist();
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(_inPage(find.text('Top songs')), findsOneWidget);
    await _flushCaches(tester);
  });
}
