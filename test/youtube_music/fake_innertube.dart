import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

/// A recorded YouTube Music response, trimmed and anonymised
/// (see `fixtures/`).
Map<String, Object?> fixture(String name) => (jsonDecode(
  File('test/youtube_music/fixtures/$name.json').readAsStringSync(),
) as Map).cast<String, Object?>();

/// `music.youtube.com/sw.js_data` as the site serves it, with a made-up
/// visitorData and a documentation IP address.
const swJsData =
    ")]}'\n"
    '[["yt.sw.adr",null,[[["en","US",null,"203.0.113.7",null,null,null,null,'
    'null,null,null,"","","CgtGQUtFVklTSVRPUijAgICAgA%3D%3D",'
    '"Mozilla/5.0",67,"1.20991231.01.00","Windows","10.0"]]]]]';

const fakeVisitorData = 'CgtGQUtFVklTSVRPUijAgICAgA%3D%3D';

/// A request as the adapter received it (after interceptors).
class SeenRequest {
  SeenRequest(this.options, this.body);

  final RequestOptions options;
  final String body;

  Uri get uri => options.uri;
  String get path => options.uri.path;
  Map<String, Object?> get json =>
      body.isEmpty ? const {} : (jsonDecode(body) as Map).cast();

  /// Header names, lower-cased.
  Set<String> get headerNames =>
      options.headers.keys.map((k) => k.toLowerCase()).toSet();

  String? header(String name) {
    for (final e in options.headers.entries) {
      if (e.key.toLowerCase() == name.toLowerCase()) return '${e.value}';
    }
    return null;
  }
}

typedef FakeResponse = ({int status, String body, Map<String, String> headers});

FakeResponse jsonReply(Object? value, {int status = 200}) =>
    (status: status, body: jsonEncode(value), headers: const {});

FakeResponse textReply(String value, {int status = 200}) =>
    (status: status, body: value, headers: const {});

/// Throw this from a handler to simulate a dropped connection.
class NetworkDown implements Exception {
  const NetworkDown();
}

/// Dio adapter answering InnerTube calls from a handler.
class FakeInnerTube implements HttpClientAdapter {
  FakeInnerTube(this.handler);

  FakeResponse Function(SeenRequest request) handler;
  final requests = <SeenRequest>[];

  /// Added before every response, to simulate a slow server.
  Duration delay = Duration.zero;

  /// Requests to the InnerTube API (not the bootstrap).
  List<SeenRequest> get apiRequests =>
      requests.where((r) => r.path.startsWith('/youtubei/')).toList();

  Dio dio() => Dio()..httpClientAdapter = this;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = <int>[];
    if (requestStream != null) await requestStream.forEach(bytes.addAll);
    final request = SeenRequest(options, utf8.decode(bytes));
    requests.add(request);
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    final FakeResponse reply;
    try {
      reply = handler(request);
    } on NetworkDown {
      throw DioException.connectionError(
        requestOptions: options,
        reason: 'offline',
      );
    }
    final isJson = reply.body.startsWith('{') || reply.body.startsWith('[');
    return ResponseBody.fromString(
      reply.body,
      reply.status,
      headers: {
        Headers.contentTypeHeader: [
          if (isJson) Headers.jsonContentType else 'text/plain',
        ],
        for (final h in reply.headers.entries) h.key: [h.value],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

/// Answers the bootstrap and every InnerTube endpoint from fixtures, the way
/// YouTube Music would for the recorded session.
FakeResponse recordedYouTubeMusic(SeenRequest r) {
  if (r.path == '/sw.js_data') return textReply(swJsData);
  final body = r.json;
  final continuation = body['continuation'] as String?;
  switch (r.path) {
    case '/youtubei/v1/browse':
      if (continuation != null) {
        return jsonReply(
          fixture(
            continuation.startsWith('PLAYLIST')
                ? 'playlist_continuation'
                : 'home_continuation',
          ),
        );
      }
      final browseId = body['browseId'] as String? ?? '';
      if (browseId == 'FEmusic_home') return jsonReply(fixture('home'));
      if (browseId.startsWith('MPRE')) return jsonReply(fixture('album'));
      return jsonReply(fixture('playlist'));
    case '/youtubei/v1/next':
      return jsonReply(
        fixture(continuation == null ? 'next' : 'next_continuation'),
      );
    case '/youtubei/v1/search':
      return jsonReply(
        fixture(continuation == null ? 'search_songs' : 'search_continuation'),
      );
    case '/youtubei/v1/music/get_search_suggestions':
      return jsonReply(fixture('search_suggestions'));
    case '/youtubei/v1/music/get_queue':
      return jsonReply(fixture('get_queue'));
  }
  return jsonReply({'error': 'not found'}, status: 404);
}
