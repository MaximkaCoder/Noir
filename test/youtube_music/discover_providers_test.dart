import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';

import 'fake_innertube.dart';

void main() {
  late FakeInnerTube http;
  late ProviderContainer container;

  setUp(() {
    http = FakeInnerTube(recordedYouTubeMusic);
    container = ProviderContainer(
      overrides: [
        innerTubeClientProvider.overrideWithValue(
          InnerTubeClient(dio: http.dio(), retryDelay: Duration.zero),
        ),
      ],
    );
    addTearDown(container.dispose);
  });

  List<String?> homeRequests() => [
    for (final r in http.apiRequests)
      if (r.path.endsWith('/browse'))
        (r.json['continuation'] ?? r.json['browseId']) as String?,
  ];

  group('homeFeedProvider', () {
    test('loads, pages and keeps the feed for 30 minutes', () async {
      final feed = await container.read(homeFeedProvider.future);
      expect(feed.shelves, hasLength(3));
      expect(feed.chips, isNotEmpty);
      expect(feed.hasMore, isTrue);

      final controller = container.read(homeFeedProvider.notifier);
      expect(await controller.loadMore(), isTrue);
      final more = container.read(homeFeedProvider).value!;
      expect(more.shelves.map((s) => s.title), [
        'Quick picks',
        'Take it easy',
        'Party music',
        'New releases',
        'The sound of autumn',
        'Trending songs for you',
      ]);
      expect(more.chips, feed.chips);

      await controller.refresh(); // Fresh: served from memory.
      expect(homeRequests(), ['FEmusic_home', 'TEST_CONTINUATION_1']);

      await controller.refresh(force: true);
      expect(homeRequests(), hasLength(3));
      expect(container.read(homeFeedProvider).value!.shelves, hasLength(3));
    });

    test('selecting a mood chip reloads with its params', () async {
      final feed = await container.read(homeFeedProvider.future);
      final chip = feed.chips[1];

      await container.read(homeFeedProvider.notifier).selectChip(chip.params);

      expect(http.apiRequests.last.json['params'], chip.params);
      expect(container.read(homeFeedProvider).value!.chipParams, chip.params);
    });

    test('a failed refresh keeps the shown feed', () async {
      await container.read(homeFeedProvider.future);
      http.handler = (r) => jsonReply({}, status: 400);

      await expectLater(
        container.read(homeFeedProvider.notifier).refresh(force: true),
        throwsA(isA<InnerTubeException>()),
      );
      expect(container.read(homeFeedProvider).value!.shelves, hasLength(3));
    });
  });

  test('radioProvider pages and drops duplicates', () async {
    final provider = radioProvider('Z85lxckrtzg');
    final sub = container.listen(provider, (_, _) {});
    addTearDown(sub.close);

    final first = await container.read(provider.future);
    expect(first.tracks, hasLength(5));

    http.handler = (r) {
      if (r.path.endsWith('/next')) {
        // A page that only repeats tracks already queued.
        return jsonReply(fixture('next'));
      }
      return recordedYouTubeMusic(r);
    };
    expect(await container.read(provider.notifier).loadMore(), isTrue);
    expect(container.read(provider).value!.tracks, hasLength(5));
    expect(http.apiRequests.last.json['playlistId'], 'RDAMVMZ85lxckrtzg');

    http.handler = recordedYouTubeMusic;
    expect(await container.read(provider.notifier).loadMore(), isTrue);
    final tracks = container.read(provider).value!.tracks;
    expect(tracks, hasLength(8));
    expect(tracks.map((t) => t.uri).toSet(), hasLength(8));
  });

  test('musicSearchProvider skips blank queries', () async {
    final empty = await container.read(
      musicSearchProvider((query: '  ', filter: YtmSearchFilter.songs)).future,
    );
    expect(empty.items, isEmpty);
    expect(http.apiRequests, isEmpty);

    final page = await container.read(
      musicSearchProvider((query: 'daft punk', filter: YtmSearchFilter.songs))
          .future,
    );
    expect(page.items, hasLength(3));
  });
}
