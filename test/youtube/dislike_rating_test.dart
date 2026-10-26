import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/features/youtube/data/youtube_repository.dart';
import 'package:noir/integrations/youtube_data/youtube_api.dart';

import '../helpers/fake_http.dart';
import '../helpers/fake_innertube_client.dart';
import '../helpers/test_database.dart';
import 'youtube_fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late FakeHttp http;
  late FakeAccount account;
  late ProviderContainer container;

  setUp(() async {
    db = inMemoryDatabase();
    http = FakeHttp((_) => (status: 204, json: null));
    account = FakeAccount()..set(AccountStatus.connected, canWrite: true);
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        httpClientProvider.overrideWithValue(http.dio()),
        accountServiceProvider.overrideWithValue(account),
      ],
    )..listen(dislikesProvider, (_, _) {});
    await YouTubeRepository(db).saveLikes(const [
      YtVideo(id: 'v1', title: 'Song v1', channelTitle: 'Artist'),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  DislikesController ctrl() => container.read(dislikesProvider.notifier);

  test('a dislike goes to YouTube and replaces the like', () async {
    expect(await ctrl().dislikeSong(ytTrack('v1')), isTrue);
    final r = http.requests.single;
    expect((r.method, r.uri.path), ('POST', '/youtube/v3/videos/rate'));
    expect(r.uri.queryParameters, {'id': 'v1', 'rating': 'dislike'});
    expect(await YouTubeRepository(db).likes(), isEmpty);
    expect(container.read(dislikesProvider).hides(ytTrack('v1')), isTrue);
  });

  test('allowing the song again clears the rating', () async {
    await ctrl().dislikeSong(ytTrack('v2'));
    await ctrl().undoSong('v2');
    expect(http.requests.last.uri.queryParameters['rating'], 'none');
    expect(container.read(dislikesProvider).isEmpty, isTrue);
  });

  test('without the write permission the dislike stays in NOIR', () async {
    account.set(AccountStatus.connected);
    expect(await ctrl().dislikeSong(ytTrack('v2')), isFalse);
    expect(http.requests, isEmpty);
    expect(container.read(dislikesProvider).hides(ytTrack('v2')), isTrue);
  });

  test('a refused dislike still hides the song', () async {
    http.handler = (_) => (status: 500, json: <String, Object?>{});
    expect(await ctrl().dislikeSong(ytTrack('v2')), isFalse);
    expect(container.read(dislikesProvider).hides(ytTrack('v2')), isTrue);
  });

  test('dislikes and blocked artists are stored on this device', () async {
    await ctrl().dislikeSong(ytTrack('v2', artist: 'Face'));
    await ctrl().blockArtist('Face');
    await Future<void>.delayed(Duration.zero);
    final fresh = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        accountServiceProvider.overrideWithValue(account),
      ],
    );
    addTearDown(fresh.dispose);
    fresh.listen(dislikesProvider, (_, _) {});
    for (var i = 0; i < 50 && fresh.read(dislikesProvider).isEmpty; i++) {
      await Future<void>.delayed(Duration.zero);
    }
    final loaded = fresh.read(dislikesProvider);
    expect(loaded.songs.keys, ['v2']);
    expect(loaded.hides(ytTrack('x', artist: 'face')), isTrue);
  });
}
