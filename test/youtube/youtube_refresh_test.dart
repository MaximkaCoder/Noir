import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/youtube/application/youtube_providers.dart';
import 'package:noir/features/youtube/application/youtube_refresh.dart';
import 'package:noir/features/youtube/application/youtube_sync.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_http.dart';
import '../helpers/test_database.dart';
import 'youtube_fakes.dart';

/// A YouTube account whose playlist "PLa" and likes can change, answering
/// conditional requests like the real API: the response etag changes with
/// the content, and a matching `If-None-Match` gets 304.
class _ChangingYouTube {
  String etagA = 'eA1';
  List<String> itemsA = ['v1', 'v2'];
  int likesVersion = 1;
  List<String> likes = ['v9'];
  bool failing = false;

  FakeReply call(FakeRequest r) {
    if (failing) {
      return error(403, {
        'error': {
          'errors': [
            {'reason': 'quotaExceeded'},
          ],
        },
      });
    }
    final q = r.uri.queryParameters;
    final ifNoneMatch = r.options.headers['If-None-Match'];
    FakeReply tagged(String etag, Map<String, Object?> body) =>
        ifNoneMatch == '"$etag"'
        ? (status: 304, json: null)
        : ok({'etag': etag, ...body});

    switch (r.uri.pathSegments.last) {
      case 'playlists':
        final all = [
          {
            'id': 'PLa',
            'etag': etagA,
            'snippet': {'title': 'Night drive'},
            'contentDetails': {'itemCount': itemsA.length},
          },
          {
            'id': 'PLb',
            'etag': 'eB1',
            'snippet': {'title': 'Focus'},
            'contentDetails': {'itemCount': 1},
          },
        ];
        if (q['id'] case final id?) {
          final one = all.where((p) => p['id'] == id).toList();
          return tagged('one-$id-${one.firstOrNull?['etag']}', {'items': one});
        }
        return ok({'items': all});
      case 'playlistItems':
        final ids = q['playlistId'] == 'PLa' ? itemsA : ['v4'];
        return ok({
          'items': [for (final id in ids) item(id)],
        });
      case 'videos':
        if (q['myRating'] == 'like') {
          return tagged('likes-$likesVersion', {
            'items': [for (final id in likes) video(id, category: '10')],
          });
        }
        return ok({
          'items': [
            for (final id in q['id']!.split(',')) video(id, category: '10'),
          ],
        });
    }
    return error(404, {});
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _ChangingYouTube yt;
  late FakeHttp http;
  late FakeAccount account;
  late ProviderContainer container;
  late YouTubeRepository repo;
  late DateTime now;

  setUp(() async {
    db = inMemoryDatabase();
    yt = _ChangingYouTube();
    http = FakeHttp(yt.call);
    account = FakeAccount();
    now = DateTime(2026, 10, 24, 12);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(http.dio()),
        accountServiceProvider.overrideWithValue(account),
        youTubeClockProvider.overrideWithValue(() => now),
      ],
    )..listen(youTubeSyncProvider, (_, _) {});
    repo = container.read(youTubeRepositoryProvider);
    // The connected account triggers the first full sync.
    await pumpEventQueue();
    await container.read(youTubeSyncProvider.notifier).whenIdle();
    http.requests.clear();
  });

  tearDown(() async {
    await container.read(youTubeSyncProvider.notifier).whenIdle();
    container.dispose();
    await db.close();
  });

  YouTubeRefreshController refresher() =>
      container.read(youTubeRefreshProvider.notifier);

  void wait(int seconds) => now = now.add(Duration(seconds: seconds));

  /// Database tables written while [action] runs.
  Future<Set<String>> writesDuring(Future<void> Function() action) async {
    final tables = <String>{};
    final sub = db.tableUpdates().listen(
      (updates) => tables.addAll(updates.map((u) => u.table)),
    );
    await action();
    await pumpEventQueue();
    await sub.cancel();
    return tables;
  }

  test('opening right after a full sync still reads the items', () async {
    wait(1);
    await refresher().refreshPlaylist('PLa');
    expect(http.requests.single.uri.pathSegments.last, 'playlistItems');
    expect(http.requests.single.uri.queryParameters['playlistId'], 'PLa');
  });

  test('a page refresh does not wait for a running full sync', () async {
    final sync = container.read(youTubeSyncProvider.notifier);
    final blocker = Completer<void>();
    unawaited(sync.sync(force: true));
    // The full sync is still running while the page refreshes.
    unawaited(sync.whenIdle().then((_) => blocker.complete()));
    await refresher().refreshPlaylist('PLa');
    expect(blocker.isCompleted, isFalse);
    expect(
      http.requests.where(
        (r) =>
            r.uri.pathSegments.last == 'playlistItems' &&
            r.uri.queryParameters['playlistId'] == 'PLa',
      ),
      isNotEmpty,
    );
    await blocker.future;
  });

  test('a page is checked at most once per 5 seconds', () async {
    await refresher().refreshPlaylist('PLa');
    expect(http.requests, hasLength(1));

    http.requests.clear();
    wait(4);
    await refresher().refreshPlaylist('PLa');
    expect(http.requests, isEmpty, reason: 'checked 4 s ago');

    // Other pages have their own throttle.
    await refresher().refreshPlaylist('PLb');
    expect(http.requests, hasLength(1));

    http.requests.clear();
    wait(2);
    await refresher().refreshPlaylist('PLa');
    expect(http.requests, hasLength(1));
  });

  test('rapid repeated opens share one request', () async {
    wait(6);
    await Future.wait([
      for (var i = 0; i < 5; i++) refresher().refreshPlaylist('PLa'),
    ]);
    expect(http.requests, hasLength(1));
  });

  test('an unchanged playlist writes nothing', () async {
    wait(6);
    final writes = await writesDuring(() => refresher().refreshPlaylist('PLa'));
    expect(http.requests, hasLength(1));
    expect(writes, isEmpty);
  });

  test('new items appear in the open list without a full sync', () async {
    final emitted = <List<String>>[];
    final sub = container.listen(youTubePlaylistTracksProvider('PLa'), (
      _,
      next,
    ) {
      if (next.value case final List<Track> tracks) {
        emitted.add([for (final t in tracks) t.uri]);
      }
    }, fireImmediately: true);
    await pumpEventQueue();
    expect(emitted.last, ['v1', 'v2']);

    // The playlist's own etag lags behind: only the items changed.
    yt.itemsA = ['v3', 'v1', 'v2'];
    wait(6);
    await refresher().refreshPlaylist('PLa');
    await pumpEventQueue();

    expect(emitted.last, ['v3', 'v1', 'v2']);
    expect(
      [for (final r in http.requests) r.uri.pathSegments.last],
      ['playlistItems', 'videos'],
    );
    expect(
      http.requests.last.uri.queryParameters['id'],
      'v3',
      reason: 'only the new video needs details',
    );
    final playlist = await repo.watchPlaylist('PLa').first;
    expect(playlist!.trackCount, 3);
    sub.close();
  });

  test('a failed refresh keeps the list and reports the reason', () async {
    final before = await repo.watchPlaylistTracks('PLa').first;
    yt.failing = true;
    wait(6);
    await refresher().refreshPlaylist('PLa');

    final state = container.read(youTubeRefreshProvider);
    expect(state.errors['PLa'], contains('allowance'));
    expect(state.running, isEmpty);
    expect(
      await repo.watchPlaylistTracks('PLa').first,
      hasLength(before.length),
    );

    // The next attempt (after the throttle) clears the error.
    yt.failing = false;
    wait(6);
    await refresher().refreshPlaylist('PLa');
    expect(container.read(youTubeRefreshProvider).errors, isEmpty);
  });

  test('likes refresh is conditional too', () async {
    wait(6);
    await refresher().refreshLikes();
    expect(http.requests.single.uri.queryParameters['myRating'], 'like');

    wait(6);
    http.requests.clear();
    final writes = await writesDuring(refresher().refreshLikes);
    expect(http.requests.single.options.headers['If-None-Match'], '"likes-1"');
    expect(writes, isEmpty);

    yt
      ..likesVersion = 2
      ..likes = ['v8', 'v9'];
    wait(6);
    await refresher().refreshLikes();
    final likes = await repo.watchLikes().first;
    expect([for (final t in likes) t.uri], ['v8', 'v9']);
  });

  test('after disconnecting nothing is requested', () async {
    account.set(AccountStatus.disconnected);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    wait(6);
    await refresher().refreshPlaylist('PLa');
    expect(http.requests, isEmpty);
  });

  test('the syncing indicator follows the refresh', () async {
    wait(6);
    final seen = <bool>[];
    container.listen(
      youTubeRefreshProvider.select((s) => s.running.contains('PLa')),
      (_, running) => seen.add(running),
    );
    await refresher().refreshPlaylist('PLa');
    expect(seen, [true, false]);
  });

  test('a deleted playlist is left to the full sync', () async {
    yt.failing = false;
    http.handler = (r) => error(404, {
      'error': {
        'errors': [
          {'reason': 'playlistNotFound'},
        ],
      },
    });
    await refresher().refreshPlaylist('PLa');
    expect(container.read(youTubeRefreshProvider).errors, isEmpty);
    expect(await repo.watchPlaylistTracks('PLa').first, hasLength(2));
  });
}
