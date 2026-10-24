import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:freezed_annotation/freezed_annotation.dart'
    show immutable, visibleForTesting;
import 'package:noir/integrations/youtube_music/json_nav.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/integrations/youtube_music/ytm_parsers.dart';

enum InnerTubeErrorKind { network, timeout, rateLimited, http, parse }

class InnerTubeException implements Exception {
  const InnerTubeException(this.kind, this.message, {this.statusCode});

  final InnerTubeErrorKind kind;

  /// User-facing explanation.
  final String message;
  final int? statusCode;

  @override
  String toString() => statusCode == null
      ? 'InnerTubeException(${kind.name})'
      : 'InnerTubeException(${kind.name} $statusCode)';
}

/// YouTube Music search filters (the `params` the web client sends).
enum YtmSearchFilter {
  songs('EgWKAQIIAWoMEA4QChADEAQQCRAF'),
  videos('EgWKAQIQAWoMEA4QChADEAQQCRAF'),
  albums('EgWKAQIYAWoMEA4QChADEAQQCRAF'),
  artists('EgWKAQIgAWoMEA4QChADEAQQCRAF'),

  /// Playlists made by users.
  playlists('EgWKAQIoAWoMEA4QChADEAQQCRAF'),

  /// Playlists curated by YouTube Music.
  featuredPlaylists('EgeKAQQoADgBagwQDhAKEAMQBBAJEAU=');

  YtmSearchFilter(this.params);

  final String params;
}

/// Anonymous client for YouTube Music's internal web API (InnerTube,
/// `WEB_REMIX`), used for discovery only: home feed, radio, search,
/// playlists and albums. Metadata only — playback stays on the official
/// player by video id.
///
/// Hard rule: requests carry no cookies, OAuth tokens or anything else tied
/// to the user's Google account. The only identifier is an anonymous
/// `visitorData` YouTube hands to every logged-out visitor. Give the client
/// its own [Dio]: it installs [AnonymousGuard] on it.
class InnerTubeClient {
  InnerTubeClient({
    required this._dio,
    String? gl,
    this.hl = 'en',
    this.retryDelay = const Duration(milliseconds: 500),
    this.timeout = const Duration(seconds: 20),
  }) : gl = gl ?? systemCountryCode() {
    _dio.interceptors.add(const AnonymousGuard());
  }

  final Dio _dio;
  final String gl;
  final String hl;
  final Duration retryDelay;

  /// Upper bound for one request, including connecting.
  final Duration timeout;

  static const origin = 'https://music.youtube.com';
  static const _base = '$origin/youtubei/v1';
  static const clientName = 'WEB_REMIX';

  /// Numeric id of WEB_REMIX for the `X-YouTube-Client-Name` header.
  static const _clientNameId = '67';

  /// Used when the live version cannot be read from music.youtube.com.
  static const fallbackClientVersion = '1.20261020.10.00';
  static const userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
  static const _maxAttempts = 3;
  static const _maxRetryAfter = Duration(seconds: 10);

  Future<InnerTubeSession>? _session;
  String? _visitorData;

  // ------------------------------------------------------------- public --

  /// The home feed. [params] selects a mood chip ([YtmChip.params]).
  Future<YtmHomePage> home({String? params}) => _call('browse', {
    'browseId': 'FEmusic_home',
    'params': ?params,
  }, parseHome);

  Future<YtmHomePage> homeMore(String continuation) =>
      _call('browse', {'continuation': continuation}, parseHome);

  /// Endless radio seeded by [videoId].
  Future<YtmTrackPage> radio(String videoId) =>
      upNext(videoId, playlistId: 'RDAMVM$videoId');

  /// The queue YouTube Music would play after [videoId], optionally within
  /// [playlistId] (album, playlist or radio).
  Future<YtmTrackPage> upNext(String videoId, {String? playlistId}) => _call(
    'next',
    {'videoId': videoId, 'playlistId': ?playlistId, 'isAudioOnly': true},
    parseNext,
  );

  /// Next page of [radio] / [upNext] ([YtmTrackPage.continuation]).
  Future<YtmTrackPage> radioMore(String continuation, {String? playlistId}) =>
      _call('next', {
        'continuation': continuation,
        'playlistId': ?playlistId,
        'isAudioOnly': true,
      }, parseNext);

  Future<YtmSearchPage> search(
    String query, {
    YtmSearchFilter filter = YtmSearchFilter.songs,
  }) => _call('search', {'query': query, 'params': filter.params}, parseSearch);

  Future<YtmSearchPage> searchMore(String continuation) =>
      _call('search', {'continuation': continuation}, parseSearch);

  Future<YtmSearchSuggestions> searchSuggestions(String query) => _call(
    'music/get_search_suggestions',
    {'input': query},
    parseSearchSuggestions,
  );

  /// A playlist by id (`RDCLAK…`, `PL…`) or browse id (`VL…`).
  Future<YtmCollection> playlist(String playlistId) {
    final browseId = playlistId.startsWith('VL') ? playlistId : 'VL$playlistId';
    return _call('browse', {
      'browseId': browseId,
    }, (json) => parseCollection(json, id: browseId));
  }

  /// An album by browse id (`MPREb_…`).
  Future<YtmCollection> album(String browseId) => _call('browse', {
    'browseId': browseId,
  }, (json) => parseCollection(json, id: browseId));

  /// More tracks of a long playlist ([YtmCollection.continuation]).
  Future<YtmTrackPage> playlistMore(String continuation) => _call('browse', {
    'continuation': continuation,
  }, parsePlaylistContinuation);

  /// Most video ids `music/get_queue` takes in one request.
  static const queueBatchSize = 50;

  /// What YouTube Music knows about [videoIds] (title, artist, duration,
  /// artwork), keyed by video id; ids it does not know are missing.
  /// Asks in batches of [queueBatchSize].
  Future<Map<String, YtmQueueEntry>> queue(List<String> videoIds) async {
    final ids = videoIds.toSet().toList();
    final entries = <String, YtmQueueEntry>{};
    for (var i = 0; i < ids.length; i += queueBatchSize) {
      final end = i + queueBatchSize < ids.length
          ? i + queueBatchSize
          : ids.length;
      entries.addAll(
        await _call('music/get_queue', {
          'videoIds': ids.sublist(i, end),
        }, parseQueue),
      );
    }
    return entries;
  }

  // ---------------------------------------------------------- requests --

  Future<T> _call<T>(
    String endpoint,
    Map<String, Object?> body,
    T Function(Map<String, Object?> json) parser,
  ) async {
    final json = await _post(endpoint, body);
    try {
      return parser(json);
    } on FormatException {
      throw _parseError;
      // A shape the defensive parsers still did not anticipate must surface
      // as a typed error, not crash the caller. The response is never logged.
      // ignore: avoid_catching_errors
    } on TypeError {
      throw _parseError;
    }
  }

  @visibleForTesting
  Map<String, Object?> requestBody(
    InnerTubeSession session,
    Map<String, Object?> body,
  ) => {
    'context': {
      'client': {
        'clientName': clientName,
        'clientVersion': session.clientVersion,
        'hl': hl,
        'gl': gl,
        'visitorData': ?_visitorData,
      },
    },
    ...body,
  };

  @visibleForTesting
  Map<String, String> requestHeaders(InnerTubeSession session) => {
    'Content-Type': 'application/json',
    'Accept-Language': hl,
    'User-Agent': userAgent,
    'Origin': origin,
    'Referer': '$origin/',
    'X-YouTube-Client-Name': _clientNameId,
    'X-YouTube-Client-Version': session.clientVersion,
    'X-Goog-Visitor-Id': ?_visitorData,
  };

  Future<Map<String, Object?>> _post(
    String endpoint,
    Map<String, Object?> body,
  ) async {
    final session = await (_session ??= _bootstrap());
    for (var attempt = 1; ; attempt++) {
      try {
        final response = await _dio
            .post<Object?>(
              '$_base/$endpoint',
              queryParameters: const {'prettyPrint': 'false'},
              data: requestBody(session, body),
              options: Options(
                headers: requestHeaders(session),
                responseType: ResponseType.json,
                sendTimeout: timeout,
                receiveTimeout: timeout,
              ),
            )
            .timeout(timeout);
        final data = response.data;
        if (data is! Map) {
          throw const InnerTubeException(
            InnerTubeErrorKind.parse,
            'YouTube Music sent an unexpected response.',
          );
        }
        final json = data.cast<String, Object?>();
        _visitorData ??= navString(json, ['responseContext', 'visitorData']);
        return json;
      } on TimeoutException {
        if (attempt < _maxAttempts) {
          await _backoff(attempt);
          continue;
        }
        throw _timeoutError;
      } on DioException catch (e) {
        final error = _classify(e);
        final transient =
            error.kind == InnerTubeErrorKind.network ||
            error.kind == InnerTubeErrorKind.timeout ||
            error.kind == InnerTubeErrorKind.rateLimited ||
            (error.statusCode ?? 0) >= 500;
        if (transient && attempt < _maxAttempts) {
          await _backoff(attempt, retryAfter: _retryAfter(e.response));
          continue;
        }
        throw error;
      }
    }
  }

  /// Exponential backoff: 0.5 s, 1 s, … or the server's `Retry-After`.
  Future<void> _backoff(int attempt, {Duration? retryAfter}) =>
      Future<void>.delayed(retryAfter ?? retryDelay * (1 << (attempt - 1)));

  static Duration? _retryAfter(Response<Object?>? response) {
    final seconds = int.tryParse(
      response?.headers.value('retry-after')?.trim() ?? '',
    );
    if (seconds == null || seconds < 0) return null;
    final wait = Duration(seconds: seconds);
    return wait > _maxRetryAfter ? _maxRetryAfter : wait;
  }

  static const _parseError = InnerTubeException(
    InnerTubeErrorKind.parse,
    'YouTube Music changed something NOIR relies on. Try again later.',
  );

  static const _timeoutError = InnerTubeException(
    InnerTubeErrorKind.timeout,
    'YouTube Music is taking too long to respond.',
  );

  static InnerTubeException _classify(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return _timeoutError;
      case DioExceptionType.transformTimeout:
        return _timeoutError;
      case DioExceptionType.badResponse:
        break;
      case DioExceptionType.connectionError:
      case DioExceptionType.badCertificate:
      case DioExceptionType.cancel:
      case DioExceptionType.unknown:
        if (e.error is FormatException) {
          return const InnerTubeException(
            InnerTubeErrorKind.parse,
            'YouTube Music sent an unexpected response.',
          );
        }
        return const InnerTubeException(
          InnerTubeErrorKind.network,
          "Couldn't reach YouTube Music. Check your internet connection.",
        );
    }
    final status = e.response?.statusCode ?? 0;
    if (status == 429) {
      return const InnerTubeException(
        InnerTubeErrorKind.rateLimited,
        'YouTube Music is limiting requests. Try again in a minute.',
        statusCode: 429,
      );
    }
    return InnerTubeException(
      InnerTubeErrorKind.http,
      status >= 500
          ? 'YouTube Music is having trouble right now. Try again later.'
          : 'YouTube Music refused the request.',
      statusCode: status,
    );
  }

  // --------------------------------------------------------- bootstrap --

  /// Reads the current web client version and an anonymous visitorData
  /// from music.youtube.com. Never fails: falls back to
  /// [fallbackClientVersion], and visitorData is then taken from the first
  /// API response.
  Future<InnerTubeSession> _bootstrap() async {
    try {
      final response = await _dio
          .get<String>(
            '$origin/sw.js_data',
            options: Options(
              headers: {'User-Agent': userAgent, 'Accept-Language': hl},
              responseType: ResponseType.plain,
              sendTimeout: timeout,
              receiveTimeout: timeout,
            ),
          )
          .timeout(timeout);
      final session = parseSwJsData(response.data ?? '');
      _visitorData ??= session.visitorData;
      return session;
    } on DioException {
      return const InnerTubeSession(clientVersion: fallbackClientVersion);
    } on TimeoutException {
      return const InnerTubeSession(clientVersion: fallbackClientVersion);
    }
  }
}

@immutable
class InnerTubeSession {
  const InnerTubeSession({required this.clientVersion, this.visitorData});

  final String clientVersion;

  /// Anonymous visitor id (not tied to any account).
  final String? visitorData;
}

/// Parses `music.youtube.com/sw.js_data`: `)]}'` followed by a JSON array
/// whose config row holds the client version and visitorData. Positions are
/// checked loosely so a reshuffle degrades to the fallback version.
@visibleForTesting
InnerTubeSession parseSwJsData(String text) {
  Object? json;
  try {
    final start = text.indexOf('[');
    json = start < 0 ? null : jsonDecode(text.substring(start));
  } on FormatException {
    json = null;
  }
  final row = navList(json, [0, 2, 0, 0]);
  final version = RegExp(r'^1\.\d{8}\.\d{2}\.\d{2}$');
  String? clientVersion;
  for (final v in row) {
    if (v is String && version.hasMatch(v)) {
      clientVersion = v;
      break;
    }
  }
  final visitor = row.length > 13 ? row[13] : null;
  return InnerTubeSession(
    clientVersion: clientVersion ?? InnerTubeClient.fallbackClientVersion,
    visitorData: visitor is String && visitor.length > 16 ? visitor : null,
  );
}

/// Two-letter country of the system locale (`en_US` → `US`), or `US`.
String systemCountryCode([String? localeName]) {
  String name;
  try {
    name = localeName ?? Platform.localeName;
  } on Object {
    return 'US';
  }
  final m = RegExp('[_-]([A-Za-z]{2})(?![A-Za-z])').firstMatch(name);
  return m?.group(1)?.toUpperCase() ?? 'US';
}

/// Removes anything that could tie a request to a Google account. Installed
/// on the InnerTube client's own Dio as a last line of defence.
class AnonymousGuard extends Interceptor {
  const AnonymousGuard();

  static const forbiddenHeaders = {
    'cookie',
    'authorization',
    'x-goog-authuser',
    'x-goog-pageid',
    'x-youtube-identity-token',
  };

  @override
  void onRequest(RequestOptions options, RequestInterceptorHandler handler) {
    options.headers.removeWhere(
      (name, _) => forbiddenHeaders.contains(name.toLowerCase()),
    );
    handler.next(options);
  }
}
