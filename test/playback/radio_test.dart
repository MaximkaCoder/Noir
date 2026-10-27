import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/discover/application/discover_providers.dart';
import 'package:noir/features/discover/application/dislikes.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/application/unplayable_tracks.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';
import 'package:noir/integrations/youtube_music/innertube_client.dart';
import 'package:noir/integrations/youtube_music/ytm_models.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/fake_engine.dart';
import '../helpers/fake_innertube_client.dart';
import '../helpers/test_database.dart';

void main() {
  late AppDatabase db;
  late FakeEngine engine;
  late FakeInnerTubeClient ytm;
  late ProviderContainer container;
  late List<Track> local;

  PlaybackController controller() => container.read(playbackProvider.notifier);
  PlaybackState state() => container.read(playbackProvider);
  List<String> uris() => [for (final q in state().queue) q.track.uri];
  List<String> radioCalls() => [
    for (final c in ytm.calls)
      if (c.startsWith('radio') || c.startsWith('search')) c,
  ];

  Future<void> complete() async {
    engine.emit(const EngineCompleted());
    await pumpEventQueue();
  }

  final y1 = ytTrack('y1');
  final y2 = ytTrack('y2');
  final r1 = ytTrack('r1');
  final r2 = ytTrack('r2');
  final r3 = ytTrack('r3');

  setUp(() async {
    db = inMemoryDatabase();
    engine = FakeEngine();
    ytm = FakeInnerTubeClient();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        innerTubeClientProvider.overrideWithValue(ytm),
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      trackRow('a.mp3', title: 'A', artist: 'Mara Vale'),
    ]);
    local = await library.watchTracks().first;
    container.listen(playbackProvider, (_, _) {});
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('radio skips songs and artists the user said no to', () async {
    ytm.radioPages['y1'] = YtmTrackPage(
      tracks: [
        y1,
        r1,
        ytTrack('b1', artist: 'Blocked'),
        r2,
        ytTrack('r4', artist: 'Kept'),
      ],
    );
    final dislikes = container.read(dislikesProvider.notifier);
    await dislikes.dislikeSong(r2);
    await dislikes.blockArtist('blocked');
    await controller().startRadio(y1);
    expect(uris(), ['y1', 'r1', 'r4']);
  });

  test('the end of a YouTube queue continues with radio, deduped', () async {
    ytm
      ..radioPages['y2'] = YtmTrackPage(
        // The radio repeats its seed and other queued songs first.
        tracks: [y2, y1, r1, r2],
        continuation: 'R1',
        playlistId: 'RDAMVMy2',
      )
      ..radioMorePages['R1'] = YtmTrackPage(tracks: [r2, r3]);
    await controller().playTracks([y1, y2], startIndex: 1);

    await complete();
    expect(uris(), ['y1', 'y2', 'r1', 'r2']);
    expect(state().current!.track.uri, 'r1');
    expect(state().status, PlaybackStatus.playing);
    expect(radioCalls(), ['radio y2']);

    await complete(); // r1 → r2, already queued: no request.
    expect(radioCalls(), hasLength(1));

    // The radio goes on where it left off rather than starting over.
    await complete();
    expect(radioCalls(), ['radio y2', 'radioMore R1']);
    expect(uris(), ['y1', 'y2', 'r1', 'r2', 'r3']);
    expect(state().current!.track.uri, 'r3');
  });

  test('radio is topped up once few tracks are left', () async {
    final list = [for (var i = 1; i <= 7; i++) ytTrack('y$i')];
    ytm.radioPages['y7'] = YtmTrackPage(tracks: [r1, r2]);
    await controller().playTracks(list, startIndex: 1);
    engine.tick(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(radioCalls(), isEmpty, reason: '5 tracks still ahead');

    await controller().next();
    engine.tick(const Duration(seconds: 1));
    await pumpEventQueue();
    expect(radioCalls(), ['radio y7']);
    expect(uris(), [...list.map((t) => t.uri), 'r1', 'r2']);
    expect(state().current!.track.uri, 'y3');

    engine.tick(const Duration(seconds: 2));
    await pumpEventQueue();
    expect(radioCalls(), hasLength(1));
  });

  test('Next on the last track goes on into radio', () async {
    ytm.radioPages['y1'] = YtmTrackPage(tracks: [r1, r2]);
    await controller().playTracks([y1]);
    await controller().next();
    expect(state().current!.track.uri, 'r1');
    expect(uris(), ['y1', 'r1', 'r2']);
  });

  test(
    'a local last track is followed by radio of the last YouTube one',
    () async {
      ytm.radioPages['y1'] = YtmTrackPage(tracks: [r1]);
      await controller().playTracks([y1, local.single], startIndex: 1);
      await complete();
      expect(radioCalls(), ['radio y1']);
      expect(uris().last, 'r1');
    },
  );

  test('autoplayRadio off keeps the old end of queue', () async {
    controller().autoplayRadio = false;
    ytm.radioPages['y1'] = YtmTrackPage(tracks: [r1]);
    await controller().playTracks([y1]);
    engine
      ..durationValue = const Duration(minutes: 3)
      ..tick(const Duration(minutes: 2, seconds: 50));

    await complete();
    expect(state().status, PlaybackStatus.completed);
    expect(uris(), ['y1']);
    expect(radioCalls(), isEmpty);
  });

  test('no radio for local-only queues or with repeat on', () async {
    await controller().playTracks(local);
    await complete();
    expect(state().status, PlaybackStatus.completed);

    await controller().playTracks([y1]);
    controller().cycleRepeat(); // all
    await complete();
    expect(state().current!.track.uri, 'y1');
    expect(radioCalls(), isEmpty);
  });

  test('a failing YouTube Music ends the queue quietly', () async {
    ytm.error = const InnerTubeException(
      InnerTubeErrorKind.network,
      "Couldn't reach YouTube Music.",
    );
    await controller().playTracks([y1]);
    await complete();
    expect(state().status, PlaybackStatus.completed);
    expect(state().message, isNull);
    expect(uris(), ['y1']);
  });

  test('startRadio plays the seed, then its radio', () async {
    ytm.radioPages['y1'] = YtmTrackPage(tracks: [y1, r1, r2]);
    await controller().startRadio(y1);
    expect(uris(), ['y1', 'r1', 'r2']);
    expect(state().current!.track.uri, 'y1');
    expect(engine.calls, containsAllInOrder(['load Song y1 @0', 'play']));
  });

  test('startRadio from a local file matches it on YouTube Music', () async {
    final match = ytTrack('m1', title: 'A', artist: 'Mara Vale');
    ytm
      ..searchPages[YtmSearchFilter.songs] = YtmSearchPage(
        items: [YtmTrackItem(match)],
      )
      ..radioPages['m1'] = YtmTrackPage(tracks: [match, r1]);
    await controller().startRadio(local.single);
    expect(radioCalls(), ['search Mara Vale A songs', 'radio m1']);
    // The match is the same song as the seed, so it is not queued again.
    expect(uris(), [local.single.uri, 'r1']);
  });

  test("a video YouTube won't play here is remembered and skipped", () async {
    await controller().playTracks([y1, y2, r1]);
    engine.emit(EngineFailed('Owner says no', unplayable: y1));
    await pumpEventQueue();

    expect(state().current!.track.uri, 'y2');
    final unplayable = container.read(unplayableTracksProvider);
    expect(unplayable.reasonFor(y1), 'Owner says no');
    expect(unplayable.reasonFor(y2), isNull);
  });

  test('next passes over videos known not to play', () async {
    container.read(unplayableTracksProvider.notifier).add(y2, 'Owner says no');
    await controller().playTracks([y1, y2, r1]);

    await controller().next();
    expect(state().current!.track.uri, 'r1');
  });

  test("a failure that is not the video's own stops on it", () async {
    await controller().playTracks([y1, y2]);
    engine.emit(const EngineFailed('Offline'));
    await pumpEventQueue();

    expect(state().current!.track.uri, 'y1');
    expect(state().status, PlaybackStatus.error);
  });
}
