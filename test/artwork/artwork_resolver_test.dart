import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:noir/features/artwork/application/artwork_resolver.dart';
import 'package:noir/features/artwork/data/artwork_cache_store.dart';
import 'package:noir/features/artwork/domain/resolved_art.dart';

import 'artwork_fakes.dart';

Future<void> wait([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  late FakeLookup lookup;
  final resolvers = <ArtworkResolver>[];

  ArtworkResolver resolver({
    ArtworkCacheStore? store,
    DateTime Function()? clock,
    int maxEntries = 10000,
  }) {
    final r = ArtworkResolver(
      lookup: lookup,
      store: store,
      clock: clock,
      batchWindow: const Duration(milliseconds: 20),
      searchSpacing: const Duration(milliseconds: 5),
      saveDelay: const Duration(milliseconds: 20),
      retryDelay: const Duration(milliseconds: 40),
      maxEntries: maxEntries,
    );
    resolvers.add(r);
    return r;
  }

  setUp(() => lookup = FakeLookup());
  tearDown(() async {
    for (final r in resolvers) {
      await r.dispose();
    }
    resolvers.clear();
  });

  group('batching', () {
    test('requests within the window become one deduplicated batch', () async {
      lookup.known.addAll({'a': atv('a'), 'b': atv('b'), 'c': atv('c')});
      final r = resolver();
      final seen = <String, ResolvedArt>{};
      for (final id in ['a', 'b', 'a', 'c', 'b']) {
        r.listen(id, (art) => seen[id] = art);
      }

      await wait();

      expect(lookup.queueCalls, [
        ['a', 'b', 'c'],
      ]);
      expect(seen.keys, unorderedEquals(['a', 'b', 'c']));
      expect(seen['a']!.squareBase, art('a'));
      expect(r.url('a', 100), '${art('a')}=w120-h120-l90-rj');
      expect(r.url('a', 900), '${art('a')}=w1200-h1200-l90-rj');
    });

    test('carries byline links and the video type', () async {
      lookup.known['a'] = atv('a');
      final r = resolver()..request('a');
      await wait();

      final resolved = r.peek('a')!;
      expect(resolved.videoType, 'MUSIC_VIDEO_TYPE_ATV');
      expect(resolved.links?.artists.single.browseId, 'UCartist');
      expect(resolved.links?.album?.browseId, 'MPREb_a');
    });

    test('known answers are not asked for again', () async {
      lookup.known['a'] = atv('a');
      final r = resolver()..request('a');
      await wait();
      r
        ..request('a')
        ..listen('a', (_) {});
      await wait();

      expect(lookup.queueCalls, hasLength(1));
    });

    test('one batch in flight; later requests wait for it', () async {
      lookup
        ..known.addAll({'a': atv('a'), 'b': atv('b')})
        ..gate = Completer<void>();
      final r = resolver()..request('a');
      await wait(60);
      r.request('b');
      await wait(80);

      expect(lookup.queueCalls, [
        ['a'],
      ]);

      lookup.gate!.complete();
      await wait();

      expect(lookup.queueCalls, [
        ['a'],
        ['b'],
      ]);
      expect(r.peek('b')?.squareBase, art('b'));
    });

    test('unknown videos are answered "video thumbnail"', () async {
      final r = resolver()..request('gone');
      await wait();

      expect(r.peek('gone')?.isVideoThumb, isTrue);
      expect(r.url('gone', 100), 'https://i.ytimg.com/vi/gone/hqdefault.jpg');
      expect(
        r.url('gone', 600),
        'https://i.ytimg.com/vi/gone/maxresdefault.jpg',
      );
    });

    test('failures back off, then retry without caching', () async {
      lookup
        ..known['a'] = atv('a')
        ..queueFailures = 1;
      final r = resolver()..request('a');
      await wait(30);

      expect(lookup.queueCalls, hasLength(1));
      expect(r.peek('a'), isNull);

      await wait(150);

      expect(lookup.queueCalls, hasLength(2));
      expect(r.peek('a')?.squareBase, art('a'));
    });

    test('gives up on a video after three failed tries', () async {
      lookup.queueFailures = 100;
      final r = resolver()..request('a');
      await wait(600);

      expect(lookup.queueCalls, hasLength(3));
      expect(r.peek('a'), isNull);
    });

    test('the offline resolver never looks anything up', () async {
      final r = ArtworkResolver.offline()..listen('a', (_) {});
      await wait(30);

      expect(lookup.queueCalls, isEmpty);
      expect(r.url('a', 48), 'https://i.ytimg.com/vi/a/hqdefault.jpg');
    });
  });

  group('counterparts', () {
    test('a music video gets the art of its song', () async {
      lookup
        ..known['v'] = omv('v')
        ..songsFor['Hit Artist'] = [songResult('Hit')];
      final r = resolver()..request('v');
      await wait();

      expect(lookup.searchCalls, ['Hit Artist']);
      expect(r.peek('v')?.squareBase, art('song1'));
      expect(r.peek('v')?.videoType, 'MUSIC_VIDEO_TYPE_OMV');
    });

    test('a doubtful match is rejected and cached as such', () async {
      lookup
        ..known['v'] = omv('v')
        ..songsFor['Hit Artist'] = [songResult('Another Song')];
      final r = resolver()..request('v');
      await wait();

      expect(r.peek('v')?.isVideoThumb, isTrue);
      expect(r.peek('v')?.links?.artists.single.name, 'Artist');
      r.request('v');
      await wait();
      expect(lookup.searchCalls, hasLength(1));
    });

    test('at most two searches at a time', () async {
      lookup.searchDelay = const Duration(milliseconds: 40);
      for (var i = 0; i < 6; i++) {
        lookup.known['v$i'] = omv('v$i', title: 'Hit $i');
      }
      final r = resolver();
      for (var i = 0; i < 6; i++) {
        r.request('v$i');
      }
      await wait(500);

      expect(lookup.queueCalls, hasLength(1));
      expect(lookup.searchCalls, hasLength(6));
      expect(lookup.maxActiveSearches, 2);
      for (var i = 0; i < 6; i++) {
        expect(r.peek('v$i')?.isVideoThumb, isTrue);
      }
    });
  });

  group('persistence', () {
    test('answers survive a restart (JSON file round trip)', () async {
      final dir = Directory.systemTemp.createTempSync('noir_art_');
      addTearDown(() => _deleteQuietly(dir));
      final file = File('${dir.path}/youtube_artwork.json');
      ArtworkCacheStore store() => JsonFileArtworkCacheStore(() async => file);

      lookup.known.addAll({'a': atv('a'), 'v': omv('v')});
      final first = resolver(store: store())
        ..request('a')
        ..request('v')
        ..request('gone');
      await wait(200);
      await first.dispose();
      expect(file.existsSync(), isTrue);

      final calls = lookup.queueCalls.length;
      final second = resolver(store: store());
      final seen = <ResolvedArt>[];
      second.listen('a', seen.add);
      await wait();

      expect(lookup.queueCalls, hasLength(calls));
      expect(seen.single.squareBase, art('a'));
      expect(seen.single.links?.album?.name, 'Album a');
      expect(second.peek('v')?.isVideoThumb, isTrue);
      expect(second.peek('gone')?.isVideoThumb, isTrue);

      // Saving again replaces the file.
      lookup.known['b'] = atv('b');
      second.request('b');
      // Slow CI machines may need more than one batch window.
      for (var i = 0; i < 50 && second.peek('b') == null; i++) {
        await wait(50);
      }
      await second.dispose();
      final third = await store().load();
      expect(third.keys, containsAll(['a', 'v', 'gone', 'b']));
    });

    test('a broken file is ignored', () async {
      final dir = Directory.systemTemp.createTempSync('noir_art_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final file = File('${dir.path}/youtube_artwork.json')
        ..writeAsStringSync('{not json');
      expect(await JsonFileArtworkCacheStore(() async => file).load(), isEmpty);
    });

    test('"no square art" expires after 14 days; found art does not', () async {
      final now = DateTime(2026, 10, 24);
      final store = MemoryStore({
        'old': ResolvedArt.none(
          checkedAt: now.subtract(const Duration(days: 15)),
        ),
        'recent': ResolvedArt.none(
          checkedAt: now.subtract(const Duration(days: 13)),
        ),
        'found': ResolvedArt(
          squareBase: art('found'),
          checkedAt: now.subtract(const Duration(days: 400)),
        ),
      });
      lookup.known['old'] = atv('old');
      final r = resolver(store: store, clock: () => now);
      await wait(10);
      ['old', 'recent', 'found'].forEach(r.request);
      await wait();

      expect(lookup.queueCalls, [
        ['old'],
      ]);
      expect(r.peek('old')?.squareBase, art('old'));
      expect(r.peek('found')?.squareBase, art('found'));
    });

    test('keeps at most maxEntries, dropping the oldest', () async {
      for (final id in ['a', 'b', 'c']) {
        lookup.known[id] = atv(id);
      }
      final store = MemoryStore();
      final r = resolver(store: store, maxEntries: 2)..request('a');
      await wait();
      r
        ..request('b')
        ..request('c');
      await wait();
      await r.dispose();

      expect(r.peek('a'), isNull);
      expect(store.saved.keys, ['b', 'c']);
    });

    test('saves are debounced', () async {
      for (final id in ['a', 'b', 'c']) {
        lookup.known[id] = atv(id);
      }
      final store = MemoryStore();
      final r = resolver(store: store)
        ..request('a')
        ..request('b')
        ..request('c');
      await wait();

      expect(store.saves, 1);
      expect(store.saved.keys, ['a', 'b', 'c']);
      await r.dispose();
      expect(store.saves, 1);
    });
  });
}

/// Windows runners can hold a just-written file open for a moment
/// (indexing, antivirus); a leftover temp folder is harmless.
void _deleteQuietly(Directory dir) {
  try {
    dir.deleteSync(recursive: true);
  } on FileSystemException {
    // Ignored.
  }
}
