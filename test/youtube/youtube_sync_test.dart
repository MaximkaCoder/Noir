import 'dart:async';

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

/// Account that is either connected or not, with a fixed token.

class _FakeAccount implements AccountConnectionService {
  final _changes = StreamController<AccountConnection>.broadcast();
  AccountConnection _state = const AccountConnection(
    status: AccountStatus.connected,
  );
  int refreshes = 0;

  void set(AccountStatus status) {
    _state = AccountConnection(status: status);
    _changes.add(_state);
  }

  @override
  AccountConnection get current => _state;
  @override
  Stream<AccountConnection> watch() async* {
    yield _state;
    yield* _changes.stream;
  }

  @override
  Future<String> accessToken({bool forceRefresh = false}) async {
    if (forceRefresh) refreshes++;
    return 'token-$refreshes';
  }

  @override
  Future<void> connect() async {}
  @override
  void cancelConnect() {}
  @override
  Future<void> disconnect() async => set(AccountStatus.disconnected);
}

Map<String, Object?> video(String id, {String duration = 'PT3M21S'}) => {
  'id': id,
  'snippet': {
    'title': 'Song $id',
    'channelTitle': 'Mara Vale - Topic',
    'thumbnails': {
      'high': {'url': 'https://i.ytimg.com/$id.jpg'},
    },
  },
  'contentDetails': {'duration': duration},
  'status': {'embeddable': true},
};

Map<String, Object?> item(String videoId, {String privacy = 'public'}) => {
  'snippet': {
    'resourceId': {'videoId': videoId},
  },
  'status': {'privacyStatus': privacy},
};

/// A small fake YouTube: two playlists, one paginated, plus likes.
FakeReply youtube(FakeRequest r, {String etagA = 'eA1'}) {
  final q = r.uri.queryParameters;
  switch (r.uri.pathSegments.last) {
    case 'playlists':
      return ok({
        'items': [
          {
            'id': 'PLa',
            'etag': etagA,
            'snippet': {'title': 'Night drive'},
            'contentDetails': {'itemCount': 3},
            'status': {'privacyStatus': 'private'},
          },
          {
            'id': 'PLb',
            'etag': 'eB1',
            'snippet': {'title': 'Focus'},
            'contentDetails': {'itemCount': 1},
          },
        ],
      });
    case 'playlistItems':
      if (q['playlistId'] == 'PLb') {
        return ok({
          'items': [item('v4')],
        });
      }
      return q['pageToken'] == null
          ? ok({
              'items': [item('v1'), item('gone', privacy: 'private')],
              'nextPageToken': 'p2',
            })
          : ok({
              'items': [item('v2')],
            });
    case 'videos':
      if (q['myRating'] == 'like') {
        return ok({
          'items': [video('v9', duration: 'PT1H2M3S')],
        });
      }
      return ok({
        'items': [for (final id in q['id']!.split(',')) video(id)],
      });
  }
  return error(404, {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeHttp http;
  late _FakeAccount account;
  late ProviderContainer container;
  late YouTubeRepository repo;

  setUp(() {
    db = inMemoryDatabase();
    http = FakeHttp(youtube);
    account = _FakeAccount();
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
    expect(tracks.first.artworkUrl, 'https://i.ytimg.com/v1.jpg');

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
