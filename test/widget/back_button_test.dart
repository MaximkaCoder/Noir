import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:noir/app/router.dart';
import 'package:noir/features/library/data/library_repository.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/playback/presentation/now_playing_screen.dart';
import 'package:noir/shared/models/media.dart';
import 'package:noir/shared/models/playback.dart';

import '../helpers/pump_app.dart';

void main() {
  Future<List<Track>> tracksOf(TestApp app) async => [
    for (final r in await app.db.select(app.db.tracks).get()) r.toTrack(),
  ];
  GoRouter router(TestApp app) => app.container.read(routerProvider);
  String location(TestApp app) =>
      router(app).routerDelegate.currentConfiguration.uri.toString();

  Future<void> mouseBack(
    WidgetTester tester, {
    int button = kBackMouseButton,
  }) async {
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
      buttons: button,
    );
    await gesture.down(const Offset(700, 400));
    await gesture.up();
    await gesture.removePointer();
    await tester.pumpAndSettle();
  }

  Future<void> altLeft(WidgetTester tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.pumpAndSettle();
  }

  Future<void> openDialog(WidgetTester tester, TestApp app) async {
    final context = router(app).routerDelegate.navigatorKey.currentContext!;
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('A dialog')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A dialog'), findsOneWidget);
  }

  /// Presses a media key the way the Windows embedder reports it: the
  /// physical key is known, but Next/Previous have no logical key in
  /// Flutter's Windows map and arrive as Windows-plane keys.
  Future<void> windowsMediaKey(
    WidgetTester tester,
    PhysicalKeyboardKey physical,
    int virtualKey,
  ) async {
    final logical = LogicalKeyboardKey(
      LogicalKeyboardKey.windowsPlane | virtualKey,
    );
    HardwareKeyboard.instance
      ..handleKeyEvent(
        KeyDownEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
      )
      ..handleKeyEvent(
        KeyUpEvent(
          physicalKey: physical,
          logicalKey: logical,
          timeStamp: Duration.zero,
        ),
      );
    await tester.pumpAndSettle();
  }

  group('mouse back button', () {
    testWidgets('pops a section sub-page back to its root', (tester) async {
      final app = await TestApp.pump(tester);
      router(app).go('/library/favorites');
      await tester.pumpAndSettle();
      expect(location(app), '/library/favorites');

      await mouseBack(tester);
      expect(location(app), '/library');
    });

    testWidgets('closes a dialog first, then Now Playing', (tester) async {
      final app = await TestApp.pump(tester);
      final tracks = await tracksOf(app);
      await app.container.read(playbackProvider.notifier).playTracks(tracks);
      router(app).go('/library/favorites');
      await tester.pumpAndSettle();
      unawaited(router(app).push('/now-playing'));
      await tester.pumpAndSettle();
      expect(find.byType(NowPlayingScreen), findsOneWidget);
      await openDialog(tester, app);

      await mouseBack(tester);
      expect(find.text('A dialog'), findsNothing);
      expect(find.byType(NowPlayingScreen), findsOneWidget);

      await mouseBack(tester);
      expect(find.byType(NowPlayingScreen), findsNothing);
      expect(location(app), '/library/favorites');

      await mouseBack(tester);
      expect(location(app), '/library');
    });

    testWidgets('does nothing at a section root', (tester) async {
      final app = await TestApp.pump(tester);
      router(app).go('/library');
      await tester.pumpAndSettle();

      await mouseBack(tester);
      expect(location(app), '/library');
      expect(tester.takeException(), isNull);
    });

    testWidgets('the forward button does nothing', (tester) async {
      final app = await TestApp.pump(tester);
      router(app).go('/library/favorites');
      await tester.pumpAndSettle();

      await mouseBack(tester, button: kForwardMouseButton);
      expect(location(app), '/library/favorites');
    });
  });

  group('Alt+Left', () {
    testWidgets('goes back like the mouse button', (tester) async {
      final app = await TestApp.pump(tester);
      router(app).go('/library/favorites');
      await tester.pumpAndSettle();
      await openDialog(tester, app);

      await altLeft(tester);
      expect(find.text('A dialog'), findsNothing);
      expect(location(app), '/library/favorites');

      await altLeft(tester);
      expect(location(app), '/library');
    });
  });

  group('media keys in the focused window', () {
    testWidgets('control playback on desktop', (tester) async {
      final app = await TestApp.pump(tester);
      final tracks = await tracksOf(app);
      final ctrl = app.container.read(playbackProvider.notifier);
      await ctrl.playTracks(tracks);
      await tester.pumpAndSettle();
      PlaybackState state() => app.container.read(playbackProvider);
      final first = state().current!.track.title;

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(state().status, PlaybackStatus.paused);

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(state().status, PlaybackStatus.playing);

      // VK_MEDIA_NEXT_TRACK / VK_MEDIA_PREV_TRACK.
      await windowsMediaKey(tester, PhysicalKeyboardKey.mediaTrackNext, 0xB0);
      expect(state().current!.track.title, isNot(first));

      await windowsMediaKey(
        tester,
        PhysicalKeyboardKey.mediaTrackPrevious,
        0xB1,
      );
      expect(state().current!.track.title, first);

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaStop);
      await tester.pumpAndSettle();
      expect(state().status, PlaybackStatus.paused);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

    testWidgets('are left to the media session on mobile', (tester) async {
      final app = await TestApp.pump(tester);
      final tracks = await tracksOf(app);
      await app.container.read(playbackProvider.notifier).playTracks(tracks);
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.mediaPlayPause);
      await tester.pumpAndSettle();
      expect(
        app.container.read(playbackProvider).status,
        PlaybackStatus.playing,
      );
    });
  });
}
