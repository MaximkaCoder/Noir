import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/discover/application/for_you.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/test_database.dart';

Track yt(String id, {String? artist}) => Track(
  id: 'yt:$id',
  source: MediaSource.youtube,
  title: 'Song $id',
  uri: id,
  artist: artist ?? 'Artist $id',
);

List<String> uris(YtmShelf shelf) => [
  for (final i in shelf.items) (i as YtmTrackItem).track.uri,
];

void main() {
  final now = DateTime(2026, 10, 25, 12);

  group('tasteSeeds', () {
    test('repeated recent plays outweigh a single old one', () {
      final seeds = tasteSeeds(
        plays: [
          YouTubePlay(yt('a'), now.subtract(const Duration(hours: 1))),
          YouTubePlay(yt('a'), now.subtract(const Duration(days: 1))),
          YouTubePlay(yt('b'), now.subtract(const Duration(days: 40))),
        ],
        likes: const [],
        playlistTracks: const [],
        now: now,
      );
      expect([for (final s in seeds) s.track.uri], ['a', 'b']);
      expect(seeds.first.weight, greaterThan(1.5));
      expect(seeds.last.weight, lessThan(0.1));
    });

    test('recent likes count more than old ones and playlist songs', () {
      final seeds = tasteSeeds(
        plays: const [],
        likes: [yt('new'), for (var i = 0; i < 100; i++) yt('l$i')],
        playlistTracks: [yt('p')],
        now: now,
      );
      expect(seeds.first.track.uri, 'new');
      final p = seeds.firstWhere((s) => s.track.uri == 'p');
      expect(p.weight, lessThan(seeds.first.weight));
    });
  });

  group('pickSeeds', () {
    final seeds = [
      TasteSeed(yt('a1', artist: 'A'), 5),
      TasteSeed(yt('a2', artist: 'A'), 5),
      TasteSeed(yt('b', artist: 'B'), 1),
      TasteSeed(yt('c', artist: 'C'), 1),
    ];

    test('one song per artist', () {
      final picked = pickSeeds(seeds, 4, Random(1));
      expect(picked, hasLength(3));
      expect(picked.map((t) => t.artist).toSet(), {'A', 'B', 'C'});
    });

    test('the same day draws the same songs', () {
      List<String> draw(int seed) => [
        for (final t in pickSeeds(seeds, 2, Random(seed))) t.uri,
      ];
      expect(draw(7), draw(7));
    });

    test('heavier seeds are drawn more often', () {
      var a = 0;
      for (var i = 0; i < 400; i++) {
        if (pickSeeds(seeds, 1, Random(i)).single.artist == 'A') a++;
      }
      expect(a, greaterThan(250));
    });
  });

  group('composeForYou', () {
    test('mixes seeds in turns, without known songs or repeats', () {
      final shelves = composeForYou(
        [
          (seed: yt('s1'), tracks: [yt('s1'), yt('x1'), yt('x2'), yt('k')]),
          (seed: yt('s2'), tracks: [yt('y1'), yt('x1'), yt('y2')]),
        ],
        {'k'},
        becauseCount: 0,
      );
      expect(shelves.single.title, 'Mixed for you');
      expect(uris(shelves.single), ['x1', 'y1', 'x2', 'y2']);
    });

    test('"because you listen to" shelves for the first seeds', () {
      final many = [for (var i = 0; i < 8; i++) yt('r$i')];
      final shelves = composeForYou([
        (seed: yt('s1', artist: 'Mara'), tracks: many),
        (seed: yt('s2'), tracks: [yt('few')]),
      ], const {});
      expect(shelves, hasLength(2), reason: 'too few for a second shelf');
      expect(shelves[1].strapline, 'Because you listen to');
      expect(shelves[1].title, 'Song s1 · Mara');
      expect(uris(shelves[1]), [for (final t in many) t.uri]);
    });

    test('nothing to suggest gives no shelves', () {
      expect(composeForYou(const [], const {}), isEmpty);
    });
  });

  test('listen again: most played first, taking turns with local', () {
    final local = [
      const Track(
        id: 'local:1',
        source: MediaSource.local,
        title: 'L1',
        uri: 'C:/1.mp3',
      ),
    ];
    final tracks = listenAgain(
      [
        YouTubePlay(yt('once'), now.subtract(const Duration(hours: 2))),
        YouTubePlay(yt('often'), now.subtract(const Duration(hours: 3))),
        YouTubePlay(yt('often'), now.subtract(const Duration(days: 1))),
      ],
      local,
      now,
    );
    expect([for (final t in tracks) t.uri], ['often', 'C:/1.mp3', 'once']);
  });

  test('the play log keeps YouTube songs only, newest first', () async {
    final db = inMemoryDatabase();
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(db)],
    );
    addTearDown(() async {
      container.dispose();
      await db.close();
    });
    final log = container.read(youTubePlayLogProvider);
    await log.record(yt('a'));
    await log.record(
      const Track(
        id: 'local:1',
        source: MediaSource.local,
        title: 'Local',
        uri: 'C:/a.mp3',
      ),
    );
    await log.record(yt('b'));
    final plays = await log.read();
    expect([for (final p in plays) p.track.uri], ['b', 'a']);
    expect(plays.first.track.artist, 'Artist b');
    await log.clear();
    expect(await log.read(), isEmpty);
  });
}
