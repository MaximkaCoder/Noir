import 'dart:async';
import 'dart:math';

import 'package:dio/dio.dart';
import 'package:noir/integrations/google_auth/desktop_oauth_flow.dart';

class YtPlaylist {
  const YtPlaylist({
    required this.id,
    required this.title,
    required this.itemCount,
    required this.etag,
    this.thumbnailUrl,
    this.privacy,
  });

  final String id;
  final String title;
  final int itemCount;

  /// Changes whenever the playlist or its items change; used to skip
  /// re-downloading unchanged playlists.
  final String etag;
  final String? thumbnailUrl;
  final String? privacy;
}

class YtVideo {
  const YtVideo({
    required this.id,
    required this.title,
    required this.channelTitle,
    this.duration,
    this.thumbnailUrl,
    this.embeddable = true,
  });

  final String id;
  final String title;
  final String channelTitle;
  final Duration? duration;
  final String? thumbnailUrl;
  final bool embeddable;
}

enum YouTubeErrorKind { quota, auth, notFound, network, server, other }

class YouTubeApiException implements Exception {
  const YouTubeApiException(this.kind, this.message);

  final YouTubeErrorKind kind;

  /// User-facing explanation.
  final String message;

  @override
  String toString() => 'YouTubeApiException(${kind.name})';
}

/// Read-only access to the YouTube Data API v3 for the signed-in user.
/// Quota costs (default 10,000 units/day): every call here costs 1 unit per
/// page.
class YouTubeApi {
  YouTubeApi({
    required Dio dio,
    required Future<String> Function({bool forceRefresh}) accessToken,
    this.retryDelay = const Duration(milliseconds: 500),
  }) : _dio = dio,
       _accessToken = accessToken;

  final Dio _dio;
  final Future<String> Function({bool forceRefresh}) _accessToken;
  final Duration retryDelay;

  static const _base = 'https://www.googleapis.com/youtube/v3';
  static const _maxAttempts = 3;

  /// Playlists the user owns (including private ones and those created in
  /// YouTube Music).
  Future<List<YtPlaylist>> myPlaylists() async {
    final items = await _paged('playlists', {
      'part': 'snippet,contentDetails,status',
      'mine': 'true',
      'maxResults': '50',
    });
    return [
      for (final p in items)
        YtPlaylist(
          id: p['id']! as String,
          etag: p['etag']! as String,
          title: _snippet(p)['title'] as String? ?? 'Untitled playlist',
          itemCount:
              ((p['contentDetails'] as Map?)?['itemCount'] as num?)?.toInt() ??
              0,
          thumbnailUrl: _thumbnail(_snippet(p)),
          privacy: (p['status'] as Map?)?['privacyStatus'] as String?,
        ),
    ];
  }

  /// Video ids of a playlist in order. Deleted and private videos are
  /// skipped — they cannot be played.
  Future<List<String>> playlistVideoIds(String playlistId) async {
    final items = await _paged('playlistItems', {
      'part': 'snippet,status',
      'playlistId': playlistId,
      'maxResults': '50',
    });
    return [
      for (final i in items)
        if (_playable(i))
          ((_snippet(i)['resourceId'] as Map?)?['videoId'] as String?) ?? '',
    ].where((id) => id.isNotEmpty).toList();
  }

  /// Full details (duration, embeddability) for up to any number of ids,
  /// fetched 50 per request.
  Future<List<YtVideo>> videos(List<String> ids) async {
    final result = <YtVideo>[];
    for (var i = 0; i < ids.length; i += 50) {
      final batch = ids.sublist(i, min(i + 50, ids.length));
      final page = await _get('videos', {
        'part': 'snippet,contentDetails,status',
        'id': batch.join(','),
        'maxResults': '50',
      });
      result.addAll(_items(page).map(_video));
    }
    return result;
  }

  /// Videos the user liked (YouTube caps this list at 1,000).
  Future<List<YtVideo>> likedVideos() async {
    final items = await _paged('videos', {
      'part': 'snippet,contentDetails,status',
      'myRating': 'like',
      'maxResults': '50',
    });
    return items.map(_video).toList();
  }

  // ----------------------------------------------------------- internals --

  Future<List<Map<String, Object?>>> _paged(
    String resource,
    Map<String, String> query,
  ) async {
    final all = <Map<String, Object?>>[];
    String? pageToken;
    do {
      final page = await _get(resource, {...query, 'pageToken': ?pageToken});
      all.addAll(_items(page));
      pageToken = page['nextPageToken'] as String?;
    } while (pageToken != null);
    return all;
  }

  Future<Map<String, Object?>> _get(
    String resource,
    Map<String, String> query,
  ) async {
    var forceRefresh = false;
    for (var attempt = 1; ; attempt++) {
      final String token;
      try {
        token = await _accessToken(forceRefresh: forceRefresh);
      } on OAuthException catch (e) {
        throw YouTubeApiException(YouTubeErrorKind.auth, e.message);
      }
      try {
        final response = await _dio.get<Map<String, Object?>>(
          '$_base/$resource',
          queryParameters: query,
          options: Options(headers: {'Authorization': 'Bearer $token'}),
        );
        return response.data!;
      } on DioException catch (e) {
        final error = _classify(e);
        final canRetry = attempt < _maxAttempts;
        if (error.kind == YouTubeErrorKind.auth && !forceRefresh && canRetry) {
          forceRefresh = true; // Token revoked or expired early: refresh once.
          continue;
        }
        final transient =
            error.kind == YouTubeErrorKind.network ||
            error.kind == YouTubeErrorKind.server ||
            e.response?.statusCode == 429;
        if (transient && canRetry) {
          // Exponential backoff: 0.5 s, 1 s, …
          await Future<void>.delayed(retryDelay * (1 << (attempt - 1)));
          continue;
        }
        throw error;
      }
    }
  }

  static YouTubeApiException _classify(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    String? reason;
    if (data is Map) {
      final errors = (data['error'] as Map?)?['errors'] as List?;
      final first = errors?.firstOrNull as Map?;
      reason = first?['reason'] as String?;
    }
    if (status == null) {
      return const YouTubeApiException(
        YouTubeErrorKind.network,
        "Couldn't reach YouTube. Check your internet connection.",
      );
    }
    if (status == 403 &&
        (reason == 'quotaExceeded' || reason == 'rateLimitExceeded')) {
      return const YouTubeApiException(
        YouTubeErrorKind.quota,
        "NOIR has used today's YouTube allowance. Syncing resumes tomorrow; "
        'everything already synced stays available.',
      );
    }
    if (status == 401) {
      return const YouTubeApiException(
        YouTubeErrorKind.auth,
        'Your Google session has ended. Connect your account again.',
      );
    }
    if (status == 404) {
      return const YouTubeApiException(
        YouTubeErrorKind.notFound,
        'This playlist is no longer available.',
      );
    }
    if (status >= 500) {
      return const YouTubeApiException(
        YouTubeErrorKind.server,
        'YouTube is having trouble right now. Try again later.',
      );
    }
    return const YouTubeApiException(
      YouTubeErrorKind.other,
      'YouTube refused the request.',
    );
  }

  static List<Map<String, Object?>> _items(Map<String, Object?> page) =>
      ((page['items'] as List?) ?? const []).cast<Map<String, Object?>>();

  static Map<String, Object?> _snippet(Map<String, Object?> item) =>
      (item['snippet'] as Map?)?.cast<String, Object?>() ?? const {};

  static bool _playable(Map<String, Object?> item) {
    final privacy = (item['status'] as Map?)?['privacyStatus'];
    return privacy == null || privacy == 'public' || privacy == 'unlisted';
  }

  static String? _thumbnail(Map<String, Object?> snippet) {
    final thumbs = (snippet['thumbnails'] as Map?)?.cast<String, Object?>();
    if (thumbs == null) return null;
    for (final size in ['maxres', 'standard', 'high', 'medium', 'default']) {
      final url = (thumbs[size] as Map?)?['url'] as String?;
      if (url != null) return url;
    }
    return null;
  }

  static YtVideo _video(Map<String, Object?> v) {
    final snippet = _snippet(v);
    return YtVideo(
      id: v['id']! as String,
      title: snippet['title'] as String? ?? 'Untitled',
      channelTitle: snippet['channelTitle'] as String? ?? '',
      duration: parseIsoDuration(
        (v['contentDetails'] as Map?)?['duration'] as String?,
      ),
      thumbnailUrl: _thumbnail(snippet),
      embeddable: (v['status'] as Map?)?['embeddable'] as bool? ?? true,
    );
  }
}

/// `PT3M21S` → 3:21. Returns null for missing or live (`P0D`) durations.
Duration? parseIsoDuration(String? iso) {
  if (iso == null) return null;
  final m = RegExp(r'^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$')
      .firstMatch(iso);
  if (m == null) return null;
  int g(int i) => int.tryParse(m.group(i) ?? '') ?? 0;
  final d = Duration(days: g(1), hours: g(2), minutes: g(3), seconds: g(4));
  return d == Duration.zero ? null : d;
}

/// "Artist - Topic" channels belong to YouTube Music's auto-generated tracks;
/// the channel name minus the suffix is the artist.
String artistFromChannel(String channelTitle) =>
    channelTitle.endsWith(' - Topic')
    ? channelTitle.substring(0, channelTitle.length - 8)
    : channelTitle;
