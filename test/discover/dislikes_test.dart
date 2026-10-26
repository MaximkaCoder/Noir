import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';

import '../helpers/fake_innertube_client.dart';

void main() {
  const dislikes = Dislikes(
    songs: {
      'd1': DislikedSong('d1', 'Labyrinth', 'Face'),
      'm1': DislikedSong('m1', 'One', 'Mara'),
      'm2': DislikedSong('m2', 'Two', 'Mara'),
    },
    artists: {'blocked band': 'Blocked Band'},
  );

  test('hides disliked songs and blocked artists, case-insensitively', () {
    expect(dislikes.hides(ytTrack('d1', artist: 'Someone')), isTrue);
    expect(dislikes.hides(ytTrack('x', artist: 'BLOCKED band ')), isTrue);
    expect(dislikes.hides(ytTrack('x', artist: 'Face')), isFalse);
    expect(dislikes.strikes(ytTrack('x', artist: 'face')), 1);
    expect(dislikes.strikes(ytTrack('x', artist: 'Mara')), 2);
  });

  test('survives a JSON round trip', () {
    final back = Dislikes.fromJson(dislikes.toJson());
    expect(back.songs.keys, ['d1', 'm1', 'm2']);
    expect(back.songs['d1']!.artist, 'Face');
    expect(back.artists, {'blocked band': 'Blocked Band'});
  });

  test('For you drops hidden songs, moves an artist with one dislike back '
      'and drops one with two', () {
    final shelves = composeForYou(
      [
        (
          seed: ytTrack('seed', artist: 'Seed'),
          tracks: [
            ytTrack('f1', artist: 'Face'),
            ytTrack('d1', artist: 'Other'),
            ytTrack('m3', artist: 'Mara'),
            ytTrack('b1', artist: 'Blocked Band'),
            ytTrack('ok1', artist: 'Fine'),
            ytTrack('ok2', artist: 'Fine'),
          ],
        ),
      ],
      const {},
      dislikes: dislikes,
    );
    final mix = shelves.first.items.cast<YtmTrackItem>();
    expect([for (final i in mix) i.videoId], ['ok1', 'ok2', 'f1']);
  });
}
