import 'package:flutter_test/flutter_test.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';

import 'fake_innertube.dart';

void main() {
  late FakeInnerTube http;

  InnerTubeClient client({String gl = 'DE'}) =>
      InnerTubeClient(dio: http.dio(), gl: gl, retryDelay: Duration.zero);

  setUp(() => http = FakeInnerTube(recordedYouTubeMusic));

  group('requests', () {
    test(
      'WEB_REMIX context with live version, visitorData, hl and gl',
      () async {
        await client().home();

        final r = http.apiRequests.single;
        expect(
          r.uri.toString(),
          startsWith('https://music.youtube.com/youtubei/v1/browse?'),
        );
        expect(r.uri.queryParameters['prettyPrint'], 'false');
        expect(r.options.method, 'POST');
        final c = (r.json['context']! as Map)['client'] as Map;
        expect(c['clientName'], 'WEB_REMIX');
        expect(c['clientVersion'], '1.20991231.01.00');
        expect(c['hl'], 'en');
        expect(c['gl'], 'DE');
        expect(c['visitorData'], fakeVisitorData);
        expect(r.json['browseId'], 'FEmusic_home');
        expect(r.header('X-Goog-Visitor-Id'), fakeVisitorData);
        expect(r.header('X-YouTube-Client-Name'), '67');
        expect(r.header('X-YouTube-Client-Version'), '1.20991231.01.00');
        expect(r.header('Origin'), 'https://music.youtube.com');
      },
    );

    test('no cookies or credentials, even if the Dio was given some', () async {
      final dio = http.dio()
        ..options.headers.addAll({
          'Cookie': 'SAPISID=secret',
          'Authorization': 'Bearer token',
          'X-Goog-AuthUser': '0',
        });
      final c = InnerTubeClient(dio: dio, retryDelay: Duration.zero);

      await c.home();
      await c.search('daft punk');

      expect(http.requests, isNotEmpty);
      for (final r in http.requests) {
        expect(
          r.headerNames,
          isNot(anyOf(contains('cookie'), contains('authorization'))),
        );
        expect(r.headerNames, isNot(contains('x-goog-authuser')));
        expect(r.body, isNot(contains('SAPISID')));
      }
    });

    test('bootstraps once and reuses the session', () async {
      final c = client();
      await c.home();
      await c.radio('Z85lxckrtzg');
      await c.searchSuggestions('daft p');

      expect(http.requests.where((r) => r.path == '/sw.js_data'), hasLength(1));
      expect(http.apiRequests, hasLength(3));
    });

    test('radio asks for the RDAMVM queue, audio only', () async {
      final page = await client().radio('Z85lxckrtzg');

      final body = http.apiRequests.single.json;
      expect(http.apiRequests.single.path, '/youtubei/v1/next');
      expect(body['videoId'], 'Z85lxckrtzg');
      expect(body['playlistId'], 'RDAMVMZ85lxckrtzg');
      expect(body['isAudioOnly'], isTrue);
      expect(page.tracks, hasLength(5));

      final more = await client().radioMore(
        page.continuation!,
        playlistId: page.playlistId,
      );
      expect(http.apiRequests.last.json['continuation'], 'TEST_CONTINUATION_1');
      expect(more.tracks.first.title, 'Kiss');
    });

    test('search sends the filter params', () async {
      final c = client();
      await c.search('daft punk');
      await c.search('daft punk', filter: YtmSearchFilter.albums);

      expect(http.apiRequests.map((r) => r.json['params']), [
        YtmSearchFilter.songs.params,
        YtmSearchFilter.albums.params,
      ]);
      expect(http.apiRequests.first.json['query'], 'daft punk');
    });

    test('playlist accepts ids with or without the VL prefix', () async {
      final c = client();
      await c.playlist('PLwNv9Hhd8gZjNoQdpd2kBa3fwXNeJjzDX');
      await c.playlist('VLPLwNv9Hhd8gZjNoQdpd2kBa3fwXNeJjzDX');
      final more = await c.playlistMore('PLAYLIST_PAGE_2');

      expect(
        http.apiRequests.take(2).map((r) => r.json['browseId']),
        everyElement('VLPLwNv9Hhd8gZjNoQdpd2kBa3fwXNeJjzDX'),
      );
      expect(more.tracks, hasLength(3));
    });

    test('album and suggestions endpoints', () async {
      final c = client();
      final album = await c.album('MPREb_K8qWMWVqXGi');
      final s = await c.searchSuggestions('daft p');

      expect(album.tracks, hasLength(4));
      expect(
        http.apiRequests.last.path,
        '/youtubei/v1/music/get_search_suggestions',
      );
      expect(http.apiRequests.last.json['input'], 'daft p');
      expect(s.queries, isNotEmpty);
    });
  });

  group('bootstrap fallback', () {
    test(
      'uses the built-in version and the visitorData YouTube returns',
      () async {
        http.handler = (r) {
          if (r.path == '/sw.js_data') return textReply('', status: 503);
          return jsonReply({
            'responseContext': {'visitorData': 'FROM_RESPONSE'},
            ...fixture('search_songs'),
          });
        };
        final c = client();
        await c.search('a');
        await c.search('b');

        final first = http.apiRequests.first;
        final second = http.apiRequests.last;
        final ctx = (first.json['context']! as Map)['client'] as Map;
        expect(ctx['clientVersion'], InnerTubeClient.fallbackClientVersion);
        expect(ctx.containsKey('visitorData'), isFalse);
        expect(first.header('X-Goog-Visitor-Id'), isNull);
        expect(second.header('X-Goog-Visitor-Id'), 'FROM_RESPONSE');
      },
    );

    test('parseSwJsData reads version and visitorData', () {
      final s = parseSwJsData(swJsData);
      expect(s.clientVersion, '1.20991231.01.00');
      expect(s.visitorData, fakeVisitorData);
      expect(
        parseSwJsData('garbage').clientVersion,
        InnerTubeClient.fallbackClientVersion,
      );
    });
  });

  group('errors', () {
    test('429 is retried, honouring Retry-After', () async {
      var calls = 0;
      http.handler = (r) {
        if (r.path == '/sw.js_data') return textReply(swJsData);
        calls++;
        if (calls == 1) {
          return (status: 429, body: '{}', headers: {'retry-after': '0'});
        }
        return jsonReply(fixture('home'));
      };

      final page = await client().home();
      expect(calls, 2);
      expect(page.shelves, isNotEmpty);
    });

    test('persistent 429 surfaces as rateLimited', () async {
      http.handler = (r) => r.path == '/sw.js_data'
          ? textReply(swJsData)
          : jsonReply({}, status: 429);

      await expectLater(
        client().home(),
        throwsA(
          isA<InnerTubeException>()
              .having((e) => e.kind, 'kind', InnerTubeErrorKind.rateLimited)
              .having((e) => e.statusCode, 'status', 429),
        ),
      );
      expect(http.apiRequests, hasLength(3));
    });

    test('4xx is not retried', () async {
      http.handler = (r) => r.path == '/sw.js_data'
          ? textReply(swJsData)
          : jsonReply({}, status: 400);

      await expectLater(
        client().home(),
        throwsA(
          isA<InnerTubeException>()
              .having((e) => e.kind, 'kind', InnerTubeErrorKind.http)
              .having((e) => e.statusCode, 'status', 400),
        ),
      );
      expect(http.apiRequests, hasLength(1));
    });

    test('network failure after retries', () async {
      http.handler = (r) => throw const NetworkDown();

      await expectLater(
        client().home(),
        throwsA(
          isA<InnerTubeException>().having(
            (e) => e.kind,
            'kind',
            InnerTubeErrorKind.network,
          ),
        ),
      );
      expect(http.apiRequests, hasLength(3));
    });

    test('unrecognisable response is a parse error', () async {
      http.handler = (r) => r.path == '/sw.js_data'
          ? textReply(swJsData)
          : jsonReply({'contents': 'surprise'});

      await expectLater(
        client().home(),
        throwsA(
          isA<InnerTubeException>().having(
            (e) => e.kind,
            'kind',
            InnerTubeErrorKind.parse,
          ),
        ),
      );
    });

    test('slow responses time out', () async {
      http.delay = const Duration(milliseconds: 200);
      final c = InnerTubeClient(
        dio: http.dio(),
        retryDelay: Duration.zero,
        timeout: const Duration(milliseconds: 20),
      );

      await expectLater(
        c.home(),
        throwsA(
          isA<InnerTubeException>().having(
            (e) => e.kind,
            'kind',
            InnerTubeErrorKind.timeout,
          ),
        ),
      );
    });
  });
}
