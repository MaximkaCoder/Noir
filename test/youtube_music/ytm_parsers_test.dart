import 'package:flutter_test/flutter_test.dart';
import 'package:noir/integrations/youtube_music/json_nav.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/integrations/youtube_music/ytm_parsers.dart';
import 'package:noir/shared/models/media.dart';

import 'fake_innertube.dart';

void main() {
  group('home', () {
    test('first page: shelves, items, chips and continuation', () {
      final page = parseHome(fixture('home'));

      expect(page.shelves.map((s) => s.title), [
        'Quick picks',
        'Take it easy',
        'Party music',
      ]);
      expect(page.continuation, 'TEST_CONTINUATION_1');
      expect(page.chips.map((c) => c.title), ['Podcasts', 'Relax', 'Party']);
      expect(page.chips.every((c) => c.params.isNotEmpty), isTrue);

      final song = page.shelves.first.items.first as YtmTrackItem;
      expect(song.isVideo, isFalse);
      expect(
        song.track,
        isA<Track>()
            .having((t) => t.id, 'id', 'yt:Z85lxckrtzg')
            .having((t) => t.uri, 'uri', 'Z85lxckrtzg')
            .having((t) => t.source, 'source', MediaSource.youtube)
            .having((t) => t.title, 'title', 'Thriller')
            .having((t) => t.artist, 'artist', 'Michael Jackson')
            .having((t) => t.album, 'album', 'Thriller'),
      );
      expect(song.track.artworkUrl, endsWith('=w544-h544-l90-rj'));

      final playlist = page.shelves[1].items.first as YtmPlaylistItem;
      expect(playlist.title, 'Mellow Pop Classics');
      expect(
        playlist.playlistId,
        'RDCLAK5uy_nDL8KeBrUagwyISwNmyEiSfYgz1gVCesg',
      );
      expect(playlist.subtitle, startsWith('Lewis Capaldi, Robbie Williams'));
      expect(playlist.thumbnailUrl, contains('googleusercontent.com'));
    });

    test('continuation page: albums and songs', () {
      final page = parseHome(fixture('home_continuation'));

      expect(page.shelves.map((s) => s.title), [
        'New releases',
        'The sound of autumn',
        'Trending songs for you',
      ]);
      expect(page.chips, isEmpty);
      final album = page.shelves.first.items[1] as YtmAlbumItem;
      expect(album.title, 'Naked');
      expect(album.browseId, 'MPREb_43hwQ7LHfaq');
      expect(album.albumType, 'Single');
      expect(album.artist, 'Dean Lewis');

      final collab = page.shelves[2].items[1] as YtmTrackItem;
      expect(
        collab.track.artist,
        'Justice, Tame Impala, SZA & Grand Theft Auto VI',
      );
    });

    test('a response without a section list is a format error', () {
      expect(() => parseHome({'contents': {}}), throwsFormatException);
    });
  });

  group('next (radio)', () {
    test('first page: tracks, playlist and radio continuation', () {
      final page = parseNext(fixture('next'));

      expect(page.playlistId, 'RDAMVMZ85lxckrtzg');
      expect(page.continuation, 'TEST_CONTINUATION_1');
      expect(page.tracks.map((t) => t.title), [
        'Thriller',
        'Bad',
        'Rasputin',
        "Stayin' Alive",
        'Another One Bites The Dust',
      ]);
      final bad = page.tracks[1];
      expect(bad.artist, 'Michael Jackson');
      expect(bad.album, 'The Essential Michael Jackson');
      expect(bad.duration, const Duration(minutes: 4, seconds: 8));
      expect(bad.artworkUrl, isNotNull);

      final video = page.tracks[2]; // "5.2M views • 50K likes", no album.
      expect(video.artist, 'Boney M.');
      expect(video.album, isNull);
    });

    test('continuation page', () {
      final page = parseNext(fixture('next_continuation'));

      expect(page.tracks, hasLength(3));
      expect(page.tracks.first.title, 'Kiss');
      expect(page.continuation, 'TEST_CONTINUATION_1');
    });

    test('unwraps playlistPanelVideoWrapperRenderer and skips others', () {
      final page = parseNext({
        'contents': {
          'playlistPanelRenderer': {
            'contents': [
              {'automixPreviewVideoRenderer': <String, Object?>{}},
              {
                'playlistPanelVideoWrapperRenderer': {
                  'primaryRenderer': {
                    'playlistPanelVideoRenderer': {
                      'videoId': 'abc',
                      'title': {'simpleText': 'Wrapped'},
                    },
                  },
                },
              },
            ],
          },
        },
      });
      expect(page.tracks.single.uri, 'abc');
      expect(
        page.tracks.single.artworkUrl,
        'https://i.ytimg.com/vi/abc/mqdefault.jpg',
      );
    });
  });

  group('search', () {
    test('songs', () {
      final page = parseSearch(fixture('search_songs'));

      expect(page.continuation, 'TEST_CONTINUATION_1');
      final songs = page.items.cast<YtmTrackItem>();
      expect(songs, hasLength(3));
      expect(songs.every((s) => !s.isVideo), isTrue);
      final first = songs.first.track;
      expect(first.title, 'Da Funk');
      expect(first.artist, 'Daft Punk');
      expect(first.album, 'Homework');
      expect(first.duration, const Duration(minutes: 5, seconds: 29));
      expect(songs[1].track.artist, 'Daft Punk & Julian Casablancas');
    });

    test('videos', () {
      final items = parseSearch(fixture('search_videos')).items;
      final video = items.first as YtmTrackItem;
      expect(video.isVideo, isTrue);
      expect(video.track.artist, 'Daft Punk');
      expect(video.track.album, isNull);
      expect(video.track.duration, const Duration(minutes: 5, seconds: 43));
      expect(video.track.artworkUrl, startsWith('https://i.ytimg.com/vi/'));
    });

    test('albums', () {
      final album = parseSearch(fixture('search_albums')).items.first;
      expect(
        album,
        isA<YtmAlbumItem>()
            .having((a) => a.title, 'title', 'Random Access Memories')
            .having((a) => a.browseId, 'browseId', 'MPREb_K8qWMWVqXGi')
            .having((a) => a.artist, 'artist', 'Daft Punk')
            .having((a) => a.year, 'year', 2013)
            .having((a) => a.albumType, 'albumType', 'Album'),
      );
    });

    test('artists', () {
      final artist = parseSearch(fixture('search_artists')).items.first;
      expect(
        artist,
        isA<YtmArtistItem>()
            .having((a) => a.title, 'title', 'Daft Punk')
            .having((a) => a.browseId, 'browseId', startsWith('UC'))
            .having((a) => a.subtitle, 'subtitle', '68M monthly audience'),
      );
    });

    test('playlists', () {
      final items = parseSearch(fixture('search_featured_playlists')).items;
      final playlist = items.first as YtmPlaylistItem;
      expect(playlist.title, 'Presenting Daft Punk');
      expect(playlist.playlistId, startsWith('RDCLAK5uy_'));
      expect(playlist.subtitle, 'YouTube Music • 35 songs');
    });

    test('continuation page', () {
      final page = parseSearch(fixture('search_continuation'));
      expect(page.items, hasLength(3));
      expect(page.items.first, isA<YtmTrackItem>());
      expect(page.continuation, 'TEST_CONTINUATION_1');
    });

    test('suggestions: phrases and direct hits', () {
      final s = parseSearchSuggestions(fixture('search_suggestions'));
      expect(s.queries.first, 'daft punk');
      expect(s.queries, contains('daft punk one more time'));
      expect(s.items.first, isA<YtmArtistItem>());
      expect(s.items.whereType<YtmTrackItem>(), isNotEmpty);
    });
  });

  group('collections', () {
    test('playlist: header, tracks and track continuation', () {
      final p = parseCollection(
        fixture('playlist'),
        id: 'VLPLwNv9Hhd8gZjNoQdpd2kBa3fwXNeJjzDX',
      );

      expect(p.title, '500 Greatest Love Songs Of All Time');
      expect(p.author, 'Inko Infinity2');
      expect(p.subtitle, startsWith('Playlist'));
      expect(p.playlistId, 'PLwNv9Hhd8gZjNoQdpd2kBa3fwXNeJjzDX');
      expect(p.thumbnailUrl, isNotNull);
      // The shelf's continuation item, not the "related playlists" one.
      expect(p.continuation, 'TEST_CONTINUATION_1');
      expect(p.tracks, hasLength(4));
      expect(p.tracks.first.title, 'I Will Always Love You');
      expect(p.tracks.first.artist, 'Whitney Houston');
      expect(p.tracks.first.duration, const Duration(minutes: 4, seconds: 34));
    });

    test('playlist continuation', () {
      final page = parsePlaylistContinuation(fixture('playlist_continuation'));
      expect(page.tracks.map((t) => t.title).take(2), [
        'We Belong (Official Music Video)',
        'Strangers In The Night',
      ]);
      expect(page.continuation, 'TEST_CONTINUATION_1');
    });

    test('album: tracks inherit album title and cover', () {
      final a = parseCollection(fixture('album'), id: 'MPREb_K8qWMWVqXGi');

      expect(a.title, 'Random Access Memories');
      expect(a.author, 'Daft Punk');
      expect(a.playlistId, 'OLAK5uy_kNhM2yaBTOVwrcZJepB1C9P3-n5_Sfy5c');
      expect(a.continuation, isNull);
      expect(a.tracks.map((t) => t.title), [
        'Give Life Back to Music',
        'The Game of Love',
        'Giorgio by Moroder',
        'Within',
      ]);
      for (final t in a.tracks) {
        expect(t.album, 'Random Access Memories');
        expect(t.artist, 'Daft Punk');
        expect(t.artworkUrl, a.thumbnailUrl);
      }
      expect(a.tracks.first.duration, const Duration(minutes: 4, seconds: 36));
    });
  });

  group('robustness', () {
    test('unknown renderers and broken items are skipped', () {
      expect(
        parseItem({'musicMultiRowListItemRenderer': <String, Object?>{}}),
        isNull,
      );
      expect(
        parseItem({
          'musicTwoRowItemRenderer': {'title': 42},
        }),
        isNull,
      );
      expect(parseItem('nonsense'), isNull);
      expect(
        parseItem({
          'musicTwoRowItemRenderer': {
            'title': {'simpleText': 'A podcast'},
            'navigationEndpoint': {
              'browseEndpoint': {
                'browseId': 'MPSP1',
                'browseEndpointContextSupportedConfigs': {
                  'browseEndpointContextMusicConfig': {
                    'pageType': 'MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE',
                  },
                },
              },
            },
          },
        }),
        isNull,
      );
    });

    test('a shelf of only unknown items is dropped', () {
      final page = parseHome({
        'contents': {
          'sectionListRenderer': {
            'contents': [
              {
                'musicCarouselShelfRenderer': {
                  'header': {
                    'musicCarouselShelfBasicHeaderRenderer': {
                      'title': {'simpleText': 'Podcasts'},
                    },
                  },
                  'contents': [
                    {'musicMultiRowListItemRenderer': <String, Object?>{}},
                  ],
                },
              },
              {'somethingNewRenderer': <String, Object?>{}},
            ],
          },
        },
      });
      expect(page.shelves, isEmpty);
      expect(page.continuation, isNull);
    });
  });

  group('helpers', () {
    test('nav follows keys and indices, null on mismatch', () {
      final json = {
        'a': [
          {'b': 'x'},
        ],
      };
      expect(nav(json, ['a', 0, 'b']), 'x');
      expect(nav(json, ['a', 1, 'b']), isNull);
      expect(nav(json, ['a', 'b']), isNull);
      expect(navString(json, ['a']), isNull);
      expect(navList(json, ['missing']), isEmpty);
    });

    test('textOf joins runs', () {
      expect(
        textOf({
          'runs': [
            {'text': 'A'},
            {'text': ' & '},
            {'text': 'B'},
          ],
        }),
        'A & B',
      );
      expect(textOf({'simpleText': 'S'}), 'S');
      expect(textOf(null), isNull);
    });

    test('bestThumbnail resizes Google art to a 544 px square', () {
      expect(
        bestThumbnail([
          {
            'url': 'https://lh3.googleusercontent.com/x=w60-h60-l90-rj',
            'width': 60,
          },
          {
            'url': 'https://lh3.googleusercontent.com/x=w120-h120-l90-rj',
            'width': 120,
          },
        ]),
        'https://lh3.googleusercontent.com/x=w544-h544-l90-rj',
      );
      expect(
        bestThumbnail([
          {'url': 'https://yt3.googleusercontent.com/y=s192', 'width': 192},
        ]),
        'https://yt3.googleusercontent.com/y=w544-h544',
      );
      expect(
        bestThumbnail({
          'thumbnails': [
            {'url': 'https://i.ytimg.com/vi/a/default.jpg', 'width': 120},
            {'url': 'https://i.ytimg.com/vi/a/hqdefault.jpg', 'width': 480},
          ],
        }),
        'https://i.ytimg.com/vi/a/hqdefault.jpg',
      );
      expect(bestThumbnail(null), isNull);
    });

    test('parseClock', () {
      expect(parseClock('3:21'), const Duration(minutes: 3, seconds: 21));
      expect(
        parseClock('1:02:03'),
        const Duration(hours: 1, minutes: 2, seconds: 3),
      );
      expect(parseClock('1.2B plays'), isNull);
    });
  });
}
