import 'package:flutter_test/flutter_test.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/integrations/youtube_music/ytm_parsers.dart';
import 'package:noir/shared/models/media.dart';

import 'fake_innertube.dart';

const _daftPunk = 'UCRr1xG_2WIDs18a6cIiCxeA';

void main() {
  group('parseArtist', () {
    test('header: name, pictures, audience, description', () {
      final a = parseArtist(fixture('artist'), id: _daftPunk);

      expect(a.browseId, _daftPunk);
      expect(a.name, 'Daft Punk');
      expect(a.subscribers, '7.2M subscribers');
      expect(a.audience, '68M monthly audience');
      expect(a.description, startsWith('Daft Punk were a French electronic'));
      // The wide banner as served, and a square crop of it as the avatar.
      expect(a.bannerUrl, endsWith('=w1080-h450-p-l90-rj'));
      expect(a.thumbnailUrl, endsWith('=w544-h544-p-l90-rj'));
    });

    test('top songs and the playlist with all of them', () {
      final a = parseArtist(fixture('artist'), id: _daftPunk);

      expect(a.topSongs, hasLength(5));
      expect(
        a.topSongs.first,
        isA<Track>()
            .having((t) => t.uri, 'uri', 'khnokW3Mw24')
            .having((t) => t.source, 'source', MediaSource.youtube)
            .having(
              (t) => t.title,
              'title',
              'Instant Crush (feat. Julian Casablancas)',
            )
            .having((t) => t.artist, 'artist', 'Daft Punk & Julian Casablancas')
            .having((t) => t.album, 'album', 'Random Access Memories'),
      );
      expect(a.songsPlaylistId, 'OLAK5uy_lNVBcjNtiCwq-n95uoxJ-Gd4vsfMkyZNs');
    });

    test('carousels in page order, items typed', () {
      final a = parseArtist(fixture('artist'), id: _daftPunk);

      expect(a.shelves.map((s) => s.title), [
        'Albums',
        'Singles & EPs',
        'Videos',
        'Live performances',
        'Featured on',
        'Playlists by Daft Punk',
        'Fans might also like',
      ]);
      YtmShelf shelf(String title) =>
          a.shelves.firstWhere((s) => s.title == title);

      expect(shelf('Albums').items, everyElement(isA<YtmAlbumItem>()));
      final album = shelf('Albums').items.first as YtmAlbumItem;
      expect(album.browseId, startsWith('MPRE'));
      expect(album.year, isNotNull);
      expect(
        (shelf('Singles & EPs').items.first as YtmAlbumItem).albumType,
        'Single',
      );
      expect(
        shelf('Videos').items,
        everyElement(
          isA<YtmTrackItem>().having((v) => v.isVideo, 'video', true),
        ),
      );
      final related = shelf('Fans might also like').items;
      expect(related, everyElement(isA<YtmArtistItem>()));
      expect(
        related.first,
        isA<YtmArtistItem>()
            .having((r) => r.title, 'title', 'Gesaffelstein')
            .having((r) => r.browseId, 'browseId', 'UCq7VAQmXDurV-9VN2bSFXvw')
            .having((r) => r.subtitle, 'subtitle', '23.5M monthly audience'),
      );
    });

    test('a page without header or sections is a format error', () {
      expect(
        () => parseArtist(const {'contents': <String, Object?>{}}, id: 'UCx'),
        throwsFormatException,
      );
    });

    test('a bare header still opens', () {
      final a = parseArtist(const {
        'header': {
          'musicHeaderRenderer': {
            'title': {
              'runs': [
                {'text': 'Someone'},
              ],
            },
          },
        },
      }, id: 'UCx');
      expect(a.name, 'Someone');
      expect(a.topSongs, isEmpty);
      expect(a.shelves, isEmpty);
      expect(a.thumbnailUrl, isNull);
    });
  });

  test('InnerTubeClient.artist browses the channel id', () async {
    final http = FakeInnerTube(
      (r) => r.path == '/sw.js_data'
          ? textReply(swJsData)
          : jsonReply(fixture('artist')),
    );
    final client = InnerTubeClient(dio: http.dio(), retryDelay: Duration.zero);

    final artist = await client.artist(_daftPunk);

    expect(http.apiRequests.single.path, '/youtubei/v1/browse');
    expect(http.apiRequests.single.json['browseId'], _daftPunk);
    expect(artist.name, 'Daft Punk');
  });
}
