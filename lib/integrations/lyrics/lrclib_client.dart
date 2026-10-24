import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

/// A track record from LRCLIB (https://lrclib.net). Durations are seconds.
@immutable
class LrclibRecord {
  const LrclibRecord({
    required this.id,
    required this.trackName,
    required this.artistName,
    this.albumName,
    this.duration,
    this.instrumental = false,
    this.plainLyrics,
    this.syncedLyrics,
  });

  factory LrclibRecord.fromJson(Map<String, Object?> json) => LrclibRecord(
    id: (json['id'] as num?)?.toInt() ?? 0,
    trackName: json['trackName'] as String? ?? json['name'] as String? ?? '',
    artistName: json['artistName'] as String? ?? '',
    albumName: json['albumName'] as String?,
    duration: json['duration'] == null
        ? null
        : Duration(milliseconds: ((json['duration']! as num) * 1000).round()),
    instrumental: json['instrumental'] as bool? ?? false,
    plainLyrics: _text(json['plainLyrics']),
    syncedLyrics: _text(json['syncedLyrics']),
  );

  final int id;
  final String trackName;
  final String artistName;
  final String? albumName;
  final Duration? duration;
  final bool instrumental;
  final String? plainLyrics;
  final String? syncedLyrics;

  bool get hasContent =>
      instrumental || plainLyrics != null || syncedLyrics != null;

  static String? _text(Object? v) =>
      v is String && v.trim().isNotEmpty ? v : null;
}

/// Minimal LRCLIB API client. Free, no key; LRCLIB asks clients to identify
/// themselves with a User-Agent.
class LrclibClient {
  LrclibClient(this._dio, {this.baseUrl = 'https://lrclib.net/api'});

  final Dio _dio;
  final String baseUrl;

  static const userAgent = 'NOIR/1.0.0';

  /// Exact lookup. LRCLIB matches the duration within ±2 s. Null on 404.
  Future<LrclibRecord?> get({
    required String trackName,
    required String artistName,
    String? albumName,
    Duration? duration,
    CancelToken? cancel,
  }) async {
    final res = await _dio.get<Object?>(
      '$baseUrl/get',
      queryParameters: {
        'track_name': trackName,
        'artist_name': artistName,
        'album_name': ?albumName,
        if (duration != null) 'duration': duration.inSeconds,
      },
      options: _options,
      cancelToken: cancel,
    );
    if (res.statusCode == 404) return null;
    final data = res.data;
    return data is Map<String, Object?> ? LrclibRecord.fromJson(data) : null;
  }

  /// Fuzzy search by free text [query] or by track/artist name.
  Future<List<LrclibRecord>> search({
    String? query,
    String? trackName,
    String? artistName,
    CancelToken? cancel,
  }) async {
    final res = await _dio.get<Object?>(
      '$baseUrl/search',
      queryParameters: {
        'q': ?query,
        'track_name': ?trackName,
        'artist_name': ?artistName,
      },
      options: _options,
      cancelToken: cancel,
    );
    final data = res.data;
    if (res.statusCode == 404 || data is! List) return const [];
    return [
      for (final r in data)
        if (r is Map<String, Object?>) LrclibRecord.fromJson(r),
    ];
  }

  Options get _options => Options(
    headers: {'User-Agent': userAgent},
    responseType: ResponseType.json,
    // 404 is an answer ("no such track"); everything else non-2xx throws.
    validateStatus: (s) => s != null && (s >= 200 && s < 300 || s == 404),
  );
}
