import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/settings/data/settings_repository.dart';
import 'package:noir/features/youtube/application/youtube_pending_edits.dart';
import 'package:noir/features/youtube/application/youtube_refresh.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_http.dart';
import '../helpers/test_database.dart';
import 'youtube_fakes.dart';

/// [FakeHttp] that holds every response until [gate] completes, so the
/// optimistic state can be observed mid-request.
class GatedHttp extends FakeHttp {
  GatedHttp(super.handler);

  Completer<void>? gate;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await gate?.future;
    return await super.fetch(options, requestStream, cancelFuture);
  }
}

Track ytTrack(String videoId) => Track(
  id: 'yt:$videoId',
  source: MediaSource.youtube,
  title: 'Song $videoId',
  uri: videoId,
  artist: 'Mara Vale',
  duration: const Duration(minutes: 3),
);

FakeReply insufficientPermissions() => error(403, {
  'error': {
    'code': 403,
    'errors': [
      {'reason': 'insufficientPermissions'},
    ],
  },
});

Future<void> until(FutureOr<bool> Function() condition) async {
  for (var i = 0; i < 200 && !await condition(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(await condition(), isTrue, reason: 'condition never became true');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late GatedHttp http;
  late FakeAccount account;
  late ProviderContainer container;
  late YouTubeRepository repo;

  ProviderContainer newContainer() => ProviderContainer(
    overrides: [
      databaseProvider.overrideWithValue(db),
      httpClientProvider.overrideWithValue(http.dio()),
      accountServiceProvider.overrideWithValue(account),
    ],
  );

  setUp(() async {
    db = inMemoryDatabase();
    http = GatedHttp((_) => error(404, {}));
    account = FakeAccount()..set(AccountStatus.connected, canWrite: true);
    container = newContainer();
    repo = container.read(youTubeRepositoryProvider);
    container
      ..listen(youTubeSaveProvider, (_, _) {})
      ..listen(saveTargetProvider, (_, _) {});
    await repo.savePlaylists(const [
      YtPlaylist(id: 'PLt', title: 'NOIR Likes', itemCount: 2, etag: 'e1'),
    ]);
    await repo.savePlaylistItems('PLt', 'e1', const [
      YtPlaylistEntry(videoId: 'v1', id: 'item-v1'),
      YtPlaylistEntry(videoId: 'v3'), // Cached before item ids were stored.
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  void chooseTarget() => container
      .read(saveTargetProvider.notifier)
      .set(const SaveTarget('PLt', 'NOIR Likes'));

  YouTubeSaveController ctrl() => container.read(youTubeSaveProvider.notifier);

  bool saved(String videoId) {
    container.listen(youTubeSavedProvider(videoId), (_, _) {});
    return container.read(youTubeSavedProvider(videoId));
  }

  Map<String, Object?> body(FakeRequest r) =>
      jsonDecode(r.body) as Map<String, Object?>;

  group('YouTubeApi writes', () {
    late YouTubeApi api;
    setUp(() => api = container.read(youTubeApiProvider));

    test('insert sends a youtube#video resource to playlistItems', () async {
      http.handler = (_) => ok({'id': 'item-new'});
      expect(await api.insertPlaylistItem('PLt', 'v2'), 'item-new');
      final r = http.requests.single;
      expect(r.method, 'POST');
      expect(r.uri.path, '/youtube/v3/playlistItems');
      expect(r.uri.queryParameters, {'part': 'snippet'});
      expect(body(r), {
        'snippet': {
          'playlistId': 'PLt',
          'resourceId': {'kind': 'youtube#video', 'videoId': 'v2'},
        },
      });
      expect(r.authorization, startsWith('Bearer '));
    });

    test('delete removes the playlist item by its id', () async {
      http.handler = (_) => (status: 204, json: null);
      await api.deletePlaylistItem('item-v1');
      final r = http.requests.single;
      expect(r.method, 'DELETE');
      expect(r.uri.path, '/youtube/v3/playlistItems');
      expect(r.uri.queryParameters, {'id': 'item-v1'});
    });

    test('createPlaylist makes a private playlist', () async {
      http.handler = (_) => ok({
        'id': 'PLnew',
        'etag': 'n1',
        'snippet': {'title': 'NOIR Likes'},
        'status': {'privacyStatus': 'private'},
      });
      final p = await api.createPlaylist('NOIR Likes');
      expect(p.id, 'PLnew');
      final r = http.requests.single;
      expect(r.method, 'POST');
      expect(r.uri.path, '/youtube/v3/playlists');
      expect(body(r), {
        'snippet': {'title': 'NOIR Likes'},
        'status': {'privacyStatus': 'private'},
      });
    });

    test('403 insufficientPermissions is a permission error', () async {
      http.handler = (_) => insufficientPermissions();
      await expectLater(
        api.insertPlaylistItem('PLt', 'v2'),
        throwsA(
          isA<YouTubeApiException>().having(
            (e) => e.kind,
            'kind',
            YouTubeErrorKind.permission,
          ),
        ),
      );
    });

    test('writes are not retried on server errors (no duplicates)', () async {
      http.handler = (_) => error(503, {});
      await expectLater(
        api.insertPlaylistItem('PLt', 'v2'),
        throwsA(isA<YouTubeApiException>()),
      );
      expect(http.requests, hasLength(1));
    });
  });

  group('heart', () {
    test('saves into the target playlist and caches the item', () async {
      chooseTarget();
      http.handler = (_) => ok({'id': 'item-v2'});

      final outcome = await ctrl().toggle(ytTrack('v2'));

      expect(outcome.result, SaveResult.saved);
      expect(outcome.message, 'Saved to NOIR Likes');
      expect(await repo.playlistItemIds('PLt', 'v2'), ['item-v2']);
      final tracks = await repo.watchPlaylistTracks('PLt').first;
      expect(tracks.map((t) => t.uri), contains('v2'));
      expect(
        http.requests.any((r) => r.uri.path.contains('rate')),
        isFalse,
        reason: 'never a real like',
      );
      await until(() => saved('v2'));
    });

    test('removes by the cached playlist item id', () async {
      chooseTarget();
      http.handler = (_) => (status: 204, json: null);

      final outcome = await ctrl().toggle(ytTrack('v1'));

      expect(outcome.result, SaveResult.removed);
      expect(outcome.message, 'Removed from NOIR Likes');
      final r = http.requests.single;
      expect((r.method, r.uri.queryParameters['id']), ('DELETE', 'item-v1'));
      expect(await repo.playlistContains('PLt', 'v1'), isFalse);
      await until(() => !saved('v1'));
    });

    test('looks the item id up when the cache has none', () async {
      chooseTarget();
      http.handler = (r) => r.method == 'GET'
          ? ok({
              'items': [
                {'id': 'found-v3'},
              ],
            })
          : (status: 204, json: null);

      final outcome = await ctrl().toggle(ytTrack('v3'));

      expect(outcome.result, SaveResult.removed);
      expect(
        http.requests.first.uri.queryParameters,
        containsPair('videoId', 'v3'),
      );
      expect(http.requests.last.method, 'DELETE');
      expect(http.requests.last.uri.queryParameters['id'], 'found-v3');
    });

    test('shows the change at once, ignores double taps and reverts on '
        'failure', () async {
      chooseTarget();
      http
        ..handler = ((_) => error(500, {}))
        ..gate = Completer<void>();
      expect(saved('v2'), isFalse);

      final pending = ctrl().toggle(ytTrack('v2'));
      await until(() => saved('v2'));
      expect((await ctrl().toggle(ytTrack('v2'))).result, SaveResult.ignored);

      http.gate!.complete();
      final outcome = await pending;

      expect(outcome.result, SaveResult.failed);
      expect(outcome.message, startsWith("Couldn't save to NOIR Likes."));
      expect(saved('v2'), isFalse);
      expect(http.requests, hasLength(1), reason: 'one request per video');
      expect(await repo.playlistContains('PLt', 'v2'), isFalse);
    });

    test(
      '403 insufficientPermissions asks for the permission and reverts',
      () async {
        chooseTarget();
        http.handler = (_) => insufficientPermissions();

        final outcome = await ctrl().toggle(ytTrack('v2'));

        expect(outcome.result, SaveResult.needsPermission);
        expect(saved('v2'), isFalse);
        expect(container.read(youTubeSaveProvider).inFlight, isEmpty);
      },
    );

    test('asks for a playlist first, then for the permission', () async {
      expect(
        (await ctrl().toggle(ytTrack('v2'))).result,
        SaveResult.needsTarget,
      );
      chooseTarget();
      account.set(AccountStatus.connected);
      expect(
        (await ctrl().toggle(ytTrack('v2'))).result,
        SaveResult.needsPermission,
      );
      expect(http.requests, isEmpty);
    });

    test('ignores local tracks', () async {
      chooseTarget();
      const local = Track(
        id: 'local:1',
        source: MediaSource.local,
        title: 'Ash',
        uri: r'C:\a.mp3',
      );
      expect((await ctrl().toggle(local)).result, SaveResult.ignored);
      expect(http.requests, isEmpty);
    });

    test('requestWriteAccess reports a declined grant', () async {
      account
        ..set(AccountStatus.connected)
        ..upgradeError = const OAuthWriteDeclined();
      final result = await ctrl().requestWriteAccess();
      expect(result.granted, isFalse);
      expect(result.message, contains('Everything else keeps working'));
      expect(container.read(youTubeSaveProvider).authorizing, isFalse);
    });
  });

  group('target playlist', () {
    const targetKey = 'youtube_save_target';

    test('is remembered on this device', () async {
      chooseTarget();
      final settings = container.read(settingsRepositoryProvider);
      await until(() async => await settings.readJson(targetKey) != null);

      final next = newContainer();
      addTearDown(next.dispose);
      next.listen(saveTargetProvider, (_, _) {});
      await until(() => next.read(saveTargetProvider) != null);
      expect(
        next.read(saveTargetProvider),
        const SaveTarget('PLt', 'NOIR Likes'),
      );
    });

    test('is forgotten when the account disconnects', () async {
      chooseTarget();
      final settings = container.read(settingsRepositoryProvider);
      await until(() async => await settings.readJson(targetKey) != null);
      account.set(AccountStatus.disconnected);
      await until(() => container.read(saveTargetProvider) == null);
      await until(() async => await settings.readJson(targetKey) == null);
    });

    test('a new playlist is created private, cached and chosen', () async {
      http.handler = (_) => ok({
        'id': 'PLnew',
        'etag': 'n1',
        'snippet': {'title': 'NOIR Likes'},
        'contentDetails': {'itemCount': 0},
        'status': {'privacyStatus': 'private'},
      });
      await ctrl().createTarget('NOIR Likes');
      expect(container.read(saveTargetProvider)?.id, 'PLnew');
      expect((await repo.playlistRow('PLnew'))?.title, 'NOIR Likes');
    });
  });

  group('add to / remove from any playlist', () {
    Future<List<String>> cached(String playlistId) async => [
      for (final e in await repo.playlistEntries(playlistId)) e.videoId,
    ];

    test('adding inserts on YouTube and shows up at once', () async {
      http.handler = (_) => ok({'id': 'item-v2'});
      final outcome = await ctrl().addTo('PLt', ytTrack('v2'));
      expect(outcome.result, SaveResult.saved);
      expect(http.requests.single.method, 'POST');
      expect(await cached('PLt'), ['v1', 'v3', 'v2']);
      container.listen(youTubePlaylistsWithVideoProvider('v2'), (_, _) {});
      await until(
        () =>
            container
                .read(youTubePlaylistsWithVideoProvider('v2'))
                .value
                ?.contains('PLt') ??
            false,
      );
    });

    test('removing drops the row before YouTube answers', () async {
      http
        ..gate = Completer<void>()
        ..handler = ((_) => (status: 204, json: null));
      final done = ctrl().removeFrom('PLt', ytTrack('v1'));
      await until(() async => !(await cached('PLt')).contains('v1'));
      http.gate!.complete();
      expect((await done).result, SaveResult.removed);
      expect(http.requests.single.method, 'DELETE');
      expect(http.requests.single.uri.queryParameters['id'], 'item-v1');
    });

    test('a refused removal puts the song back', () async {
      http.handler = (_) => error(500, {});
      final outcome = await ctrl().removeFrom('PLt', ytTrack('v1'));
      expect(outcome.result, SaveResult.failed);
      expect(await cached('PLt'), ['v1', 'v3']);
    });

    test('without the write permission nothing is sent', () async {
      account.set(AccountStatus.connected);
      final outcome = await ctrl().addTo('PLt', ytTrack('v2'));
      expect(outcome.result, SaveResult.needsPermission);
      expect(http.requests, isEmpty);
    });

    test('a lagging YouTube answer does not undo a fresh change', () async {
      http.handler = (_) => ok({'id': 'item-v2'});
      await ctrl().addTo('PLt', ytTrack('v2'));
      http.handler = (_) => (status: 204, json: null);
      await ctrl().removeFrom('PLt', ytTrack('v1'));

      // YouTube still lists the playlist as it was before both changes.
      http.handler = (r) => r.uri.pathSegments.last == 'playlistItems'
          ? ok({
              'items': [item('v1'), item('v3')],
            })
          : ok({
              'items': [video('v3', category: '10')],
            });
      await container
          .read(youTubeRefreshProvider.notifier)
          .refreshPlaylist('PLt');
      expect(await cached('PLt'), ['v3', 'v2']);
    });
  });

  group('Liked music', () {
    Future<List<String>> likes() async => [
      for (final t in await repo.likes()) t.uri,
    ];

    setUp(() async {
      await repo.saveLikes([
        const YtVideo(id: 'v1', title: 'Song v1', channelTitle: 'Mara Vale'),
        const YtVideo(id: 'v3', title: 'Song v3', channelTitle: 'Mara Vale'),
      ]);
    });

    test('the heart likes the song on YouTube and lists it first', () async {
      container
          .read(saveTargetProvider.notifier)
          .set(const SaveTarget(likedVideosId, 'Liked music'));
      http.handler = (_) => (status: 204, json: null);
      final outcome = await ctrl().toggle(ytTrack('v2'));
      expect(outcome.message, 'Saved to Liked music');
      final r = http.requests.single;
      expect((r.method, r.uri.path), ('POST', '/youtube/v3/videos/rate'));
      expect(r.uri.queryParameters, {'id': 'v2', 'rating': 'like'});
      expect(await likes(), ['v2', 'v1', 'v3']);
      await until(() => saved('v2'));
    });

    test('removing clears the rating', () async {
      http.handler = (_) => (status: 204, json: null);
      final outcome = await ctrl().removeFrom(likedVideosId, ytTrack('v1'));
      expect(outcome.result, SaveResult.removed);
      expect(http.requests.single.uri.queryParameters, {
        'id': 'v1',
        'rating': 'none',
      });
      expect(await likes(), ['v3']);
    });

    test('a refused unlike puts the song back', () async {
      http.handler = (_) => error(500, {});
      final outcome = await ctrl().removeFrom(likedVideosId, ytTrack('v1'));
      expect(outcome.result, SaveResult.failed);
      expect(await likes(), ['v1', 'v3']);
    });

    test('a lagging sync does not undo a fresh like or unlike', () async {
      http.handler = (_) => (status: 204, json: null);
      await ctrl().addTo(likedVideosId, ytTrack('v2'));
      await ctrl().removeFrom(likedVideosId, ytTrack('v1'));

      // YouTube still lists the likes as they were before both changes.
      http.handler = (r) => switch (r.uri.pathSegments.last) {
        'videos' when r.uri.queryParameters['myRating'] == 'like' => ok({
          'items': [video('v1'), video('v3')],
        }),
        _ => ok({'items': <Object?>[]}),
      };
      final fresh = newContainer()..listen(youTubeSyncProvider, (_, _) {});
      addTearDown(fresh.dispose);
      fresh.read(youTubePendingEditsProvider)
        ..added(likedVideosId, const YtPlaylistEntry(id: 'v2', videoId: 'v2'))
        ..removed(likedVideosId, 'v1');
      final sync = fresh.read(youTubeSyncProvider.notifier);
      await sync.sync();
      await sync.whenIdle();
      expect(await likes(), ['v2', 'v3']);
    });
  });

  test('sync stores playlist item ids', () async {
    http.handler = youtube;
    // Sync is built first, as in bootstrap.
    final fresh = newContainer()..listen(youTubeSyncProvider, (_, _) {});
    addTearDown(fresh.dispose);
    final sync = fresh.read(youTubeSyncProvider.notifier);
    await sync.sync();
    await sync.whenIdle();
    expect(await repo.playlistItemIds('PLa', 'v1'), ['item-v1']);
    expect(await repo.playlistItemIds('PLb', 'v4'), ['item-v4']);
  });
}
