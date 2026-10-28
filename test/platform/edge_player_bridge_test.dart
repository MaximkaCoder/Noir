import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/core/database/app_database.dart';
import 'package:noir/core/database/database_provider.dart';
import 'package:noir/features/edge_player/edge_player_bridge.dart';
import 'package:noir/features/edge_player/edge_snapshot.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/shared/models/media.dart';

import '../helpers/fake_engine.dart';
import '../helpers/test_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late AppDatabase db;
  late FakeEngine engine;
  late ProviderContainer container;
  late List<Track> tracks;
  late DateTime now;
  late List<EdgeSnapshot> sent;
  late EdgePlayerBridge bridge;

  PlaybackController controller() => container.read(playbackProvider.notifier);

  Future<void> command(String name, [num? value]) async {
    await messenger.handlePlatformMessage(
      edgeChannel.name,
      edgeChannel.codec.encodeMethodCall(
        MethodCall('command', {'name': name, 'value': value}),
      ),
      (_) {},
    );
    await pumpEventQueue();
  }

  setUp(() async {
    now = DateTime(2026);
    sent = [];
    messenger.setMockMethodCallHandler(edgeChannel, (call) async {
      if (call.method == 'update') {
        sent.add(EdgeSnapshot.fromMap(call.arguments as Map));
      }
      return null;
    });
    db = inMemoryDatabase();
    engine = FakeEngine();
    container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        playbackEngineProvider.overrideWithValue(engine),
        initialSettingsProvider.overrideWithValue(const AppSettings()),
      ],
    );
    final library = LibraryRepository(db);
    await library.upsertScanned([
      for (final name in ['A', 'B'])
        trackRow('$name.mp3', title: name, artist: 'Artist $name'),
    ]);
    tracks = await library.watchTracks().first;
    // Another window is active.
    bridge = EdgePlayerBridge(container, clock: () => now)
      ..start()
      ..onWindowBlur();
    await pumpEventQueue();
  });

  tearDown(() async {
    bridge.dispose();
    messenger.setMockMethodCallHandler(edgeChannel, null);
    container.dispose();
    await db.close();
  });

  test('stays hidden until something is loaded, then shows it', () async {
    expect(sent.single.side, 'right');
    expect(sent.single.visible, isFalse);

    await controller().playTracks(tracks);
    await pumpEventQueue();
    final s = sent.last;
    expect(s.visible, isTrue);
    expect(s.title, 'A');
    expect(s.artist, 'Artist A');
    expect(s.playing, isTrue);
    expect(s.canNext, isTrue);
    expect(s.canLike, isTrue);
  });

  test('shows only while NOIR is in the background', () async {
    await controller().playTracks(tracks);
    await pumpEventQueue();
    expect(sent.last.visible, isTrue);

    bridge.onWindowFocus();
    await pumpEventQueue();
    expect(sent.last.visible, isFalse);
    expect(sent.last.side, 'right');

    bridge.onWindowMinimize();
    await pumpEventQueue();
    expect(sent.last.visible, isTrue);

    bridge
      ..onWindowFocus()
      ..onWindowBlur();
    await pumpEventQueue();
    expect(sent.last.visible, isTrue);
  });

  test('remembers where it was dropped', () async {
    await controller().playTracks(tracks);
    await pumpEventQueue();
    await messenger.handlePlatformMessage(
      edgeChannel.name,
      edgeChannel.codec.encodeMethodCall(
        const MethodCall('moved', {
          'side': 'left',
          'anchorX': 2600,
          'anchorY': 400,
        }),
      ),
      (_) {},
    );
    await pumpEventQueue();
    final settings = container.read(settingsProvider);
    expect(settings.edgePlayer, EdgePlayerSide.left);
    expect((settings.edgePlayerX, settings.edgePlayerY), (2600, 400));
    expect(sent.last.side, 'left');
    expect((sent.last.anchorX, sent.last.anchorY), (2600, 400));
  });

  test('follows the settings: side, screen capture, off', () async {
    await controller().playTracks(tracks);
    await pumpEventQueue();
    expect(sent.last.capturable, isFalse);
    container
        .read(settingsProvider.notifier)
        .update(
          (s) => s.copyWith(
            edgePlayer: EdgePlayerSide.top,
            edgePlayerCapturable: true,
          ),
        );
    await pumpEventQueue();
    expect(sent.last.side, 'top');
    expect(sent.last.capturable, isTrue);

    container
        .read(settingsProvider.notifier)
        .update((s) => s.copyWith(edgePlayerEnabled: false));
    await pumpEventQueue();
    expect(sent.last.side, 'off');
    expect(sent.last.visible, isFalse);
  });

  test('sends the position only when it jumps', () async {
    await controller().playTracks(tracks);
    await pumpEventQueue();
    final count = sent.length;

    now = now.add(const Duration(seconds: 5));
    engine.tick(const Duration(seconds: 5));
    expect(sent, hasLength(count));

    engine.tick(const Duration(seconds: 40));
    expect(sent, hasLength(count + 1));
    expect(sent.last.position, const Duration(seconds: 40));
    expect(sent.last.at, now);
  });

  test('carries out what the edge player asks for', () async {
    await controller().playTracks(tracks);
    await pumpEventQueue();

    await command('playPause');
    expect(container.read(playbackProvider).isPlaying, isFalse);
    await command('next');
    expect(container.read(playbackProvider).current!.track.title, 'B');
    await command('seek', 12000);
    expect(engine.calls, contains('seek 12'));
    await command('volume', 0.25);
    expect(container.read(playbackProvider).volume, 0.25);

    await command('like');
    expect(container.read(playbackProvider).current!.track.isFavorite, isTrue);
    await pumpEventQueue();
    expect(sent.last.liked, isTrue);
    // Lets the remembered volume be saved.
    await Future<void>.delayed(const Duration(milliseconds: 600));
  });
}
