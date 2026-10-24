import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

const songArt = 'https://lh3.googleusercontent.com/song=w544-h544-l90-rj';

YtmQueueEntry video({
  String title = 'Never Gonna Give You Up',
  String? artist = 'Rick Astley',
  Duration? duration = const Duration(minutes: 3, seconds: 34),
}) => YtmQueueEntry(
  videoId: 'dQw4w9WgXcQ',
  title: title,
  artist: artist,
  duration: duration,
  thumbnailUrl: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg',
  videoType: 'MUSIC_VIDEO_TYPE_OMV',
);

Track song({
  String title = 'Never Gonna Give You Up',
  String? artist = 'Rick Astley',
  Duration? duration = const Duration(minutes: 3, seconds: 33),
  String? artworkUrl = songArt,
}) => Track(
  id: 'yt:lYBUbBu4W08',
  source: MediaSource.youtube,
  title: title,
  uri: 'lYBUbBu4W08',
  artist: artist,
  duration: duration,
  artworkUrl: artworkUrl,
);

void main() {
  group('acceptsCounterpart', () {
    test('same song, length within 5 s', () {
      expect(acceptsCounterpart(video(), song()), isTrue);
      expect(
        acceptsCounterpart(
          video(),
          song(duration: const Duration(minutes: 3, seconds: 39)),
        ),
        isTrue,
      );
    });

    test('without a sure artist match, rejects a length more than 5 s off', () {
      expect(
        acceptsCounterpart(
          video(artist: null),
          song(duration: const Duration(minutes: 3, seconds: 40)),
        ),
        isFalse,
      );
      expect(
        acceptsCounterpart(
          video(artist: null),
          song(duration: const Duration(minutes: 3, seconds: 27)),
        ),
        isFalse,
      );
    });

    test('an exact title and artist match allows up to 90 s', () {
      expect(
        acceptsCounterpart(
          video(duration: const Duration(minutes: 4, seconds: 42)),
          song(duration: const Duration(minutes: 3, seconds: 48)),
        ),
        isTrue,
      );
      expect(
        acceptsCounterpart(
          video(duration: const Duration(minutes: 5, seconds: 10)),
          song(),
        ),
        isFalse,
      );
    });

    test('rejects unknown lengths', () {
      expect(acceptsCounterpart(video(duration: null), song()), isFalse);
      expect(acceptsCounterpart(video(), song(duration: null)), isFalse);
    });

    test('video title noise is ignored', () {
      expect(
        acceptsCounterpart(
          video(
            title:
                'Rick Astley - Never Gonna Give You Up (Official Music Video)',
            artist: 'RickAstleyVEVO',
          ),
          song(),
        ),
        isTrue,
      );
    });

    test('rejects a different title', () {
      expect(
        acceptsCounterpart(video(), song(title: 'Together Forever')),
        isFalse,
      );
      // A live version is not the studio recording.
      expect(
        acceptsCounterpart(
          video(title: 'Never Gonna Give You Up (Live at Glastonbury 2023)'),
          song(),
        ),
        isFalse,
      );
    });

    test('rejects a different artist', () {
      expect(acceptsCounterpart(video(), song(artist: 'Cover Band')), isFalse);
      expect(acceptsCounterpart(video(artist: null), song()), isTrue);
    });

    test('needs square art on the song', () {
      expect(
        acceptsCounterpart(
          video(),
          song(artworkUrl: 'https://i.ytimg.com/vi/lYBUbBu4W08/hqdefault.jpg'),
        ),
        isFalse,
      );
      expect(acceptsCounterpart(video(), song(artworkUrl: null)), isFalse);
    });
  });

  test('counterpartQuery: cleaned title and artist', () {
    expect(counterpartQuery(video()), 'Never Gonna Give You Up Rick Astley');
    expect(
      counterpartQuery(
        video(
          title: 'Rick Astley - Never Gonna Give You Up (Official Video) [4K]',
          artist: 'RickAstleyVEVO',
        ),
      ),
      'Never Gonna Give You Up Rick Astley',
    );
  });

  test('squareArtOf: own art, else the song twin', () {
    expect(squareArtOf(video()), isNull);
    const own = YtmQueueEntry(
      videoId: 'a',
      title: 'Thriller',
      thumbnailUrl: 'https://yt3.googleusercontent.com/thr=w544-h544-l90-rj',
    );
    expect(squareArtOf(own), 'https://yt3.googleusercontent.com/thr');
    const twin = YtmQueueEntry(
      videoId: 'b',
      title: 'Thriller',
      thumbnailUrl: 'https://i.ytimg.com/vi/b/hq720.jpg',
      counterpart: own,
    );
    expect(squareArtOf(twin), 'https://yt3.googleusercontent.com/thr');
  });

  test('ResolvedArt sizes its URL and survives JSON', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
    final art = ResolvedArt(
      squareBase: 'https://lh3.googleusercontent.com/x',
      checkedAt: at,
    );
    expect(art.isVideoThumb, isFalse);
    expect(
      art.squareUrl(500),
      'https://lh3.googleusercontent.com/x=w544-h544-l90-rj',
    );
    expect(ResolvedArt.fromJson(art.toJson()), art);

    final linked = ResolvedArt(
      squareBase: 'https://lh3.googleusercontent.com/x',
      checkedAt: at,
      videoType: 'MUSIC_VIDEO_TYPE_ATV',
      links: const YtmTrackLinks(
        artists: [
          (name: 'Luis Fonsi', browseId: 'UCk91oFc2hY2CdHirU93baLg'),
          (name: 'Daddy Yankee', browseId: 'UCXRloA7YFgCfd6sU2_Y12cA'),
        ],
        album: (name: 'VIDA', browseId: 'MPREb_abc'),
      ),
    );
    final restored = ResolvedArt.fromJson(linked.toJson());
    expect(restored, linked);
    expect(restored!.links!.artists.last.name, 'Daddy Yankee');
    expect(restored.links!.album?.browseId, 'MPREb_abc');
    expect(restored.videoType, 'MUSIC_VIDEO_TYPE_ATV');

    final none = ResolvedArt.none(checkedAt: at);
    expect(none.isVideoThumb, isTrue);
    expect(none.squareUrl(500), isNull);
    expect(ResolvedArt.fromJson(none.toJson()), none);
    expect(ResolvedArt.fromJson({'b': 3, 't': 1}), isNull);
    expect(ResolvedArt.fromJson('x'), isNull);
  });
}
