import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_lyrics.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

/// In-memory YouTube Music client for widget and controller tests: no Dio,
/// no network. Every answer is a field tests can replace; [error] makes all
/// calls fail.
class FakeInnerTubeClient implements InnerTubeClient {
  /// Recorded calls, e.g. `home`, `homeMore TOKEN`, `radio VIDEO`,
  /// `search QUERY songs`.
  final calls = <String>[];

  /// Thrown by every call when set.
  InnerTubeException? error;

  YtmHomePage homePage = const YtmHomePage(shelves: []);

  /// Pages for `homeMore`, by continuation token.
  Map<String, YtmHomePage> homeMorePages = {};

  /// Radio pages: first page by seed video id, further pages by token.
  Map<String, YtmTrackPage> radioPages = {};
  Map<String, YtmTrackPage> radioMorePages = {};

  /// Search results by filter (any query), further pages by token.
  Map<YtmSearchFilter, YtmSearchPage> searchPages = {};
  Map<String, YtmSearchPage> searchMorePages = {};

  /// Playlists and albums by id, further tracks by token.
  Map<String, YtmCollection> collections = {};
  Map<String, YtmTrackPage> playlistMorePages = {};

  /// `get_queue` entries by video id. None by default.
  Map<String, YtmQueueEntry> queueEntries = {};

  /// Lyrics: browse id by video id, lyrics by browse id. None by default.
  Map<String, String> lyricsTabs = {};
  Map<String, YtmLyrics> lyricsPages = {};

  Future<T> _answer<T>(String call, T Function() value) async {
    calls.add(call);
    await Future<void>.delayed(Duration.zero);
    if (error case final e?) throw e;
    return value();
  }

  static const _notFound = InnerTubeException(
    InnerTubeErrorKind.http,
    'YouTube Music refused the request.',
    statusCode: 404,
  );

  @override
  Future<YtmHomePage> home({String? params}) =>
      _answer(params == null ? 'home' : 'home $params', () => homePage);

  @override
  Future<YtmHomePage> homeMore(String continuation) => _answer(
    'homeMore $continuation',
    () => homeMorePages[continuation] ?? const YtmHomePage(shelves: []),
  );

  @override
  Future<YtmTrackPage> radio(String videoId) => _answer(
    'radio $videoId',
    () => radioPages[videoId] ?? const YtmTrackPage(tracks: []),
  );

  @override
  Future<YtmTrackPage> radioMore(String continuation, {String? playlistId}) =>
      _answer(
        'radioMore $continuation',
        () => radioMorePages[continuation] ?? const YtmTrackPage(tracks: []),
      );

  @override
  Future<YtmSearchPage> search(
    String query, {
    YtmSearchFilter filter = YtmSearchFilter.songs,
  }) => _answer(
    'search $query ${filter.name}',
    () => searchPages[filter] ?? const YtmSearchPage(items: []),
  );

  @override
  Future<YtmSearchPage> searchMore(String continuation) => _answer(
    'searchMore $continuation',
    () => searchMorePages[continuation] ?? const YtmSearchPage(items: []),
  );

  @override
  Future<YtmSearchSuggestions> searchSuggestions(String query) => _answer(
    'suggestions $query',
    () => const YtmSearchSuggestions(queries: []),
  );

  @override
  Future<YtmCollection> playlist(String playlistId) =>
      _answer('playlist $playlistId', () {
        final c = collections[playlistId];
        if (c == null) throw _notFound;
        return c;
      });

  @override
  Future<YtmCollection> album(String browseId) =>
      _answer('album $browseId', () {
        final c = collections[browseId];
        if (c == null) throw _notFound;
        return c;
      });

  @override
  Future<YtmTrackPage> playlistMore(String continuation) => _answer(
    'playlistMore $continuation',
    () => playlistMorePages[continuation] ?? const YtmTrackPage(tracks: []),
  );

  @override
  Future<Map<String, YtmQueueEntry>> queue(List<String> videoIds) => _answer(
    'queue ${videoIds.join(',')}',
    () => {for (final id in videoIds) id: ?queueEntries[id]},
  );

  @override
  Future<String?> lyricsBrowseId(String videoId) =>
      _answer('lyricsBrowseId $videoId', () => lyricsTabs[videoId]);

  @override
  Future<YtmLyrics?> lyrics(String browseId) =>
      _answer('lyrics $browseId', () => lyricsPages[browseId]);

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A YouTube track as the InnerTube parsers build it.
Track ytTrack(String videoId, {String? title, String? artist}) => Track(
  id: 'yt:$videoId',
  source: MediaSource.youtube,
  title: title ?? 'Song $videoId',
  uri: videoId,
  artist: artist ?? 'Artist',
  duration: const Duration(minutes: 3),
);
