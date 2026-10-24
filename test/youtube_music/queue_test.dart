import 'package:flutter_test/flutter_test.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/integrations/youtube_music/ytm_parsers.dart';

import 'fake_innertube.dart';

/// A `playlistPanelVideoRenderer` body, as get_queue sends it.
Map<String, Object?> panel(
  String videoId, {
  required String title,
  required String thumbnail,
  required String type,
  String length = '3:34',
}) => {
  'title': {
    'runs': [
      {'text': title},
    ],
  },
  'longBylineText': {
    'runs': [
      {'text': 'Rick Astley'},
    ],
  },
  'thumbnail': {
    'thumbnails': [
      {'url': thumbnail, 'width': 544, 'height': 544},
    ],
  },
  'lengthText': {
    'runs': [
      {'text': length},
    ],
  },
  'videoId': videoId,
  'navigationEndpoint': {
    'watchEndpoint': {
      'videoId': videoId,
      'watchEndpointMusicSupportedConfigs': {
        'watchEndpointMusicConfig': {'musicVideoType': type},
      },
    },
  },
};

void main() {
  group('parseQueue', () {
    test('songs carry square art, music videos a video frame', () {
      final queue = parseQueue(fixture('get_queue'));

      expect(queue.keys, ['dQw4w9WgXcQ', 'kJQP7kiw5Fk', 'Z85lxckrtzg']);

      final song = queue['Z85lxckrtzg']!;
      expect(song.isSong, isTrue);
      expect(song.videoType, 'MUSIC_VIDEO_TYPE_ATV');
      expect(song.title, 'Thriller');
      expect(song.artist, 'Michael Jackson');
      expect(song.duration, const Duration(minutes: 5, seconds: 58));
      expect(
        song.thumbnailUrl,
        startsWith('https://yt3.googleusercontent.com/'),
      );

      final video = queue['dQw4w9WgXcQ']!;
      expect(video.isSong, isFalse);
      expect(video.videoType, 'MUSIC_VIDEO_TYPE_OMV');
      expect(video.title, 'Never Gonna Give You Up');
      expect(video.artist, 'Rick Astley');
      expect(video.duration, const Duration(minutes: 3, seconds: 34));
      // The largest frame (853 px wide).
      expect(
        video.thumbnailUrl,
        allOf(startsWith('https://i.ytimg.com/vi/dQw4w9WgXcQ/hq720.jpg')),
      );
      expect(video.counterpart, isNull);

      expect(queue['kJQP7kiw5Fk']!.artist, 'Luis Fonsi & Daddy Yankee');
    });

    test('byline links: artist channels and album', () {
      final queue = parseQueue(fixture('get_queue'));

      final song = queue['Z85lxckrtzg']!;
      expect(song.artists, [
        (name: 'Michael Jackson', browseId: 'UCoIOOL7QKuBhQHVKL8y7BEQ'),
      ]);
      expect(song.album, (name: 'Thriller', browseId: 'MPREb_dqWTncCjkSp'));
      expect(
        song.links,
        const YtmTrackLinks(
          artists: [
            (name: 'Michael Jackson', browseId: 'UCoIOOL7QKuBhQHVKL8y7BEQ'),
          ],
          album: (name: 'Thriller', browseId: 'MPREb_dqWTncCjkSp'),
        ),
      );

      // Two linked artists; "1.8B views" style runs are not links.
      final video = queue['kJQP7kiw5Fk']!;
      expect(video.artists, [
        (name: 'Luis Fonsi', browseId: 'UCk91oFc2hY2CdHirU93baLg'),
        (name: 'Daddy Yankee', browseId: 'UCXRloA7YFgCfd6sU2_Y12cA'),
      ]);
      expect(video.album, isNull);
      expect(queue['dQw4w9WgXcQ']!.artists.single.name, 'Rick Astley');
    });

    test('wrapper: video and its song twin point at each other', () {
      final queue = parseQueue({
        'queueDatas': [
          {
            'content': {
              'playlistPanelVideoWrapperRenderer': {
                'primaryRenderer': {
                  'playlistPanelVideoRenderer': panel(
                    'dQw4w9WgXcQ',
                    title: 'Never Gonna Give You Up',
                    thumbnail: 'https://i.ytimg.com/vi/dQw4w9WgXcQ/sd.jpg',
                    type: 'MUSIC_VIDEO_TYPE_OMV',
                  ),
                },
                'counterpart': [
                  {
                    'counterpartRenderer': {
                      'playlistPanelVideoRenderer': panel(
                        'lYBUbBu4W08',
                        title: 'Never Gonna Give You Up',
                        thumbnail:
                            'https://lh3.googleusercontent.com/art=w60-h60',
                        type: 'MUSIC_VIDEO_TYPE_ATV',
                        length: '3:33',
                      ),
                    },
                  },
                ],
              },
            },
          },
        ],
      });

      final video = queue['dQw4w9WgXcQ']!;
      expect(video.isSong, isFalse);
      expect(video.counterpart?.videoId, 'lYBUbBu4W08');
      expect(video.counterpart?.isSong, isTrue);
      expect(
        video.counterpart?.thumbnailUrl,
        'https://lh3.googleusercontent.com/art=w544-h544',
      );
      expect(queue['lYBUbBu4W08']?.counterpart?.videoId, 'dQw4w9WgXcQ');
    });

    test('skips entries without a video id or title', () {
      final queue = parseQueue({
        'queueDatas': [
          {'content': <String, Object?>{}},
          {
            'content': {
              'playlistPanelVideoRenderer': {'title': 'no id'},
            },
          },
        ],
      });
      expect(queue, isEmpty);
    });

    test('a response without queue data is a format error', () {
      expect(() => parseQueue({}), throwsFormatException);
    });
  });

  group('InnerTubeClient.queue', () {
    late FakeInnerTube http;

    setUp(() => http = FakeInnerTube(recordedYouTubeMusic));

    InnerTubeClient client() =>
        InnerTubeClient(dio: http.dio(), gl: 'US', retryDelay: Duration.zero);

    test('posts the ids to music/get_queue', () async {
      final queue = await client().queue(['Z85lxckrtzg', 'dQw4w9WgXcQ']);

      final r = http.apiRequests.single;
      expect(r.path, '/youtubei/v1/music/get_queue');
      expect(r.json['videoIds'], ['Z85lxckrtzg', 'dQw4w9WgXcQ']);
      expect(
        (r.json['context']! as Map)['client'],
        isA<Map<Object?, Object?>>(),
      );
      expect(queue['Z85lxckrtzg'], isA<YtmQueueEntry>());
    });

    test('dedupes and asks in batches of 50', () async {
      final ids = [for (var i = 0; i < 120; i++) 'id$i', 'id0', 'id1'];
      await client().queue(ids);

      final batches = [
        for (final r in http.apiRequests) (r.json['videoIds']! as List).length,
      ];
      expect(batches, [50, 50, 20]);
    });

    test('no request for no ids', () async {
      expect(await client().queue([]), isEmpty);
      expect(http.apiRequests, isEmpty);
    });
  });
}
