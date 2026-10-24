import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/core/widgets/artwork.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/youtube/presentation/youtube_cover.dart';

import 'artwork_fakes.dart';

/// URLs of the network images on screen.
List<String> shownUrls(WidgetTester tester) => [
  for (final image in tester.widgetList<Image>(find.byType(Image)))
    switch (image.image) {
      ResizeImage(imageProvider: final NetworkImage p) => p.url,
      final NetworkImage p => p.url,
      _ => '?',
    },
];

void main() {
  late FakeLookup lookup;
  late ArtworkResolver resolver;

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [artworkResolverProvider.overrideWithValue(resolver)],
        child: MaterialApp(
          theme: buildNoirTheme(Brightness.dark, Density.comfortable),
          home: Center(child: child),
        ),
      ),
    );
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await resolver.dispose();
  }

  setUp(() {
    lookup = FakeLookup()..known['abcdefghijk'] = atv('abcdefghijk');
    resolver = ArtworkResolver(
      lookup: lookup,
      batchWindow: const Duration(milliseconds: 20),
      saveDelay: const Duration(milliseconds: 20),
    );
  });

  testWidgets('shows the thumbnail crop, then the square album art', (
    tester,
  ) async {
    await pump(tester, const YouTubeCover(videoId: 'abcdefghijk', size: 100));

    expect(shownUrls(tester), [
      'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg',
    ]);
    final box = tester.getSize(find.byType(YouTubeCover));

    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();

    expect(lookup.queueCalls, [
      ['abcdefghijk'],
    ]);
    expect(
      shownUrls(tester),
      contains(
        'https://lh3.googleusercontent.com/abcdefghijk=w120-h120-l90-rj',
      ),
    );
    // Cross-fades in place: same size, thumbnail still underneath.
    expect(tester.getSize(find.byType(YouTubeCover)), box);
    expect(
      shownUrls(tester),
      contains('https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg'),
    );
    await finish(tester);
  });

  testWidgets('large covers crop the maxres frame and ask for 1200 px', (
    tester,
  ) async {
    await pump(tester, const YouTubeCover(videoId: 'abcdefghijk', size: 600));

    expect(
      shownUrls(tester).first,
      'https://i.ytimg.com/vi/abcdefghijk/maxresdefault.jpg',
    );
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
    expect(
      shownUrls(tester),
      contains(
        'https://lh3.googleusercontent.com/abcdefghijk=w1200-h1200-l90-rj',
      ),
    );
    await finish(tester);
  });

  testWidgets('Artwork routes YouTube thumbnails and resizes Google art', (
    tester,
  ) async {
    await pump(
      tester,
      const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Artwork(
            path: 'https://i.ytimg.com/vi/abcdefghijk/mqdefault.jpg',
            size: 48,
          ),
          Artwork(
            path: 'https://lh3.googleusercontent.com/disc=w544-h544-l90-rj',
            size: 48,
          ),
        ],
      ),
    );

    expect(find.byType(YouTubeCover), findsOneWidget);
    expect(shownUrls(tester), [
      'https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg',
      'https://lh3.googleusercontent.com/disc=w120-h120-l90-rj',
    ]);
    await tester.pump(const Duration(milliseconds: 50));
    await finish(tester);
  });
}
