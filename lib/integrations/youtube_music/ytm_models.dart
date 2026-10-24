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

/// An opened artist page (`UC…` channel).
@immutable
class YtmArtist {
  const YtmArtist({
    required this.browseId,
    required this.name,
    this.thumbnailUrl,
    this.bannerUrl,
    this.subscribers,
    this.audience,
    this.description,
    this.topSongs = const [],
    this.songsPlaylistId,
    this.shelves = const [],
  });

  /// Channel id (`UC…`) it was opened with.
  final String browseId;
  final String name;

  /// Square picture (avatar), when YouTube Music has one.
  final String? thumbnailUrl;

  /// Wide header image, full size.
  final String? bannerUrl;

  /// "7.2M subscribers".
  final String? subscribers;

  /// "68M monthly audience".
  final String? audience;
  final String? description;

  /// The few most played songs shown on the page.
  final List<Track> topSongs;

  /// Playlist with all of the artist's songs (no `VL` prefix), for
  /// `InnerTubeClient.playlist`; null when the page has no "Show all".
  final String? songsPlaylistId;

  /// Albums, singles, videos, related artists, … in page order.
  final List<YtmShelf> shelves;
}

/// One video as `music/get_queue` describes it: enough to pick its artwork.
@immutable
class YtmQueueEntry {
  const YtmQueueEntry({
    required this.videoId,
    required this.title,
    this.artist,
    this.duration,
    this.thumbnailUrl,
    this.videoType,
    this.artists = const [],
    this.album,
    this.counterpart,
  });

  final String videoId;
  final String title;
  final String? artist;
  final Duration? duration;

  /// Largest thumbnail: square album art (`*.googleusercontent.com`) for
  /// songs, an `i.ytimg.com` video frame for music videos.
  final String? thumbnailUrl;

  /// `MUSIC_VIDEO_TYPE_ATV` (song), `_OMV` (official video), `_UGC`, …
  final String? videoType;

  /// Linked artist names in the byline (channel ids `UC…`).
  final List<YtmLink> artists;

  /// Linked album in the byline (`MPREb_…`); songs only, as a rule.
  final YtmLink? album;

  /// The song/video twin YouTube Music pairs this entry with, if any.
  final YtmQueueEntry? counterpart;

  YtmTrackLinks get links => YtmTrackLinks(artists: artists, album: album);

  /// An audio track ("Art Track") rather than a music video.
  bool get isSong => videoType == 'MUSIC_VIDEO_TYPE_ATV';
}

/// A name in a byline and the page it opens (`InnerTubeClient.album` for
/// `MPREb_…`, an artist page for `UC…`).
typedef YtmLink = ({String name, String browseId});

/// Where a track's artist and album names lead on YouTube Music.
@immutable
class YtmTrackLinks {
  const YtmTrackLinks({this.artists = const [], this.album});

  final List<YtmLink> artists;
  final YtmLink? album;

  bool get isEmpty => artists.isEmpty && album == null;

  @override
  bool operator ==(Object other) =>
      other is YtmTrackLinks &&
      other.album == album &&
      other.artists.length == artists.length &&
      Iterable<int>.generate(artists.length)
          .every((i) => other.artists[i] == artists[i]);

  @override
  int get hashCode => Object.hash(album, Object.hashAll(artists));

  @override
  String toString() => 'YtmTrackLinks($artists, $album)';
}
