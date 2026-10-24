import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/search/presentation/music_results.dart';
import 'package:noir/features/search/presentation/search_screen.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';

FakeInnerTubeClient _youTubeMusic() => FakeInnerTubeClient()
  ..searchPages[YtmSearchFilter.songs] = YtmSearchPage(
    items: [
      YtmTrackItem(ytTrack('s1', title: 'Harbor Lights')),
      YtmTrackItem(ytTrack('s2', title: 'Harbor Song')),
    ],
    continuation: 'S1',
  )
  ..searchMorePages['S1'] = YtmSearchPage(
    items: [YtmTrackItem(ytTrack('s3', title: 'Harbor Dawn'))],
  )
  ..searchPages[YtmSearchFilter.albums] = const YtmSearchPage(
    items: [
      YtmAlbumItem(
        browseId: 'MPREb_9',
        title: 'Glass Harbor',
        artist: 'Ilse North',
        year: 2024,
      ),
    ],
  )
  ..collections['MPREb_9'] = YtmCollection(
    id: 'MPREb_9',
    title: 'Glass Harbor',
    subtitle: 'Album • 2024',
    author: 'Ilse North',
    tracks: [ytTrack('g1', title: 'Opening')],
  );

Finder _field() => find.descendant(
  of: find.byType(SearchScreen),
  matching: find.byType(TextField),
);

Finder _musicChip(String label) =>
    find.descendant(of: find.byType(MusicResults), matching: find.text(label));

List<String> _searches(FakeInnerTubeClient ytm) => [
  for (final c in ytm.calls)
    if (c.startsWith('search ')) c,
];

Future<TestApp> _openSearch(WidgetTester tester) async {
  final app = await TestApp.pump(tester, innerTube: _youTubeMusic());
  app.container.read(routerProvider).go('/search');
  await tester.pumpAndSettle();
  return app;
}

/// Lets the providers' in-memory caches expire so no timer outlives the
/// test.
Future<void> _flushCaches(WidgetTester tester) =>
    tester.pump(const Duration(minutes: 11));

void main() {
  testWidgets('YouTube Music is searched once typing pauses for 400 ms', (
    tester,
  ) async {
    final app = await _openSearch(tester);
    await tester.enterText(_field(), 'har');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(_field(), 'harbor');
    await tester.pump(const Duration(milliseconds: 399));
    expect(_searches(app.innerTube), isEmpty);

    await tester.pump(const Duration(milliseconds: 1));
    await tester.pumpAndSettle();
    expect(_searches(app.innerTube), ['search harbor songs']);
    // Local results stay first.
    expect(find.text('Quiet Harbor'), findsWidgets);
    expect(find.text('YouTube Music'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Quiet Harbor').last).dy,
      lessThan(tester.getTopLeft(find.text('Harbor Lights')).dy),
    );

    // Results play from the one tapped; the next page loads on its own.
    await tester.tap(find.text('Harbor Song'));
    await tester.pumpAndSettle();
    final playback = app.container.read(playbackProvider);
    expect(playback.current!.track.uri, 's2');
    expect(find.text('Harbor Dawn'), findsOneWidget);
    expect(app.innerTube.calls, contains('searchMore S1'));
    await _flushCaches(tester);
  });

  testWidgets('Enter searches right away; filters re-run the search', (
    tester,
  ) async {
    final app = await _openSearch(tester);
    await tester.enterText(_field(), 'harbor');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();
    expect(_searches(app.innerTube), ['search harbor songs']);

    await tester.pumpAndSettle();
    await tester.tap(_musicChip('Albums'));
    await tester.pumpAndSettle();
    expect(_searches(app.innerTube).last, 'search harbor albums');
    expect(find.text('Album · Ilse North · 2024'), findsOneWidget);

    await tester.tap(find.text('Glass Harbor'));
    await tester.pumpAndSettle();
    expect(
      app.container.read(routerProvider).state.uri.path,
      '/search/album/MPREb_9',
    );
    expect(find.text('Album · 2024'), findsOneWidget);
    expect(find.text('Opening'), findsOneWidget);
    await _flushCaches(tester);
  });

  testWidgets('a YouTube Music failure leaves local results alone', (
    tester,
  ) async {
    final app = await _openSearch(tester);
    app.innerTube.error = const InnerTubeException(
      InnerTubeErrorKind.rateLimited,
      'YouTube Music is limiting requests. Try again in a minute.',
    );
    await tester.enterText(_field(), 'harbor');
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(find.text('Quiet Harbor'), findsWidgets);
    expect(
      find.text('YouTube Music is limiting requests. Try again in a minute.'),
      findsOneWidget,
    );

    app.innerTube.error = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Harbor Lights'), findsOneWidget);
    await _flushCaches(tester);
  });
}
