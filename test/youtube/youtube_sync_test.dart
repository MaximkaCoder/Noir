import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

import '../helpers/fake_http.dart';
import '../helpers/test_database.dart';
import 'youtube_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeHttp http;
  late FakeAccount account;
  late ProviderContainer container;
  late YouTubeRepository repo;

  setUp(() {
    db = inMemoryDatabase();
    http = FakeHttp(youtube);
    account = FakeAccount();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(http.dio()),
        accountServiceProvider.overrideWithValue(account),
      ],
    );
    repo = container.read(youTubeRepositoryProvider);
    // Like the app does in bootstrap: keep sync alive so it reacts.
    container.listen(youTubeSyncProvider, (_, _) {});
  });

  tearDown(() async {
    // Let background syncs (started by the connected event) finish before
    // the database closes.
    await container.read(youTubeSyncProvider.notifier).whenIdle();
    container.dispose();
    await db.close();
  });

  Future<void> sync({bool force = false}) =>
      container.read(youTubeSyncProvider.notifier).sync(force: force);

  List<String> calls() => [
    for (final r in http.requests)
      [
        r.uri.pathSegments.last,
        r.uri.queryParameters['playlistId'] ?? '',
        r.uri.queryParameters['pageToken'] ?? '',
      ].join(),
  ];

  test('sync stores playlists in order with playable tracks only', () async {
    await sync();

    final playlists = await repo.watchPlaylists().first;
    expect(playlists.map((p) => (p.title, p.trackCount)), [
      ('Night drive', 2),
      ('Focus', 1),
    ]);
    final tracks = await repo.watchPlaylistTracks('PLa').first;
    expect(tracks.map((t) => t.uri), ['v1', 'v2']);
    expect(tracks.first.artist, 'Mara Vale', reason: '" - Topic" stripped');
    expect(tracks.first.duration, const Duration(minutes: 3, seconds: 21));
    expect(tracks.first.artworkUrl, 'https://i.ytimg.com/vi/v1/mqdefault.jpg');

    final likes = await repo.watchLikes().first;
    expect(
      likes.single.duration,
      const Duration(hours: 1, minutes: 2, seconds: 3),
    );
    expect(
      http.requests.every((r) => r.authorization == 'Bearer token-0'),
      isTrue,
    );
    expect(container.read(youTubeSyncProvider).lastSyncAt, isNotNull);
  });

  test('unchanged playlists (same etag) are not downloaded again', () async {
    await sync();
    http.requests.clear();

    await sync();
    expect(calls(), isNot(contains(startsWith('playlistItems'))));

    http.handler = (r) => youtube(r, etagA: 'eA2');
    http.requests.clear();
    await sync();
    expect(calls().where((c) => c.startsWith('playlistItems')), [
      'playlistItemsPLa',
      'playlistItemsPLap2',
    ]);
  });

  test('videos cached without a category are backfilled cheaply', () async {
    await sync();
    final stored = await db.select(db.ytVideos).get();
    expect(
      {for (final v in stored) v.id: v.categoryId},
      {'v1': '10', 'v2': '10', 'v4': '10', 'v9': '22'},
    );

    // Rows cached by schema v2 have no category.
    await db.customStatement('UPDATE yt_videos SET category_id = NULL');
    http.requests.clear();
    await sync();

    expect(calls(), isNot(contains(startsWith('playlistItems'))));
    final details = http.requests.where(
      (r) =>
          r.uri.pathSegments.last == 'videos' &&
          r.uri.queryParameters['id'] != null,
    );
    expect(
      details.single.uri.queryParameters['id']!.split(','),
      unorderedEquals(['v1', 'v2', 'v4']),
    );
    expect(
      (await db.select(db.ytVideos).get()).where((v) => v.categoryId == null),
      isEmpty,
    );

    http.requests.clear();
    await sync();
    expect(
      http.requests.where((r) => r.uri.queryParameters['id'] != null),
      isEmpty,
      reason: 'nothing left to backfill',
    );
  });

  test('refreshPlaylists skips while the last sync is recent', () async {
    var now = DateTime(2026, 10, 24, 12);
    await container.read(youTubeSyncProvider.notifier).whenIdle();
    container.dispose();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(http.dio()),
        accountServiceProvider.overrideWithValue(account),
        youTubeClockProvider.overrideWithValue(() => now),
      ],
    )..listen(youTubeSyncProvider, (_, _) {});
    final controller = container.read(youTubeSyncProvider.notifier);
    await pumpEventQueue(); // The connected event starts a sync.
    await controller.whenIdle();
    http.requests.clear();

    now = now.add(const Duration(seconds: 20));
    await controller.refreshPlaylists();
    expect(http.requests, isEmpty);

    now = now.add(const Duration(seconds: 11));
    await controller.refreshPlaylists();
    expect(calls(), contains('playlists'));
  });

  test('quota exhaustion keeps the cache and explains', () async {
    await sync();
    http.handler = (_) => error(403, {
      'error': {
        'errors': [
          {'reason': 'quotaExceeded'},
        ],
      },
    });

    await sync(force: true);

    final state = container.read(youTubeSyncProvider);
    expect(state.status, SyncStatus.failed);
    expect(state.message, contains('allowance'));
    expect(await repo.watchPlaylists().first, hasLength(2));
  });

  test('a 401 refreshes the token once and retries', () async {
    var first = true;
    http.handler = (r) {
      if (first) {
        first = false;
        return error(401, {});
      }
      return youtube(r);
    };
    await sync();
    expect(account.refreshes, 1);
    expect(container.read(youTubeSyncProvider).status, SyncStatus.idle);
  });

  test('disconnecting deletes every YouTube-derived row', () async {
    await sync();
    account.set(AccountStatus.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(await repo.watchPlaylists().first, isEmpty);
    expect(await repo.watchLikes().first, isEmpty);
    expect(await db.select(db.ytVideos).get(), isEmpty);
  });

  test('ISO 8601 durations', () {
    expect(parseIsoDuration('PT4M'), const Duration(minutes: 4));
    expect(parseIsoDuration('P1DT1S'), const Duration(days: 1, seconds: 1));
    expect(parseIsoDuration('P0D'), isNull);
    expect(parseIsoDuration('nonsense'), isNull);
  });
}
