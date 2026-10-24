import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/widgets/collection_header.dart';

import '../helpers/pump_app.dart';
import '../helpers/test_database.dart';

const _likes = [
  YtVideo(
    id: 'm1',
    title: 'Ash & Ember (Official Audio)',
    channelTitle: 'Mara Vale - Topic',
    duration: Duration(minutes: 3),
    categoryId: '10',
  ),
  YtVideo(
    id: 'x1',
    title: 'How to fix a bike chain',
    channelTitle: 'Garage Hour',
    duration: Duration(minutes: 10),
    categoryId: '26',
  ),
  YtVideo(
    id: 'm2',
    title: 'Signal (Live)',
    channelTitle: 'KeiAotoVEVO',
    duration: Duration(minutes: 4),
    categoryId: '24',
  ),
];

/// The page title (the sidebar has its own "Liked videos" link).
Finder _title(String text) => find.descendant(
  of: find.byType(CollectionHeader),
  matching: find.text(text),
);

void main() {
  testWidgets('Liked music hides non-music likes until "All likes"', (
    tester,
  ) async {
    final app = await TestApp.pump(tester, withMusic: false);
    await YouTubeRepository(app.db).saveLikes(_likes);
    app.container.read(routerProvider).go('/library/youtube/liked');
    await tester.pumpAndSettle();

    expect(_title('Liked music'), findsOneWidget);
    expect(find.text('Ash & Ember (Official Audio)'), findsOneWidget);
    expect(find.text('Signal (Live)'), findsOneWidget);
    expect(find.text('How to fix a bike chain'), findsNothing);
    expect(find.textContaining('2 songs · 7m'), findsOneWidget);

    await tester.tap(find.text('All likes'));
    await tester.pumpAndSettle();

    expect(_title('Liked videos'), findsOneWidget);
    expect(find.text('How to fix a bike chain'), findsOneWidget);
    expect(find.textContaining('3 songs · 17m'), findsOneWidget);
    final saved = await app.container
        .read(settingsRepositoryProvider)
        .readJson('youtube_likes_filter');
    expect(saved, {'musicOnly': false});
  });

  test('the "All likes" choice survives a restart', () async {
    final db = inMemoryDatabase();
    addTearDown(db.close);
    await YouTubeRepository(db).saveLikes(_likes);

    var container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    expect(container.read(likesMusicOnlyProvider), isTrue, reason: 'default');
    expect(container.read(youTubeLikesTitleProvider), 'Liked music');
    container.read(likesMusicOnlyProvider.notifier).set(musicOnly: false);
    await pumpEventQueue();
    container.dispose();

    container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(container.dispose);
    final sub = container.listen(youTubeLikesProvider, (_, _) {});
    addTearDown(sub.close);
    container.read(likesMusicOnlyProvider);
    await pumpEventQueue();
    expect(container.read(likesMusicOnlyProvider), isFalse);
    expect(container.read(youTubeLikesTitleProvider), 'Liked videos');
    await pumpEventQueue();
    expect(container.read(youTubeLikesProvider).value, hasLength(3));

    container.read(likesMusicOnlyProvider.notifier).set(musicOnly: true);
    await pumpEventQueue();
    expect(
      [for (final t in container.read(youTubeLikesProvider).value!) t.uri],
      ['m1', 'm2'],
    );
  });
}
