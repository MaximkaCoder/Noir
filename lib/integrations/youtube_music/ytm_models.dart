import 'package:freezed_annotation/freezed_annotation.dart' show immutable;
import 'package:noir/shared/models/media.dart';

/// Something YouTube Music shows on a shelf or in search results.
@immutable
sealed class YtmItem {
  const YtmItem({required this.title, this.thumbnailUrl});

  final String title;
  final String? thumbnailUrl;
}

/// A playable song (`isVideo == false`) or music video.
final class YtmTrackItem extends YtmItem {
  YtmTrackItem(this.track, {this.isVideo = false})
    : super(title: track.title, thumbnailUrl: track.artworkUrl);

  final Track track;

  /// Official or user-uploaded video rather than an audio track ("song").
  final bool isVideo;

  String get videoId => track.uri;
}

final class YtmAlbumItem extends YtmItem {
  const YtmAlbumItem({
    required this.browseId,
    required super.title,
    super.thumbnailUrl,
    this.artist,
    this.year,
    this.albumType,
  });

  /// `MPREb_…`, opens with `InnerTubeClient.album`.
  final String browseId;
  final String? artist;
  final int? year;

  /// "Album", "Single", "EP", … as YouTube Music labels it.
  final String? albumType;
}

final class YtmPlaylistItem extends YtmItem {
  const YtmPlaylistItem({
    required this.playlistId,
    required super.title,
    super.thumbnailUrl,
    this.subtitle,
  });

  /// Playlist id without the `VL` browse prefix; opens with
  /// `InnerTubeClient.playlist`.
  final String playlistId;

  /// Author or featured artists, as shown under the title.
  final String? subtitle;
}

final class YtmArtistItem extends YtmItem {
  const YtmArtistItem({
    required this.browseId,
    required super.title,
    super.thumbnailUrl,
    this.subtitle,
  });

  /// Channel id (`UC…`).
  final String browseId;
  final String? subtitle;
}

/// A titled row of items on the home feed.
@immutable
class YtmShelf {
  const YtmShelf({required this.title, required this.items, this.strapline});

  final String title;
  final List<YtmItem> items;

  /// Small text above the title ("Similar to …"), when present.
  final String? strapline;
}

/// A mood/genre chip ("Relax", "Workout") that filters the home feed.
@immutable
class YtmChip {
  const YtmChip({required this.title, required this.params});

  final String title;

  /// Opaque browse params; pass to `InnerTubeClient.home(params: …)`.
  final String params;
}

@immutable
class YtmHomePage {
  const YtmHomePage({
    required this.shelves,
    this.chips = const [],
    this.continuation,
  });

  final List<YtmShelf> shelves;
  final List<YtmChip> chips;

  /// Token for `InnerTubeClient.homeMore`; null on the last page.
  final String? continuation;
}

/// A page of tracks from radio / up next or a playlist continuation.
@immutable
class YtmTrackPage {
  const YtmTrackPage({
    required this.tracks,
    this.continuation,
    this.playlistId,
  });

  final List<Track> tracks;
  final String? continuation;

  /// Queue the tracks belong to (`RDAMVM…` for radio).
  final String? playlistId;
}

@immutable
class YtmSearchPage {
  const YtmSearchPage({required this.items, this.continuation});

  final List<YtmItem> items;
  final String? continuation;
}

@immutable
class YtmSearchSuggestions {
  const YtmSearchSuggestions({required this.queries, this.items = const []});

  /// Completed search phrases.
  final List<String> queries;

  /// Direct hits (songs, artists, albums) shown under the phrases.
  final List<YtmItem> items;
}

/// An opened playlist or album.
@immutable
class YtmCollection {
  const YtmCollection({
    required this.id,
    required this.title,
    required this.tracks,
    this.subtitle,
    this.author,
    this.thumbnailUrl,
    this.playlistId,
    this.continuation,
  });

  /// The browse id it was opened with (`VL…` or `MPREb_…`).
  final String id;
  final String title;

  /// "Album • 2013", "Playlist • 2026", …
  final String? subtitle;

  /// Album artist or playlist owner.
  final String? author;
  final String? thumbnailUrl;

  /// Playable playlist id (albums: `OLAK5uy_…`), for `upNext`.
  final String? playlistId;
  final List<Track> tracks;

  /// Token for `InnerTubeClient.playlistMore`; null when complete.
  final String? continuation;
}
