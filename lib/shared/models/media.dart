import 'package:freezed_annotation/freezed_annotation.dart';

part 'media.freezed.dart';
part 'media.g.dart';

/// Where a piece of media comes from. Capabilities differ per source.
enum MediaSource { local, youtube }

@freezed
abstract class Track with _$Track {
  const factory Track({
    /// Stable, source-prefixed id, e.g. `local:42`.
    required String id,
    required MediaSource source,
    required String title,

    /// Local file path or provider media id.
    required String uri,
    String? artist,
    String? album,
    int? trackNumber,
    int? year,
    @DurationMsConverter() Duration? duration,
    String? artworkPath,
    String? artworkUrl,
    @Default(false) bool isFavorite,
  }) = _Track;

  const Track._();

  factory Track.fromJson(Map<String, Object?> json) => _$TrackFromJson(json);

  /// Database id for local tracks, null otherwise.
  int? get localId =>
      source == MediaSource.local ? int.tryParse(id.substring(6)) : null;

  String get artistOrUnknown => artist ?? 'Unknown artist';

  /// Local artwork file or remote thumbnail URL, whichever exists.
  String? get artwork => artworkPath ?? artworkUrl;
}

@freezed
abstract class Album with _$Album {
  const factory Album({
    required String title,
    required String artist,
    required int trackCount,
    int? year,
    String? artworkPath,
  }) = _Album;
}

@freezed
abstract class Artist with _$Artist {
  const factory Artist({
    required String name,
    required int trackCount,
    required int albumCount,
    String? artworkPath,
  }) = _Artist;
}

@freezed
abstract class Playlist with _$Playlist {
  const factory Playlist({
    required int id,
    required String name,
    required int trackCount,
    required Duration totalDuration,
    required DateTime updatedAt,

    /// Up to four distinct covers for a collage.
    @Default(<String>[]) List<String> artworkPaths,
  }) = _Playlist;
}

class DurationMsConverter implements JsonConverter<Duration?, int?> {
  const DurationMsConverter();

  @override
  Duration? fromJson(int? json) =>
      json == null ? null : Duration(milliseconds: json);

  @override
  int? toJson(Duration? object) => object?.inMilliseconds;
}
