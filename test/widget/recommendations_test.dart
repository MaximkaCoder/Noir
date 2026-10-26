import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/shell/sidebar.dart';
import 'package:noir/core/widgets/shelf_row.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playlists/data/playlist_repository.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';
import '../helpers/pump_app.dart';

Finder _inRow(String row, String text) => find.descendant(
  of: find.ancestor(of: find.text(row), matching: find.byType(ShelfRow)),
  matching: find.text(text),
);

Future<void> _rightClick(WidgetTester tester, Finder target) async {
  await tester.tap(target, buttons: kSecondaryMouseButton);
  await tester.pumpAndSettle();
}

Future<TestApp> _withForYou(WidgetTester tester) async {
  final ytm = FakeInnerTubeClient()
    ..radioPages['y1'] = YtmTrackPage(
      tracks: [ytTrack('y1'), ytTrack('r1'), ytTrack('r2')],
    )
    ..radioPages['r1'] = YtmTrackPage(
      tracks: [ytTrack('r1'), ytTrack('s1'), ytTrack('s2')],
    );
  final app = await TestApp.pump(tester, innerTube: ytm);
  await app.container.read(youTubePlayLogProvider).record(ytTrack('y1'));
  app.container.invalidate(forYouProvider);
  await tester.pumpAndSettle();
  return app;
}

void main() {
  group('For you', () {
    testWidgets('a song starts its radio, like Listen again', (tester) async {
      final app = await _withForYou(tester);
      await tester.tap(_inRow('Mixed for you', 'Song r1'));
      await tester.pumpAndSettle();
      final queue = app.container.read(playbackProvider).queue;
      expect([for (final q in queue) q.track.uri], ['r1', 's1', 's2']);
    });

    testWidgets('"Not interested" removes the song at once', (tester) async {
      final app = await _withForYou(tester);
      await _rightClick(tester, _inRow('Mixed for you', 'Song r2'));
      await tester.tap(find.text('Not interested'));
      await tester.pumpAndSettle();
      expect(_inRow('Mixed for you', 'Song r2'), findsNothing);
      expect(_inRow('Mixed for you', 'Song r1'), findsOneWidget);
      expect(app.container.read(dislikesProvider).songs.keys, contains('r2'));
      // Let the toast run out.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  testWidgets('a playlist can be hidden from the sidebar', (tester) async {
    final app = await TestApp.pump(tester);
    await PlaylistRepository(app.db).create('Late Night');
    await tester.pumpAndSettle();
    final item = find.descendant(
      of: find.byType(Sidebar),
      matching: find.text('Late Night'),
    );
    expect(item, findsOneWidget);

    await _rightClick(tester, item);
    await tester.tap(find.text('Hide from sidebar'));
    await tester.pumpAndSettle();
    expect(item, findsNothing);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
  });

  testWidgets('playlist pages leave out the top search field', (tester) async {
    final app = await TestApp.pump(tester);
    final id = await PlaylistRepository(app.db).create('Late Night');
    const top = 'Search music, artists, albums…';
    expect(find.text(top), findsOneWidget);

    app.container.read(routerProvider).go('/library/playlist/$id');
    await tester.pumpAndSettle();
    expect(find.text(top), findsNothing);

    app.container.read(routerProvider).go('/library');
    await tester.pumpAndSettle();
    expect(find.text(top), findsOneWidget);
  });
}
