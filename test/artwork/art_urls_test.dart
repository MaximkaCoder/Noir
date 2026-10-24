import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/artwork/domain/art_urls.dart';

void main() {
  const art = 'https://lh3.googleusercontent.com/AbC-d_E';

  group('artBucket', () {
    test('rounds up to 120/226/544/1200', () {
      expect(artBucket(1), 120);
      expect(artBucket(120), 120);
      expect(artBucket(120.5), 226);
      expect(artBucket(226), 226);
      expect(artBucket(300), 544);
      expect(artBucket(544), 544);
      expect(artBucket(545), 1200);
      expect(artBucket(1200), 1200);
    });

    test('caps at the largest bucket', () {
      expect(artBucket(4000), 1200);
    });
  });

  group('resizeGoogleArt', () {
    test('replaces size options, keeps the rest', () {
      expect(
        resizeGoogleArt('$art=w544-h544-l90-rj', 1000),
        '$art=w1200-h1200-l90-rj',
      );
      expect(
        resizeGoogleArt('$art=w60-h60-p-l90-rj', 72),
        '$art=w120-h120-p-l90-rj',
      );
      expect(resizeGoogleArt('$art=s192', 400), '$art=w544-h544-l90-rj');
      expect(resizeGoogleArt('$art=s0', 200), '$art=w226-h226-l90-rj');
    });

    test('adds a suffix when there is none', () {
      expect(resizeGoogleArt(art, 100), '$art=w120-h120-l90-rj');
      expect(
        resizeGoogleArt('https://yt3.ggpht.com/x', 600),
        'https://yt3.ggpht.com/x=w1200-h1200-l90-rj',
      );
    });

    test('leaves other URLs alone', () {
      const thumb = 'https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg';
      expect(resizeGoogleArt(thumb, 500), thumb);
      expect(resizeGoogleArt('/music/cover.jpg', 500), '/music/cover.jpg');
    });

    test('googleArtBase strips only a trailing option string', () {
      expect(googleArtBase('$art=w60-h60-l90-rj'), art);
      expect(googleArtBase(art), art);
      expect(
        googleArtBase('https://x.googleusercontent.com/a=b/c'),
        'https://x.googleusercontent.com/a=b/c',
      );
    });

    test('isGoogleArt', () {
      expect(isGoogleArt(art), isTrue);
      expect(isGoogleArt('https://yt3.googleusercontent.com/a'), isTrue);
      expect(isGoogleArt('https://yt3.ggpht.com/a'), isTrue);
      expect(isGoogleArt('https://i.ytimg.com/vi/x/hqdefault.jpg'), isFalse);
      expect(isGoogleArt('https://evilgoogleusercontent.com/a'), isFalse);
    });
  });

  group('YouTube thumbnails', () {
    test('video id from i.ytimg URLs', () {
      expect(
        youtubeThumbnailVideoId(
          'https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        youtubeThumbnailVideoId(
          'https://i9.ytimg.com/vi_webp/dQw4w9WgXcQ/hq720.webp?sqp=x',
        ),
        'dQw4w9WgXcQ',
      );
      expect(
        youtubeThumbnailVideoId('https://i9.ytimg.com/s_p/PLx/a.jpg'),
        isNull,
      );
      expect(youtubeThumbnailVideoId('$art=w60-h60'), isNull);
      expect(youtubeThumbnailVideoId('C:/music/cover.jpg'), isNull);
    });

    test('the smallest frame whose square covers the size, never mq', () {
      expect(youtubeFrame(48), hqFrame);
      expect(youtubeFrame(270), hqFrame);
      expect(youtubeFrame(300), sdFrame);
      expect(youtubeFrame(360), sdFrame);
      expect(youtubeFrame(361), maxresFrame);
      expect(
        youtubeFrameUrl('dQw4w9WgXcQ', sdFrame),
        'https://i.ytimg.com/vi/dQw4w9WgXcQ/sddefault.jpg',
      );
    });
  });
}
