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
    this.categoryId = '',
  });

  final String id;
  final String title;
  final String channelTitle;
  final Duration? duration;
  final String? thumbnailUrl;
  final bool embeddable;

  /// `snippet.categoryId` ("10" is Music); empty when YouTube sent none.
  final String categoryId;
}

/// One entry of a playlist: the playlist item id (needed to remove it) and
/// the video it points to.
class YtPlaylistEntry {
  const YtPlaylistEntry({required this.videoId, this.id});

  final String videoId;

  /// `playlistItems` resource id; null only in hand-made test data.
  final String? id;
}

/// Result of a conditional request that was answered with data.
class YtFetch<T> {
  const YtFetch(this.value, this.etag);

  final T value;

  /// Etag of the response (first page for paged lists). Send it back as
  /// `ifNoneMatch` to get HTTP 304 while nothing changed.
  final String? etag;
}

enum YouTubeErrorKind {
  quota,
  auth,

  /// HTTP 403 `insufficientPermissions`: the token lacks the scope (for
  /// writes, the user has not granted playlist access yet).
  permission,
  notFound,
  network,
  server,
  other,
}

class YouTubeApiException implements Exception {
  const YouTubeApiException(this.kind, this.message);

  final YouTubeErrorKind kind;

  /// User-facing explanation.
  final String message;

  @override
  String toString() => 'YouTubeApiException(${kind.name})';
}

/// Access to the YouTube Data API v3 for the signed-in user.
/// Quota costs (default 10,000 units/day): reads cost 1 unit per page; the
/// few writes (adding or removing a playlist item, creating a playlist,
/// liking or unliking a video) cost 50 units each.
class YouTubeApi {
  YouTubeApi({
    required this._dio,
    required this._accessToken,
    this.retryDelay = const Duration(milliseconds: 500),
  });

  final Dio _dio;
  final Future<String> Function({bool forceRefresh}) _accessToken;
  final Duration retryDelay;

  static const _base = 'https://www.googleapis.com/youtube/v3';
  static const _maxAttempts = 3;

  /// Playlists the user owns (including private ones and those created in
  /// YouTube Music).
  Future<List<YtPlaylist>> myPlaylists() async {
    final page = await _paged('playlists', {
      'part': 'snippet,contentDetails,status',
      'mine': 'true',
      'maxResults': '50',
    });
    return page!.items.map(_playlist).toList();
  }

  /// Items of a playlist in order. Deleted and private videos are skipped —
  /// they cannot be played.
  Future<List<YtPlaylistEntry>> playlistItems(String playlistId) async {
    final page = await _paged('playlistItems', {
      'part': 'snippet,status',
      'playlistId': playlistId,
      'maxResults': '50',
    });
    return [
      for (final i in page!.items)
        if (_playable(i) && _itemVideoId(i) != null)
          YtPlaylistEntry(id: i['id'] as String?, videoId: _itemVideoId(i)!),
    ];
  }

  /// Ids of the items in [playlistId] that point to [videoId] (1 unit).
  Future<List<String>> playlistItemIdsFor(
    String playlistId,
    String videoId,
  ) async {
    final page = await _paged('playlistItems', {
      'part': 'id',
      'playlistId': playlistId,
      'videoId': videoId,
      'maxResults': '50',
    });
    return [for (final i in page!.items) i['id']! as String];
  }

  /// Appends [videoId] to [playlistId] (`playlistItems.insert`, 50 units).
  /// Returns the new playlist item's id.
  Future<String> insertPlaylistItem(String playlistId, String videoId) async {
    final item = await _write(
      'POST',
      'playlistItems',
      {'part': 'snippet'},
      body: {
        'snippet': {
          'playlistId': playlistId,
          'resourceId': {'kind': 'youtube#video', 'videoId': videoId},
        },
      },
    );
    return item['id']! as String;
  }

  /// Removes one playlist item (`playlistItems.delete`, 50 units).
  Future<void> deletePlaylistItem(String itemId) =>
      _write('DELETE', 'playlistItems', {'id': itemId});

  /// Likes [videoId], or clears its rating when [like] is false
  /// (`videos.rate`, 50 units).
  Future<void> rate(String videoId, {required bool like}) => _write(
    'POST',
    'videos/rate',
    {'id': videoId, 'rating': like ? 'like' : 'none'},
  );

  /// Creates a playlist, private unless [privacy] says otherwise
  /// (`playlists.insert`, 50 units).
  Future<YtPlaylist> createPlaylist(
    String title, {
    String privacy = 'private',
  }) async {
    final created = await _write(
      'POST',
      'playlists',
      {'part': 'snippet,status'},
      body: {
        'snippet': {'title': title},
        'status': {'privacyStatus': privacy},
      },
    );
    return _playlist(created);
  }

  /// Full details (duration, embeddability, category) for any number of ids,
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
  ///
  /// This is every liked video, not only music: the Data API has no access
  /// to YouTube Music's "Liked music" list.
  Future<List<YtVideo>> likedVideos() async =>
      (await likedVideosIfChanged())!.value;

  /// [likedVideos], or null (HTTP 304 on the first page) when the list is
  /// unchanged since the response tagged [ifNoneMatch]. New and removed
  /// likes change the first page (newest first, and it carries the total).
  Future<YtFetch<List<YtVideo>>?> likedVideosIfChanged({
    String? ifNoneMatch,
  }) async {
    final page = await _paged('videos', {
      'part': 'snippet,contentDetails,status',
      'myRating': 'like',
      'maxResults': '50',
    }, ifNoneMatch: ifNoneMatch);
    if (page == null) return null;
    return YtFetch(page.items.map(_video).toList(), page.etag);
  }

  // ----------------------------------------------------------- internals --

  /// All pages, or null when the first page is not modified.
  Future<({List<Map<String, Object?>> items, String? etag})?> _paged(
    String resource,
    Map<String, String> query, {
    String? ifNoneMatch,
  }) async {
    final first = await _request(resource, query, ifNoneMatch: ifNoneMatch);
    if (first == null) return null;
    final all = [..._items(first)];
    var pageToken = first['nextPageToken'] as String?;
    while (pageToken != null) {
      final page = await _get(resource, {...query, 'pageToken': pageToken});
      all.addAll(_items(page));
      pageToken = page['nextPageToken'] as String?;
    }
    return (items: all, etag: first['etag'] as String?);
  }

  Future<Map<String, Object?>> _get(
    String resource,
    Map<String, String> query,
  ) async => (await _request(resource, query))!;

  /// GET with retries. Returns null when [ifNoneMatch] is given and the
  /// server answers 304 Not Modified.
  Future<Map<String, Object?>?> _request(
    String resource,
    Map<String, String> query, {
    String? ifNoneMatch,
  }) => _send('GET', resource, query, ifNoneMatch: ifNoneMatch);

  /// A write. Not retried on network or server errors: YouTube may already
  /// have applied it, and a second insert would add the video twice.
  Future<Map<String, Object?>> _write(
    String method,
    String resource,
    Map<String, String> query, {
    Map<String, Object?>? body,
  }) async => (await _send(
    method,
    resource,
    query,
    body: body,
    retryTransient: false,
  ))!;

  Future<Map<String, Object?>?> _send(
    String method,
    String resource,
    Map<String, String> query, {
    Map<String, Object?>? body,
    String? ifNoneMatch,
    bool retryTransient = true,
  }) async {
    var forceRefresh = false;
    for (var attempt = 1; ; attempt++) {
      final String token;
      try {
        token = await _accessToken(forceRefresh: forceRefresh);
      } on OAuthException catch (e) {
        throw YouTubeApiException(YouTubeErrorKind.auth, e.message);
      }
      try {
        final response = await _dio.request<Map<String, Object?>>(
          '$_base/$resource',
          queryParameters: query,
          data: body,
          options: Options(
            method: method,
            headers: {
              'Authorization': 'Bearer $token',
              if (ifNoneMatch != null)
                'If-None-Match': ifNoneMatch.startsWith('"')
                    ? ifNoneMatch
                    : '"$ifNoneMatch"',
            },
            validateStatus: (s) =>
                s != null && (s >= 200 && s < 300 || s == 304),
          ),
        );
        if (response.statusCode == 304) return null;
        // DELETE answers 204 without a body.
        return response.data ?? const {};
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
        if (transient && canRetry && retryTransient) {
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
    if (status == 403 &&
        (reason == 'insufficientPermissions' ||
            reason == 'ACCESS_TOKEN_SCOPE_INSUFFICIENT')) {
      return const YouTubeApiException(
        YouTubeErrorKind.permission,
        'NOIR needs permission to change your YouTube playlists.',
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

  static String? _itemVideoId(Map<String, Object?> item) {
    final id = (_snippet(item)['resourceId'] as Map?)?['videoId'] as String?;
    return id == null || id.isEmpty ? null : id;
  }

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

  static YtPlaylist _playlist(Map<String, Object?> p) => YtPlaylist(
    id: p['id']! as String,
    etag: p['etag']! as String,
    title: _snippet(p)['title'] as String? ?? 'Untitled playlist',
    itemCount:
        ((p['contentDetails'] as Map?)?['itemCount'] as num?)?.toInt() ?? 0,
    thumbnailUrl: _thumbnail(_snippet(p)),
    privacy: (p['status'] as Map?)?['privacyStatus'] as String?,
  );

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
      categoryId: snippet['categoryId'] as String? ?? '',
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
