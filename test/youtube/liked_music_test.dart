import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/widgets/collection_header.dart';

import '../helpers/pump_app.dart';

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
  testWidgets('Liked music shows only the music among liked videos', (
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
    expect(find.text('All likes'), findsNothing);
    expect(find.byTooltip('Open in YouTube Music'), findsNothing);
  });
}
