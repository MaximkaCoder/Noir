import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/youtube/domain/music_filter.dart';

void main() {
  bool music(String? category, String channel) =>
      isMusicVideo(categoryId: category, channelTitle: channel);

  test('the Music category counts, whatever the channel', () {
    expect(music('10', 'Some Vlogger'), isTrue);
  });

  test('YouTube Music "Topic" channels count', () {
    expect(music('22', 'Mara Vale - Topic'), isTrue);
    expect(music(null, 'Mara Vale - Topic'), isTrue, reason: 'not backfilled');
    expect(music('22', 'Topic Talks'), isFalse);
    expect(music('22', 'Mara Vale -Topic'), isFalse);
  });

  test('VEVO channels count, but not words that merely start with VEVO', () {
    expect(music('24', 'TaylorSwiftVEVO'), isTrue);
    expect(music('24', 'VEVO Hits'), isTrue);
    expect(music('24', 'Best of VEVO 2026'), isTrue);
    expect(music('28', 'VEVOR Tools'), isFalse);
    expect(music('24', 'vevo fan edits'), isFalse);
  });

  test('anything else is not music', () {
    expect(music('20', 'Gaming Weekly'), isFalse);
    expect(music('', 'Cooking with Kei'), isFalse);
    expect(music(null, ''), isFalse);
  });
}
