import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/app/router.dart';
import 'package:noir/app/shell/navigation_history.dart';
import 'package:noir/app/theme/app_theme.dart';
import 'package:noir/app/theme/glass_theme.dart';
import 'package:noir/features/playback/application/media_commands.dart';
import 'package:noir/features/playback/presentation/youtube_video_layer.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';

class NoirApp extends ConsumerWidget {
  const NoirApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Only what the theme and the effects depend on: any other setting
    // (a transition mode, the volume) changing must not rebuild the app.
    ref.watch(
      settingsProvider.select(
        (s) => (
          s.themeMode,
          s.density,
          s.liquidGlass,
          s.glassLevel,
          s.animations,
          s.performanceMode,
        ),
      ),
    );
    final settings = ref.read(settingsProvider);
    return MaterialApp.router(
      title: 'NOIR',
      debugShowCheckedModeBanner: false,
      themeMode: settings.themeMode,
      theme: buildNoirTheme(Brightness.light, settings.density),
      darkTheme: buildNoirTheme(Brightness.dark, settings.density),
      routerConfig: ref.watch(routerProvider),
      // Effects depend on both the user's settings and the system
      // reduced-motion flag, so they are resolved below MediaQuery.
      builder: (context, child) => NoirEffects(
        config: EffectsConfig.resolve(
          settings,
          systemReducedMotion: MediaQuery.disableAnimationsOf(context),
        ),
        child: _GlobalInput(
          // The YouTube video sits above every route so it can move between
          // Now Playing and its floating mini position without reloading.
          child: Stack(
            fit: StackFit.expand,
            children: [
              child!,
              Overlay(
                initialEntries: [
                  OverlayEntry(
                    builder: (_) => const Material(
                      type: MaterialType.transparency,
                      child: YouTubeVideoLayer(),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-wide input that belongs to no single screen:
/// - the mouse Back / Forward side buttons and Alt+← / Alt+→ walk the
///   [NavigationHistory] like a browser, across sections too; Back closes
///   an open dialog, sheet or menu first, then Now Playing;
/// - media keys reach the player while the window is focused. On Windows
///   SMTC may deliver the same press too; [MediaCommands] drops the
///   duplicate.
class _GlobalInput extends ConsumerStatefulWidget {
  const _GlobalInput({required this.child});

  final Widget child;

  @override
  ConsumerState<_GlobalInput> createState() => _GlobalInputState();
}

class _GlobalInputState extends ConsumerState<_GlobalInput> {
  static final _mediaKeys = {
    LogicalKeyboardKey.mediaPlayPause: MediaCommand.playPause,
    LogicalKeyboardKey.mediaPlay: MediaCommand.play,
    LogicalKeyboardKey.mediaPause: MediaCommand.pause,
    LogicalKeyboardKey.mediaTrackNext: MediaCommand.next,
    LogicalKeyboardKey.mediaTrackPrevious: MediaCommand.previous,
    LogicalKeyboardKey.mediaStop: MediaCommand.stop,
  };

  // Flutter's Windows key map has no logical keys for Next/Previous track
  // (VK_MEDIA_NEXT_TRACK arrives as a Windows-plane key), so match the
  // physical keys too.
  static final _mediaPhysicalKeys = {
    PhysicalKeyboardKey.mediaPlayPause: MediaCommand.playPause,
    PhysicalKeyboardKey.mediaTrackNext: MediaCommand.next,
    PhysicalKeyboardKey.mediaTrackPrevious: MediaCommand.previous,
    PhysicalKeyboardKey.mediaStop: MediaCommand.stop,
  };

  @override
  void initState() {
    super.initState();
    // Starts recording before the first navigation.
    ref.read(navigationHistoryProvider);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  // Mobile and macOS get media keys through their media session instead.
  bool get _handlesMediaKeys =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux;

  void _back() => unawaited(ref.read(navigationHistoryProvider).back());

  void _forward() => ref.read(navigationHistoryProvider).forward();

  bool _onKey(KeyEvent event) {
    final command =
        _mediaKeys[event.logicalKey] ?? _mediaPhysicalKeys[event.physicalKey];
    if (command != null) {
      if (!_handlesMediaKeys) return false;
      if (event is KeyDownEvent) {
        unawaited(
          ref
              .read(mediaCommandsProvider)
              .handle(command, MediaCommandSource.keyboard),
        );
      }
      return true;
    }

    final keys = HardwareKeyboard.instance;
    final arrow = event.logicalKey;
    if (event is KeyDownEvent &&
        (arrow == LogicalKeyboardKey.arrowLeft ||
            arrow == LogicalKeyboardKey.arrowRight) &&
        keys.isAltPressed &&
        !keys.isControlPressed &&
        !keys.isShiftPressed &&
        !keys.isMetaPressed &&
        !_editingText) {
      arrow == LogicalKeyboardKey.arrowLeft ? _back() : _forward();
      return true;
    }
    return false;
  }

  /// Text fields keep Alt+← / Alt+→ for themselves.
  bool get _editingText =>
      FocusManager.instance.primaryFocus?.context
          ?.findAncestorStateOfType<EditableTextState>() !=
      null;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse) return;
        if (event.buttons & kBackMouseButton != 0) {
          _back();
        } else if (event.buttons & kForwardMouseButton != 0) {
          _forward();
        }
      },
      child: widget.child,
    );
  }
}
