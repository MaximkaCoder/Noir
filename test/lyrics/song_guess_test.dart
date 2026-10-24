import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/lyrics/domain/song_guess.dart';

void main() {
  group('cleanArtistName', () {
    test('strips YouTube channel suffixes', () {
      expect(cleanArtistName('Daft Punk - Topic'), 'Daft Punk');
      expect(cleanArtistName('TaylorSwiftVEVO'), 'TaylorSwift');
      expect(cleanArtistName('Adele VEVO'), 'Adele');
      expect(cleanArtistName('Imagine Dragons Official'), 'Imagine Dragons');
      expect(cleanArtistName('Muse'), 'Muse');
    });
  });

  group('cleanSongTitle', () {
    test('drops noise brackets but keeps meaningful ones', () {
      expect(
        cleanSongTitle('Never Gonna Give You Up (Official Music Video) [4K]'),
        'Never Gonna Give You Up',
      );
      expect(cleanSongTitle('Song (Lyric Video)'), 'Song');
      expect(cleanSongTitle('Song [Official Audio]'), 'Song');
      expect(cleanSongTitle('Song (Visualizer)'), 'Song');
      expect(cleanSongTitle('Song (Remastered 2011)'), 'Song');
      expect(cleanSongTitle('Song (HD)'), 'Song');
      expect(cleanSongTitle('Song【MV】'), 'Song');
      expect(cleanSongTitle('Song (Remix)'), 'Song (Remix)');
      expect(
        cleanSongTitle('Song (Live at Wembley)'),
        'Song (Live at Wembley)',
      );
      expect(cleanSongTitle('Song (Remix)', allBrackets: true), 'Song');
    });

    test('drops feat. in brackets and as a tail', () {
      expect(cleanSongTitle('Song (feat. Someone)'), 'Song');
      expect(cleanSongTitle('Song [ft. Someone]'), 'Song');
      expect(cleanSongTitle('Song feat. Someone Else'), 'Song');
      expect(cleanSongTitle('Song (with Someone)'), 'Song');
      // "ft" inside a word is not a feature.
      expect(cleanSongTitle('Left Behind'), 'Left Behind');
    });

    test('drops unbracketed trailing noise and hashtags', () {
      expect(cleanSongTitle('Song Official Music Video'), 'Song');
      expect(cleanSongTitle('Song #shorts #music'), 'Song');
      // Not noise on its own.
      expect(cleanSongTitle('Video Games'), 'Video Games');
    });
  });

  group('songGuesses', () {
    test('splits "Artist - Title (Official Video) [4K]"', () {
      final g = songGuesses(
        title: 'Rick Astley - Never Gonna Give You Up (Official Video) [4K]',
        artist: 'Rick Astley',
      );
      expect(g.first, (
        artist: 'Rick Astley',
        title: 'Never Gonna Give You Up',
      ));
    });

    test('accepts en and em dashes', () {
      expect(songGuesses(title: 'Artist – Title', artist: 'x').first, (
        artist: 'Artist',
        title: 'Title',
      ));
      expect(songGuesses(title: 'Artist — Title', artist: 'x').first, (
        artist: 'Artist',
        title: 'Title',
      ));
    });

    test('uses the channel when the title has no artist', () {
      expect(
        songGuesses(
          title: 'Get Lucky (Official Audio)',
          artist: 'Daft Punk - Topic',
        ).first,
        (artist: 'Daft Punk', title: 'Get Lucky'),
      );
      expect(
        songGuesses(title: 'Shake It Off', artist: 'TaylorSwiftVEVO').first,
        (artist: 'TaylorSwift', title: 'Shake It Off'),
      );
    });

    test('flips "Title - Artist" when the channel matches the right side', () {
      final g = songGuesses(
        title: 'Blinding Lights - The Weeknd',
        artist: 'TheWeekndVEVO',
      );
      expect(g.first, (artist: 'The Weeknd', title: 'Blinding Lights'));
      expect(g, contains((artist: 'Blinding Lights', title: 'The Weeknd')));
    });

    test('handles "Title | Artist" and pipe noise', () {
      expect(
        songGuesses(title: 'Midnight City | M83', artist: 'Some Uploader'),
        contains((artist: 'M83', title: 'Midnight City')),
      );
      expect(
        songGuesses(
          title: 'M83 - Midnight City | Official Video',
          artist: 'M83VEVO',
        ).first,
        (artist: 'M83', title: 'Midnight City'),
      );
    });

    test('reads "Artist "Title"" quotes', () {
      expect(
        songGuesses(
          title: 'Muse "Uprising" (Official Video)',
          artist: 'Muse',
        ).first,
        (artist: 'Muse', title: 'Uprising'),
      );
    });

    test('drops feat. from the artist side', () {
      expect(
        songGuesses(title: 'Artist feat. Guest - Song', artist: 'x').first,
        (artist: 'Artist', title: 'Song'),
      );
    });

    test('adds a bracket-free fallback and no duplicates', () {
      final g = songGuesses(title: 'Song (Acoustic)', artist: 'Band');
      expect(g, [
        (artist: 'Band', title: 'Song (Acoustic)'),
        (artist: 'Band', title: 'Song'),
      ]);
    });

    test('local tags without artist give a title-only guess', () {
      expect(songGuesses(title: 'Lonely Song'), [
        (artist: null, title: 'Lonely Song'),
      ]);
    });
  });

  group('similarity', () {
    test('ignores case, punctuation and spacing', () {
      expect(similarity('The Weeknd', 'TheWeeknd'), 1);
      expect(similarity('AC/DC', 'acdc'), 1);
    });

    test('scores partial overlaps lower', () {
      expect(
        similarity('Blinding Lights', 'Blinding Lights Remix'),
        lessThan(1),
      );
      expect(
        similarity('Blinding Lights', 'Blinding Lights Remix'),
        greaterThan(0.5),
      );
      expect(similarity('Blinding Lights', 'Save Your Tears'), 0);
    });
  });
}
