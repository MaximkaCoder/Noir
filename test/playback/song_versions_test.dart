import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/playback/application/song_versions.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';

YtmQueueEntry entry(
  String id,
  String type, {
  Duration? duration,
  YtmQueueEntry? twin,
}) => YtmQueueEntry(
  videoId: id,
  title: 'False Alarm',
  duration: duration,
  videoType: 'MUSIC_VIDEO_TYPE_$type',
  counterpart: twin,
);

void main() {
  late FakeInnerTubeClient client;
  late SongVersions versions;

  setUp(() {
    client = FakeInnerTubeClient();
    versions = SongVersions(client);
  });

  test('a music video plays as its song twin', () async {
    client.queueEntries['omv'] = entry(
      'omv',
      'OMV',
      duration: const Duration(minutes: 5, seconds: 46),
      twin: entry(
        'atv',
        'ATV',
        duration: const Duration(minutes: 3, seconds: 40),
      ),
    );
    final song = await versions.resolve(ytTrack('omv', title: 'False Alarm'));
    expect(song.uri, 'atv');
    expect(song.id, 'yt:atv');
    expect(song.title, 'False Alarm');
    expect(song.duration, const Duration(minutes: 3, seconds: 40));

    // Remembered: no second request.
    await versions.resolve(ytTrack('omv'));
    expect(client.calls.where((c) => c.startsWith('queue')), hasLength(1));
  });

  test('songs, twinless videos and unknown ids stay as they are', () async {
    client.queueEntries
      ..['atv'] = entry('atv', 'ATV', twin: entry('omv', 'OMV'))
      ..['ugc'] = entry('ugc', 'UGC');
    for (final id in ['atv', 'ugc', 'unknown']) {
      expect((await versions.resolve(ytTrack(id))).uri, id);
    }
  });

  test('a failed lookup keeps the video and asks again later', () async {
    client.error = const InnerTubeException(
      InnerTubeErrorKind.network,
      'offline',
    );
    expect((await versions.resolve(ytTrack('omv'))).uri, 'omv');
    client
      ..error = null
      ..queueEntries['omv'] = entry('omv', 'OMV', twin: entry('atv', 'ATV'));
    expect((await versions.resolve(ytTrack('omv'))).uri, 'atv');
  });
}
