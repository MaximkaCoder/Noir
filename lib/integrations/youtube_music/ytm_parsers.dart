import 'dart:collection';

import 'package:noir/integrations/youtube_music/json_nav.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

/// Parsers for YouTube Music InnerTube responses. They skip renderers they
/// do not know instead of failing; a [FormatException] is thrown only when
/// the response lacks the container a page is built from.

// --------------------------------------------------------------- pages --

/// `browse` FEmusic_home, first page or continuation.
YtmHomePage parseHome(Map<String, Object?> json) {
  final sectionList =
      findMap(json['continuationContents'], 'sectionListContinuation') ??
      findMap(json['contents'], 'sectionListRenderer');
  if (sectionList == null) {
    throw const FormatException('home: no section list');
  }
  final shelves = <YtmShelf>[];
  for (final section in navList(sectionList, ['contents'])) {
    final shelf = _shelf(section);
    if (shelf != null) shelves.add(shelf);
  }
  final chips = <YtmChip>[];
  final chipList = navList(sectionList, [
    'header',
    'chipCloudRenderer',
    'chips',
  ]);
  for (final chip in chipList) {
    final body = navMap(chip, ['chipCloudChipRenderer']);
    final title = textOf(body?['text']);
    final params = navString(body, [
      'navigationEndpoint',
      'browseEndpoint',
      'params',
    ]);
    if (title != null && params != null) {
      chips.add(YtmChip(title: title, params: params));
    }
  }
  return YtmHomePage(
    shelves: shelves,
    chips: chips,
    continuation: continuationToken(navList(sectionList, ['continuations'])),
  );
}

/// `next` (radio / up next), first page or continuation.
YtmTrackPage parseNext(Map<String, Object?> json) {
  final panel =
      findMap(json['continuationContents'], 'playlistPanelContinuation') ??
      findMap(json['contents'], 'playlistPanelRenderer');
  if (panel == null) throw const FormatException('next: no queue panel');
  final tracks = <Track>[];
  for (final entry in navList(panel, ['contents'])) {
    final video =
        navMap(entry, ['playlistPanelVideoRenderer']) ??
        navMap(entry, [
          'playlistPanelVideoWrapperRenderer',
          'primaryRenderer',
          'playlistPanelVideoRenderer',
        ]);
    final track = video == null ? null : _panelTrack(video);
    if (track != null) tracks.add(track);
  }
  return YtmTrackPage(
    tracks: tracks,
    continuation: continuationToken(panel['continuations']),
    playlistId: navString(panel, ['playlistId']),
  );
}

/// `search`, first page or continuation.
YtmSearchPage parseSearch(Map<String, Object?> json) {
  final continued = findMap(
    json['continuationContents'],
    'musicShelfContinuation',
  );
  final sectionList = findMap(json['contents'], 'sectionListRenderer');
  if (continued == null && sectionList == null) {
    throw const FormatException('search: no section list');
  }
  final shelves = continued != null
      ? [continued]
      : [
          for (final section in navList(sectionList, ['contents']))
            ?navMap(section, ['musicShelfRenderer']),
        ];
  final items = <YtmItem>[];
  String? continuation;
  for (final shelf in shelves) {
    items.addAll(_items(navList(shelf, ['contents'])));
    continuation ??= continuationToken(shelf['continuations']);
  }
  return YtmSearchPage(items: items, continuation: continuation);
}

/// `music/get_search_suggestions`.
YtmSearchSuggestions parseSearchSuggestions(Map<String, Object?> json) {
  final queries = <String>[];
  final items = <YtmItem>[];
  for (final section in navList(json, ['contents'])) {
    final entries = navList(section, [
      'searchSuggestionsSectionRenderer',
      'contents',
    ]);
    for (final entry in entries) {
      final (name, body) = renderer(entry) ?? ('', const <String, Object?>{});
      if (name == 'searchSuggestionRenderer' ||
          name == 'historySuggestionRenderer') {
        final query =
            navString(body, [
              'navigationEndpoint',
              'searchEndpoint',
              'query',
            ]) ??
            textOf(body['suggestion']);
        if (query != null && query.isNotEmpty) queries.add(query);
      } else {
        final item = parseItem(entry);
        if (item != null) items.add(item);
      }
    }
  }
  return YtmSearchSuggestions(queries: queries, items: items);
}

/// `browse` of a playlist (`VL…`) or album (`MPREb_…`) page.
YtmCollection parseCollection(Map<String, Object?> json, {required String id}) {
  final contents = json['contents'];
  final shelf =
      findMap(contents, 'musicPlaylistShelfRenderer') ??
      findMap(contents, 'musicShelfRenderer');
  final header =
      findMap(contents, 'musicResponsiveHeaderRenderer') ??
      findMap(json['header'], 'musicDetailHeaderRenderer');
  if (shelf == null && header == null) {
    throw const FormatException('collection: no header or tracks');
  }
  final title = textOf(header?['title']) ?? '';
  final artwork = bestThumbnail(findKey(header?['thumbnail'], 'thumbnails'));
  final isAlbum = id.startsWith('MPRE');
  final author =
      textOf(header?['straplineTextOne']) ??
      navString(header, [
        'facepile',
        'avatarStackViewModel',
        'text',
        'content',
      ]);
  final items = navList(shelf, ['contents']);
  final tracks = _collectionTracks(
    items,
    fallbackArtwork: artwork,
    fallbackArtist: isAlbum ? author : null,
    album: isAlbum ? title : null,
  );
  final buttonPlaylistId = findKey(header?['buttons'], 'playlistId');
  return YtmCollection(
    id: id,
    title: title,
    subtitle: textOf(header?['subtitle']),
    author: author,
    thumbnailUrl: artwork,
    playlistId:
        navString(shelf, ['playlistId']) ??
        (buttonPlaylistId is String ? buttonPlaylistId : null) ??
        (id.startsWith('VL') ? id.substring(2) : null),
    tracks: tracks,
    continuation:
        continuationItemToken(items) ??
        continuationToken(shelf?['continuations']),
  );
}

/// `browse` of an artist channel (`UC…`): header, top songs and the
/// carousels below them (albums, singles, videos, related artists, …).
YtmArtist parseArtist(Map<String, Object?> json, {required String id}) {
  final header = renderer(json['header'])?.$2;
  final sectionList = findMap(json['contents'], 'sectionListRenderer');
  if (header == null && sectionList == null) {
    throw const FormatException('artist: no header or sections');
  }
  final name = textOf(header?['title']) ?? '';
  var topSongs = const <Track>[];
  String? songsPlaylistId;
  String? about;
  final shelves = <YtmShelf>[];
  for (final section in navList(sectionList, ['contents'])) {
    final (kind, body) = renderer(section) ?? ('', const <String, Object?>{});
    switch (kind) {
      case 'musicShelfRenderer' when topSongs.isEmpty:
        topSongs = _collectionTracks(
          navList(body, ['contents']),
          fallbackArtist: name.isEmpty ? null : name,
        );
        final all =
            navString(nav(body, ['title', 'runs', 0, 'navigationEndpoint']), [
              'browseEndpoint',
              'browseId',
            ]) ??
            navString(body, ['bottomEndpoint', 'browseEndpoint', 'browseId']);
        if (all != null && all.startsWith('VL')) {
          songsPlaylistId = all.substring(2);
        }
      case 'musicDescriptionShelfRenderer':
        about ??= textOf(body['description']);
      default:
        final shelf = _shelf(section);
        if (shelf != null) shelves.add(shelf);
    }
  }
  final subscribe = navMap(header, [
    'subscriptionButton',
    'subscribeButtonRenderer',
  ]);
  final count = textOf(subscribe?['subscriberCountText']);
  final banner = header?['thumbnail'];
  return YtmArtist(
    browseId: id,
    name: name,
    // The immersive header only has a wide banner; a square crop of it
    // (googleusercontent `-p`) serves as the avatar.
    thumbnailUrl:
        bestThumbnail(findKey(header?['foregroundThumbnail'], 'thumbnails')) ??
        bestThumbnail(findKey(banner, 'thumbnails')),
    bannerUrl: header?['foregroundThumbnail'] == null
        ? _largestThumbnail(findKey(banner, 'thumbnails'))
        : null,
    subscribers:
        textOf(subscribe?['longSubscriberCountText']) ??
        (count == null ? null : '$count subscribers'),
    audience: textOf(header?['monthlyListenerCount']),
    description: textOf(header?['description']) ?? about,
    topSongs: topSongs,
    songsPlaylistId: songsPlaylistId,
    shelves: shelves,
  );
}

/// `browse` continuation of a long playlist.
YtmTrackPage parsePlaylistContinuation(Map<String, Object?> json) {
  var items = const <Object?>[];
  for (final action in navList(json, ['onResponseReceivedActions'])) {
    final list = navList(action, [
      'appendContinuationItemsAction',
      'continuationItems',
    ]);
    if (list.isNotEmpty) items = list;
  }
  String? legacyToken;
  if (items.isEmpty) {
    final shelf = findMap(
      json['continuationContents'],
      'musicPlaylistShelfContinuation',
    );
    if (shelf == null) {
      throw const FormatException('playlist: no continuation items');
    }
    items = navList(shelf, ['contents']);
    legacyToken = continuationToken(shelf['continuations']);
  }
  return YtmTrackPage(
    tracks: _collectionTracks(items),
    continuation: continuationItemToken(items) ?? legacyToken,
  );
}

/// `music/get_queue`: the requested videos keyed by video id. A
/// `playlistPanelVideoWrapperRenderer` pairs a video with its song (or song
/// with its video) twin; both are returned, each pointing at the other.
Map<String, YtmQueueEntry> parseQueue(Map<String, Object?> json) {
  final datas = json['queueDatas'];
  if (datas is! List) throw const FormatException('get_queue: no queue data');
  final entries = <String, YtmQueueEntry>{};
  for (final data in datas) {
    final content = navMap(data, ['content']);
    final wrapper = navMap(content, ['playlistPanelVideoWrapperRenderer']);
    final primary =
        navMap(content, ['playlistPanelVideoRenderer']) ??
        navMap(wrapper, ['primaryRenderer', 'playlistPanelVideoRenderer']);
    final twinBody = navMap(navList(wrapper, ['counterpart']).firstOrNull, [
      'counterpartRenderer',
      'playlistPanelVideoRenderer',
    ]);
    final twin = twinBody == null ? null : _queueEntry(twinBody);
    final entry = primary == null
        ? null
        : _queueEntry(primary, counterpart: twin);
    if (entry == null) continue;
    entries[entry.videoId] = entry;
    if (twin != null) {
      entries.putIfAbsent(
        twin.videoId,
        () => _queueEntry(twinBody!, counterpart: entry)!,
      );
    }
  }
  return entries;
}

// --------------------------------------------------------------- items --

/// One shelf/search entry, or null for renderers NOIR does not show
/// (podcasts, episodes, unknown types).
YtmItem? parseItem(Object? json) {
  final (name, body) = renderer(json) ?? ('', const <String, Object?>{});
  return switch (name) {
    'musicResponsiveListItemRenderer' => _listItem(body),
    'musicTwoRowItemRenderer' => _twoRowItem(body),
    _ => null,
  };
}

/// Square artwork when YouTube Music has it (`*.googleusercontent.com`,
/// resized to 544 px), otherwise the largest video thumbnail.
String? bestThumbnail(Object? thumbnails) {
  final best = _largestThumbnail(thumbnails);
  if (best == null) return null;
  final host = Uri.tryParse(best)?.host ?? '';
  if (host.endsWith('googleusercontent.com') || host.endsWith('ggpht.com')) {
    return _resizeGoogleImage(best);
  }
  return best;
}

/// URL of the widest thumbnail, unchanged.
String? _largestThumbnail(Object? thumbnails) {
  final list = thumbnails is Map
      ? navList(thumbnails, ['thumbnails'])
      : navList(thumbnails);
  String? best;
  var bestWidth = -1;
  for (final t in list) {
    final url = navString(t, ['url']);
    if (url == null || url.isEmpty) continue;
    final width = switch (nav(t, ['width'])) {
      final num n => n.toInt(),
      _ => 0,
    };
    if (width >= bestWidth) {
      best = url;
      bestWidth = width;
    }
  }
  if (best == null) return null;
  return best.startsWith('//') ? 'https:$best' : best;
}

/// `3:21` / `1:02:03` → Duration.
Duration? parseClock(String? text) {
  if (text == null) return null;
  final m = RegExp(r'^(?:(\d+):)?(\d{1,2}):(\d{2})$').firstMatch(text.trim());
  if (m == null) return null;
  return Duration(
    hours: int.tryParse(m.group(1) ?? '') ?? 0,
    minutes: int.parse(m.group(2)!),
    seconds: int.parse(m.group(3)!),
  );
}

/// Breadth-first search for the first map stored under [key]
/// (or any value for keys like `playlistId`). Bounded so a malformed
/// response cannot make it run long.
Object? findKey(Object? json, String key, {int maxNodes = 20000}) {
  if (json == null) return null;
  final queue = Queue<Object?>()..add(json);
  var visited = 0;
  while (queue.isNotEmpty && visited++ < maxNodes) {
    final node = queue.removeFirst();
    if (node is Map) {
      if (node.containsKey(key)) {
        final value = node[key];
        if (value != null) return value;
      }
      queue.addAll(node.values);
    } else if (node is List) {
      queue.addAll(node);
    }
  }
  return null;
}

Map<String, Object?>? findMap(Object? json, String key) =>
    navMap(findKey(json, key));

// ----------------------------------------------------------- internals --

YtmShelf? _shelf(Object? section) {
  final (name, body) = renderer(section) ?? ('', const <String, Object?>{});
  if (!name.endsWith('ShelfRenderer')) return null;
  final header = renderer(body['header'])?.$2;
  final title = textOf(header?['title']) ?? textOf(body['title']);
  final items = _items(navList(body, ['contents']));
  if (title == null || items.isEmpty) return null;
  return YtmShelf(
    title: title,
    items: items,
    strapline: textOf(header?['strapline']),
  );
}

List<YtmItem> _items(List<Object?> entries) => [
  for (final e in entries) ?parseItem(e),
];

const _typeLabels = {
  'Song',
  'Video',
  'Album',
  'Single',
  'EP',
  'Playlist',
  'Artist',
  'Episode',
  'Podcast',
  'Profile',
  'Station',
};

/// Runs split at the " • " separators.
List<List<Map<String, Object?>>> _segments(Object? text) {
  final segments = <List<Map<String, Object?>>>[[]];
  for (final run in navList(text, ['runs'])) {
    final map = navMap(run);
    if (map == null) continue;
    if (navString(map, ['text'])?.trim() == '•') {
      segments.add([]);
    } else {
      segments.last.add(map);
    }
  }
  return segments.where((s) => s.isNotEmpty).toList();
}

String _segmentText(List<Map<String, Object?>> segment) =>
    segment.map((r) => navString(r, ['text']) ?? '').join().trim();

String? _pageType(Object? endpoint) => navString(endpoint, [
  'browseEndpoint',
  'browseEndpointContextSupportedConfigs',
  'browseEndpointContextMusicConfig',
  'pageType',
]);

bool _isMetric(String text) =>
    parseClock(text) != null ||
    RegExp(r'^\d{4}$').hasMatch(text) ||
    RegExp(
      r'\b(views?|plays?|likes?|songs?|tracks?|subscribers?|monthly audience)$',
      caseSensitive: false,
    ).hasMatch(text);

/// Label ("Song", "Album", …) dropped; returns it and the remaining segments.
(String?, List<List<Map<String, Object?>>>) _splitLabel(
  List<List<Map<String, Object?>>> segments,
) {
  if (segments.isEmpty) return (null, segments);
  final first = segments.first;
  final text = _segmentText(first);
  if (first.length == 1 &&
      first.first['navigationEndpoint'] == null &&
      _typeLabels.contains(text)) {
    return (text, segments.sublist(1));
  }
  return (null, segments);
}

/// Artist names from the first subtitle segment, if it is not a metric.
String? _artistOf(List<List<Map<String, Object?>>> segments) {
  if (segments.isEmpty) return null;
  final text = _segmentText(segments.first);
  return text.isEmpty || _isMetric(text) ? null : text;
}

String? _albumOf(Iterable<Map<String, Object?>> runs) {
  for (final run in runs) {
    if (_pageType(run['navigationEndpoint']) == 'MUSIC_PAGE_TYPE_ALBUM') {
      return navString(run, ['text']);
    }
  }
  return null;
}

Duration? _durationOf(List<List<Map<String, Object?>>> segments) {
  for (final s in segments.reversed) {
    final d = parseClock(_segmentText(s));
    if (d != null) return d;
  }
  return null;
}

String? _videoType(Object? endpoint) => navString(endpoint, [
  'watchEndpoint',
  'watchEndpointMusicSupportedConfigs',
  'watchEndpointMusicConfig',
  'musicVideoType',
]);

bool _isVideoType(String? type) =>
    type != null && type != 'MUSIC_VIDEO_TYPE_ATV';

Track _track({
  required String videoId,
  required String title,
  String? artist,
  String? album,
  Duration? duration,
  String? artworkUrl,
}) => Track(
  id: 'yt:$videoId',
  source: MediaSource.youtube,
  title: title,
  uri: videoId,
  artist: artist,
  album: album,
  duration: duration,
  artworkUrl: artworkUrl ?? 'https://i.ytimg.com/vi/$videoId/mqdefault.jpg',
);

Object? _flexText(Map<String, Object?> body, int column) => nav(body, [
  'flexColumns',
  column,
  'musicResponsiveListItemFlexColumnRenderer',
  'text',
]);

YtmItem? _listItem(Map<String, Object?> body, {String? fallbackArtwork}) {
  final titleText = _flexText(body, 0);
  final title = textOf(titleText);
  if (title == null || title.isEmpty) return null;
  final thumbnail = bestThumbnail(
    nav(body, ['thumbnail', 'musicThumbnailRenderer', 'thumbnail']),
  );
  final titleEndpoint = nav(titleText, ['runs', 0, 'navigationEndpoint']);
  final videoId =
      navString(body, ['playlistItemData', 'videoId']) ??
      navString(titleEndpoint, ['watchEndpoint', 'videoId']);
  final (label, segments) = _splitLabel(_segments(_flexText(body, 1)));

  if (videoId != null) {
    final columns = navList(body, ['flexColumns']);
    final allRuns = [
      for (var c = 1; c < columns.length; c++)
        for (final run in navList(_flexText(body, c), ['runs'])) ?navMap(run),
    ];
    final fixed = textOf(
      nav(body, [
        'fixedColumns',
        0,
        'musicResponsiveListItemFixedColumnRenderer',
        'text',
      ]),
    );
    final type =
        _videoType(titleEndpoint) ??
        _videoType(
          nav(body, [
            'overlay',
            'musicItemThumbnailOverlayRenderer',
            'content',
            'musicPlayButtonRenderer',
            'playNavigationEndpoint',
          ]),
        );
    return YtmTrackItem(
      _track(
        videoId: videoId,
        title: title,
        artist: _artistOf(segments),
        album: _albumOf(allRuns),
        duration: parseClock(fixed) ?? _durationOf(segments),
        artworkUrl: thumbnail ?? fallbackArtwork,
      ),
      isVideo: _isVideoType(type) || label == 'Video',
    );
  }

  final endpoint = body['navigationEndpoint'];
  final browseId = navString(endpoint, ['browseEndpoint', 'browseId']);
  if (browseId == null) return null;
  return _browseItem(
    pageType: _pageType(endpoint),
    browseId: browseId,
    title: title,
    thumbnail: thumbnail,
    label: label,
    segments: segments,
  );
}

YtmItem? _twoRowItem(Map<String, Object?> body) {
  final title = textOf(body['title']);
  if (title == null || title.isEmpty) return null;
  final thumbnail = bestThumbnail(
    nav(body, ['thumbnailRenderer', 'musicThumbnailRenderer', 'thumbnail']),
  );
  final (label, segments) = _splitLabel(_segments(body['subtitle']));
  final endpoint = body['navigationEndpoint'];

  final videoId = navString(endpoint, ['watchEndpoint', 'videoId']);
  if (videoId != null) {
    return YtmTrackItem(
      _track(
        videoId: videoId,
        title: title,
        artist: _artistOf(segments),
        album: _albumOf(segments.expand((s) => s)),
        duration: _durationOf(segments),
        artworkUrl: thumbnail,
      ),
      isVideo: _isVideoType(_videoType(endpoint)) || label == 'Video',
    );
  }
  final watchPlaylist = navString(endpoint, [
    'watchPlaylistEndpoint',
    'playlistId',
  ]);
  if (watchPlaylist != null) {
    return YtmPlaylistItem(
      playlistId: watchPlaylist,
      title: title,
      thumbnailUrl: thumbnail,
      subtitle: textOf(body['subtitle']),
    );
  }
  final browseId = navString(endpoint, ['browseEndpoint', 'browseId']);
  if (browseId == null) return null;
  return _browseItem(
    pageType: _pageType(endpoint),
    browseId: browseId,
    title: title,
    thumbnail: thumbnail,
    label: label,
    segments: segments,
  );
}

YtmItem? _browseItem({
  required String? pageType,
  required String browseId,
  required String title,
  required String? thumbnail,
  required String? label,
  required List<List<Map<String, Object?>>> segments,
}) {
  final texts = segments.map(_segmentText).where((t) => t.isNotEmpty);
  final subtitle = texts.isEmpty ? null : texts.join(' • ');
  switch (pageType) {
    case 'MUSIC_PAGE_TYPE_ALBUM':
    case 'MUSIC_PAGE_TYPE_AUDIOBOOK':
      final year = texts
          .map((t) => RegExp(r'^\d{4}$').hasMatch(t) ? int.parse(t) : null)
          .nonNulls
          .firstOrNull;
      return YtmAlbumItem(
        browseId: browseId,
        title: title,
        thumbnailUrl: thumbnail,
        artist: _artistOf(segments),
        year: year,
        albumType: label,
      );
    case 'MUSIC_PAGE_TYPE_PLAYLIST':
      return YtmPlaylistItem(
        playlistId: browseId.startsWith('VL')
            ? browseId.substring(2)
            : browseId,
        title: title,
        thumbnailUrl: thumbnail,
        subtitle: subtitle,
      );
    case 'MUSIC_PAGE_TYPE_ARTIST':
    case 'MUSIC_PAGE_TYPE_USER_CHANNEL':
      return YtmArtistItem(
        browseId: browseId,
        title: title,
        thumbnailUrl: thumbnail,
        subtitle: subtitle,
      );
    default:
      return null; // Podcasts, episodes and future page types.
  }
}

Track? _panelTrack(Map<String, Object?> body) {
  final videoId =
      navString(body, ['videoId']) ??
      navString(body, ['navigationEndpoint', 'watchEndpoint', 'videoId']);
  final title = textOf(body['title']);
  if (videoId == null || title == null || title.isEmpty) return null;
  final segments = _segments(body['longBylineText']);
  return _track(
    videoId: videoId,
    title: title,
    artist: _artistOf(segments) ?? textOf(body['shortBylineText']),
    album: _albumOf(segments.expand((s) => s)),
    duration: parseClock(textOf(body['lengthText'])),
    artworkUrl: bestThumbnail(body['thumbnail']),
  );
}

YtmQueueEntry? _queueEntry(
  Map<String, Object?> body, {
  YtmQueueEntry? counterpart,
}) {
  final track = _panelTrack(body);
  if (track == null) return null;
  final artists = <YtmLink>[];
  YtmLink? album;
  for (final byline in [body['longBylineText'], body['shortBylineText']]) {
    for (final run in navList(byline, ['runs'])) {
      final name = navString(run, ['text'])?.trim();
      final endpoint = nav(run, ['navigationEndpoint']);
      final browseId = navString(endpoint, ['browseEndpoint', 'browseId']);
      if (name == null || name.isEmpty || browseId == null) continue;
      final link = (name: name, browseId: browseId);
      final pageType = _pageType(endpoint);
      if (pageType == 'MUSIC_PAGE_TYPE_ALBUM' || browseId.startsWith('MPRE')) {
        album ??= link;
      } else if ((pageType == 'MUSIC_PAGE_TYPE_ARTIST' ||
              pageType == 'MUSIC_PAGE_TYPE_USER_CHANNEL' ||
              browseId.startsWith('UC')) &&
          !artists.any((a) => a.browseId == browseId)) {
        artists.add(link);
      }
    }
    // The short byline only repeats the long one, minus links.
    if (artists.isNotEmpty || album != null) break;
  }
  return YtmQueueEntry(
    videoId: track.uri,
    title: track.title,
    artist: track.artist,
    duration: track.duration,
    thumbnailUrl: bestThumbnail(body['thumbnail']),
    videoType: _videoType(body['navigationEndpoint']),
    artists: artists,
    album: album,
    counterpart: counterpart,
  );
}

List<Track> _collectionTracks(
  List<Object?> items, {
  String? fallbackArtwork,
  String? fallbackArtist,
  String? album,
}) {
  final tracks = <Track>[];
  for (final entry in items) {
    final body = navMap(entry, ['musicResponsiveListItemRenderer']);
    if (body == null) continue;
    final item = _listItem(body, fallbackArtwork: fallbackArtwork);
    if (item is! YtmTrackItem) continue;
    var track = item.track;
    if (track.artist == null && fallbackArtist != null) {
      track = track.copyWith(artist: fallbackArtist);
    }
    if (track.album == null && album != null) {
      track = track.copyWith(album: album);
    }
    tracks.add(track);
  }
  return tracks;
}

String _resizeGoogleImage(String url) {
  const size = 'w544-h544';
  final eq = url.lastIndexOf('=');
  if (eq < 0) return '$url=$size';
  final options = url.substring(eq + 1).split('-');
  // Drop the existing size options (w60, h60, s192), keep the rest (l90, rj).
  final kept = options.where((o) => !RegExp(r'^[whs]\d+$').hasMatch(o));
  return '${url.substring(0, eq)}=${[size, ...kept].join('-')}';
}
