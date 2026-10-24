import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/integrations/lyrics/lrclib_client.dart';
import 'package:noir/integrations/lyrics/lrclib_source.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_http.dart';

Map<String, Object?> record({
  String track = 'Blinding Lights',
  String artist = 'The Weeknd',
  double duration = 200,
  String? synced = '[00:01.00] Yeah\n[00:05.00] I been tryna call',
  String? plain = 'Yeah\nI been tryna call',
  bool instrumental = false,
}) => {
  'id': 1,
  'trackName': track,
  'artistName': artist,
  'albumName': 'After Hours',
  'duration': duration,
  'instrumental': instrumental,
  'plainLyrics': plain,
  'syncedLyrics': synced,
};

const notFound = (
  status: 404,
  json: {'code': 404, 'name': 'TrackNotFound', 'message': 'Failed'},
);

LyricsRequest youTube(String title, String channel, {int seconds = 200}) =>
    LyricsRequest(
      id: 'yt:abc',
      source: MediaSource.youtube,
      title: title,
      artist: channel,
      duration: Duration(seconds: seconds),
    );

void main() {
  group('LrclibClient', () {
    test('get sends the query and a User-Agent, parses the record', () async {
      final http = FakeHttp((_) => ok(record()));
      final client = LrclibClient(http.dio());
      final r = await client.get(
        trackName: 'Blinding Lights',
        artistName: 'The Weeknd',
        albumName: 'After Hours',
        duration: const Duration(seconds: 200, milliseconds: 400),
      );
      final req = http.requests.single;
      expect(req.uri.path, '/api/get');
      expect(req.uri.queryParameters, {
        'track_name': 'Blinding Lights',
        'artist_name': 'The Weeknd',
        'album_name': 'After Hours',
        'duration': '200',
      });
      expect(req.options.headers['User-Agent'], startsWith('NOIR/'));
      expect(r!.trackName, 'Blinding Lights');
      expect(r.duration, const Duration(seconds: 200));
      expect(r.syncedLyrics, contains('Yeah'));
    });

    test('get answers null on 404; other errors throw', () async {
      final http = FakeHttp((_) => notFound);
      final client = LrclibClient(http.dio());
      expect(await client.get(trackName: 'x', artistName: 'y'), isNull);
      http.handler = (_) => error(503, {'name': 'ServerOverloaded'});
      await expectLater(
        client.get(trackName: 'x', artistName: 'y'),
        throwsA(isA<DioException>()),
      );
    });

    test('search parses a list and treats blank lyrics as missing', () async {
      final http = FakeHttp(
        (_) => ok([record(), record(track: 'Other', synced: ' ', plain: null)]),
      );
      final results = await LrclibClient(http.dio()).search(query: 'q');
      expect(http.requests.single.uri.queryParameters, {'q': 'q'});
      expect(results, hasLength(2));
      expect(results.last.hasContent, isFalse);
    });
  });

  group('LrclibLyricsSource', () {
    test('exact match returns synced lyrics after one request', () async {
      final http = FakeHttp((_) => ok(record()));
      final source = LrclibLyricsSource(LrclibClient(http.dio()));
      final lyrics = await source.find(
        youTube(
          'The Weeknd - Blinding Lights (Official Video)',
          'TheWeekndVEVO',
        ),
      );
      expect(lyrics, isA<SyncedLyrics>());
      expect((lyrics! as SyncedLyrics).lines.first.text, 'Yeah');
      expect(lyrics.source, 'LRCLIB');
      expect(http.requests, hasLength(1));
      expect(
        http.requests.single.uri.queryParameters['track_name'],
        'Blinding Lights',
      );
    });

    test('falls back to search and picks by title and duration', () async {
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/get')) return notFound;
        return ok([
          record(track: 'Save Your Tears', duration: 215),
          record(duration: 260), // Right song, wrong length (extended mix).
          record(duration: 203, synced: null), // Plain only, close length.
          record(duration: 201),
        ]);
      });
      final source = LrclibLyricsSource(LrclibClient(http.dio()));
      final lyrics = await source.find(
        youTube('Blinding Lights', 'The Weeknd - Topic'),
      );
      expect(lyrics, isA<SyncedLyrics>());
      expect(http.requests.where((r) => r.uri.path.endsWith('/search')), [
        isA<FakeRequest>().having((r) => r.uri.queryParameters, 'query', {
          'track_name': 'Blinding Lights',
          'artist_name': 'The Weeknd',
        }),
      ]);
    });

    test('a busy /get still lets search answer', () async {
      final http = FakeHttp(
        (r) => r.uri.path.endsWith('/get')
            ? error(503, {'name': 'ServerOverloaded'})
            : ok([record()]),
      );
      final lyrics = await LrclibLyricsSource(LrclibClient(http.dio()))
          .find(youTube('Blinding Lights', 'The Weeknd'));
      expect(lyrics, isA<SyncedLyrics>());
    });

    test('nothing close enough → null after a free-text search', () async {
      final http = FakeHttp((r) {
        if (r.uri.path.endsWith('/get')) return notFound;
        return ok([record(track: 'Completely Different')]);
      });
      final lyrics = await LrclibLyricsSource(LrclibClient(http.dio()))
          .find(youTube('Blinding Lights', 'The Weeknd'));
      expect(lyrics, isNull);
      expect(http.requests.last.uri.queryParameters['q'], isNotNull);
    });

    test('maps instrumental and plain-only records', () {
      expect(
        LrclibLyricsSource.toLyrics(
          LrclibRecord.fromJson(record(instrumental: true, synced: null)),
        ),
        isA<InstrumentalLyrics>(),
      );
      expect(
        LrclibLyricsSource.toLyrics(
          LrclibRecord.fromJson(record(synced: null)),
        ),
        isA<PlainLyrics>(),
      );
    });
  });

  group('LyricsRepository', () {
    test('caches answers (also "none") and evicts the oldest', () async {
      final http = FakeHttp((_) => ok(record()));
      final repo = LyricsRepository([
        LrclibLyricsSource(LrclibClient(http.dio())),
      ], capacity: 2);
      final a = youTube('Blinding Lights', 'The Weeknd');
      await repo.find(a);
      await repo.find(a);
      expect(http.requests, hasLength(1));

      await repo.find(youTube('Song B', 'X', seconds: 100));
      await repo.find(youTube('Song C', 'X', seconds: 100));
      final before = http.requests.length;
      await repo.find(a); // Evicted.
      expect(http.requests.length, greaterThan(before));
    });

    test('network errors throw LyricsUnavailable and are not cached', () async {
      final http = FakeHttp((_) => error(500, {}));
      final repo = LyricsRepository([
        LrclibLyricsSource(LrclibClient(http.dio())),
      ]);
      final a = youTube('Blinding Lights', 'The Weeknd');
      await expectLater(repo.find(a), throwsA(isA<LyricsUnavailable>()));
      http.handler = (_) => ok(record());
      expect(await repo.find(a), isA<SyncedLyrics>());
    });

    test('a cancelled lookup rethrows the cancellation', () async {
      final http = FakeHttp((_) => ok(record()));
      final repo = LyricsRepository([
        LrclibLyricsSource(LrclibClient(http.dio())),
      ]);
      final cancel = CancelToken()..cancel();
      await expectLater(
        repo.find(youTube('Blinding Lights', 'The Weeknd'), cancel: cancel),
        throwsA(
          isA<DioException>().having(
            (e) => e.type,
            'type',
            DioExceptionType.cancel,
          ),
        ),
      );
    });
  });
}
