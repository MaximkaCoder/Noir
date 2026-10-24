import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/lyrics/application/lyrics_providers.dart';
import 'package:noir/features/lyrics/domain/lrc.dart';
import 'package:noir/features/lyrics/domain/lyrics.dart';
import 'package:noir/integrations/lyrics/ytm_lyrics_source.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_lyrics.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_innertube_client.dart';
import 'fake_innertube.dart';

const _browseId = 'MPLYt_dcYZhAh5urI-1';

Duration ms(int v) => Duration(milliseconds: v);

/// The recorded lyrics answers: the Lyrics tab, timings for the Android
/// client, plain text for the web client.
FakeResponse _lyricsServer(SeenRequest r, {bool timed = true}) {
  if (r.path == '/sw.js_data') return textReply(swJsData);
  if (r.path == '/youtubei/v1/next') {
    return jsonReply(fixture('next_lyrics_tab'));
  }
  final client = ((r.json['context']! as Map)['client'] as Map)['clientName'];
  if (client == 'ANDROID_MUSIC') {
    return jsonReply(timed ? fixture('lyrics_timed') : fixture('lyrics_plain'));
  }
  return jsonReply(fixture('lyrics_plain'));
}

void main() {
  group('parsers', () {
    test('find the Lyrics tab, or nothing when it has no endpoint', () {
      expect(parseLyricsBrowseId(fixture('next_lyrics_tab')), _browseId);
      expect(parseLyricsBrowseId(fixture('next_no_lyrics_tab')), isNull);
    });

    test('timed lyrics keep start and end of every line', () {
      final lyrics = parseTimedLyrics(fixture('lyrics_timed'))!;
      final lines = lyrics.lines!;
      expect(lines, hasLength(6));
      // "♪" marks an instrumental break.
      expect(lines.first.text, '');
      expect(lines[1].text, 'First sung line here');
      expect(lines[1].start, ms(18810));
      expect(lines[1].end, ms(22870));
      expect(lyrics.provider, 'Musixmatch');
      expect(lyrics.text, isNull);
    });

    test('plain lyrics come with their provider', () {
      final lyrics = parsePlainLyrics(fixture('lyrics_plain'))!;
      expect(lyrics.text, startsWith('First plain line\nSecond plain line'));
      expect(lyrics.provider, 'Musixmatch');
      expect(lyrics.lines, isNull);
    });

    test('each parser ignores the other answer', () {
      expect(parseTimedLyrics(fixture('lyrics_plain')), isNull);
      expect(parsePlainLyrics(fixture('lyrics_timed')), isNull);
      expect(parseTimedLyrics(const {}), isNull);
    });
  });

  group('InnerTubeClient', () {
    late FakeInnerTube http;
    InnerTubeClient client() =>
        InnerTubeClient(dio: http.dio(), gl: 'US', retryDelay: Duration.zero);

    test('asks the Lyrics tab with the web client', () async {
      http = FakeInnerTube(_lyricsServer);
      expect(await client().lyricsBrowseId('lYBUbBu4W08'), _browseId);
      final r = http.apiRequests.single;
      expect(r.path, '/youtubei/v1/next');
      expect(r.json['videoId'], 'lYBUbBu4W08');
    });

    test(
      'timed lyrics come from the Android app client, anonymously',
      () async {
        http = FakeInnerTube(_lyricsServer);
        final dio = http.dio()
          ..options.headers.addAll({'Cookie': 'SAPISID=secret'});
        final c = InnerTubeClient(
          dio: dio,
          gl: 'US',
          retryDelay: Duration.zero,
        );

        final lyrics = await c.lyrics(_browseId);
        expect(lyrics!.lines, hasLength(6));

        final r = http.apiRequests.single;
        expect(r.path, '/youtubei/v1/browse');
        expect(r.json['browseId'], _browseId);
        final ctx = (r.json['context']! as Map)['client'] as Map;
        expect(ctx['clientName'], 'ANDROID_MUSIC');
        expect(ctx['clientVersion'], '7.27.52');
        expect(ctx['androidSdkVersion'], 34);
        expect(ctx.containsKey('visitorData'), isFalse);
        expect(r.header('User-Agent'), startsWith('com.google.android.apps'));
        expect(r.header('X-YouTube-Client-Name'), '21');
        expect(r.headerNames, isNot(contains('cookie')));
      },
    );

    test('without timings it falls back to the web text', () async {
      http = FakeInnerTube((r) => _lyricsServer(r, timed: false));
      final lyrics = await client().lyrics(_browseId);
      expect(lyrics!.text, startsWith('First plain line'));
      final clients = [
        for (final r in http.apiRequests)
          ((r.json['context']! as Map)['client'] as Map)['clientName'],
      ];
      expect(clients, ['ANDROID_MUSIC', 'WEB_REMIX']);
    });

    test('a refused app client still gets the plain lyrics', () async {
      http = FakeInnerTube((r) {
        final ctx = r.path == '/sw.js_data'
            ? null
            : ((r.json['context']! as Map)['client'] as Map)['clientName'];
        if (ctx == 'ANDROID_MUSIC') return jsonReply(const {}, status: 400);
        return _lyricsServer(r);
      });
      final lyrics = await client().lyrics(_browseId);
      expect(lyrics!.text, isNotNull);
    });
  });

  group('YtmLyricsSource', () {
    const youTube = LyricsRequest(
      id: 'yt:vid',
      source: MediaSource.youtube,
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
      videoId: 'vid',
    );
    const local = LyricsRequest(
      id: '7',
      source: MediaSource.local,
      title: 'Never Gonna Give You Up',
      artist: 'Rick Astley',
      duration: Duration(seconds: 213),
    );
    YtmLyrics timed() => parseTimedLyrics(fixture('lyrics_timed'))!;

    test('YouTube tracks: synced lines with their own end times', () async {
      final ytm = FakeInnerTubeClient()
        ..lyricsTabs['vid'] = _browseId
        ..lyricsPages[_browseId] = timed();
      final lyrics = await YtmLyricsSource.byVideo(ytm).find(youTube);
      expect(lyrics, isA<SyncedLyrics>());
      expect(lyrics!.source, 'YouTube Music · Musixmatch');
      final lines = (lyrics as SyncedLyrics).lines;
      expect(lines[1].end, ms(22870));
      // Karaoke times the words within the line's own cue.
      expect(lineEnd(lines, 1), ms(22870));
      expect(lineWordTimings(lines, 1).last.end, lessThan(ms(22870)));
      expect(ytm.calls, ['lyricsBrowseId vid', 'lyrics $_browseId']);
    });

    test(
      'nothing without a Lyrics tab, and local files are not its job',
      () async {
        final ytm = FakeInnerTubeClient();
        expect(await YtmLyricsSource.byVideo(ytm).find(youTube), isNull);
        expect(await YtmLyricsSource.byVideo(ytm).find(local), isNull);
        expect(await YtmLyricsSource.bySearch(ytm).find(youTube), isNull);
        expect(ytm.calls, ['lyricsBrowseId vid']);
      },
    );

    test('local files: the matching song from search, within 3 s', () async {
      Track song(
        String id,
        int seconds, {
        String title = 'Never Gonna Give You Up',
      }) => Track(
        id: 'yt:$id',
        source: MediaSource.youtube,
        title: title,
        uri: id,
        artist: 'Rick Astley',
        duration: Duration(seconds: seconds),
      );
      final ytm = FakeInnerTubeClient()
        ..searchPages[YtmSearchFilter.songs] = YtmSearchPage(
          items: [
            YtmTrackItem(song('long', 230)),
            YtmTrackItem(song('other', 213, title: 'Together Forever')),
            YtmTrackItem(song('right', 215)),
          ],
        )
        ..lyricsTabs['right'] = _browseId
        ..lyricsPages[_browseId] = timed();
      final lyrics = await YtmLyricsSource.bySearch(ytm).find(local);
      expect(lyrics, isA<SyncedLyrics>());
      expect(ytm.calls, contains('lyricsBrowseId right'));
    });

    test('failures surface as LyricsUnavailable', () async {
      final ytm = FakeInnerTubeClient()
        ..error = const InnerTubeException(
          InnerTubeErrorKind.network,
          'offline',
        );
      await expectLater(
        YtmLyricsSource.byVideo(ytm).find(youTube),
        throwsA(isA<LyricsUnavailable>()),
      );
    });
  });

  group('LyricsRepository order', () {
    const request = LyricsRequest(
      id: 'yt:vid',
      source: MediaSource.youtube,
      title: 'Song',
      videoId: 'vid',
    );

    test('timed lyrics end the search at once', () async {
      final later = _Fixed(const PlainLyrics('later', source: 'B'));
      final repo = LyricsRepository([
        _Fixed(SyncedLyrics([LyricLine(ms(0), 'a')], source: 'A')),
        later,
      ]);
      expect((await repo.find(request))!.source, 'A');
      expect(later.asked, 0);
    });

    test('plain lyrics wait for a timed answer further on', () async {
      final repo = LyricsRepository([
        _Fixed(const PlainLyrics('plain', source: 'A')),
        _Fixed(SyncedLyrics([LyricLine(ms(0), 'a')], source: 'B')),
      ]);
      expect((await repo.find(request))!.source, 'B');
    });

    test('and are the answer when none comes', () async {
      final repo = LyricsRepository([
        _Fixed(const PlainLyrics('first', source: 'A')),
        _Fixed(const PlainLyrics('second', source: 'B')),
        _Fixed(null),
      ]);
      expect((await repo.find(request))!.source, 'A');
    });

    test('an unreachable source does not hide the others', () async {
      final repo = LyricsRepository([
        _Failing(),
        _Fixed(const PlainLyrics('plain', source: 'B')),
      ]);
      expect((await repo.find(request))!.source, 'B');
      final none = LyricsRepository([_Failing(), _Fixed(null)]);
      await expectLater(none.find(request), throwsA(isA<LyricsUnavailable>()));
    });
  });
}

class _Fixed implements LyricsSource {
  _Fixed(this.answer);

  final Lyrics? answer;
  int asked = 0;

  @override
  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel}) async {
    asked++;
    return answer;
  }
}

class _Failing implements LyricsSource {
  @override
  Future<Lyrics?> find(LyricsRequest request, {CancelToken? cancel}) async =>
      throw const LyricsUnavailable('offline');
}
