import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/playback/application/playback_controller.dart';

/// A transport command from outside NOIR's own UI.
enum MediaCommand { playPause, play, pause, next, previous, stop }

/// Where a [MediaCommand] came from.
enum MediaCommandSource {
  /// A media key seen by NOIR's focused window.
  keyboard,

  /// The OS media session (Windows SMTC: media keys and the media flyout).
  system,
}

final mediaCommandsProvider = Provider<MediaCommands>(MediaCommands.new);

/// Routes media commands to the playback controller, once per key press.
///
/// On Windows one press of a media key can reach NOIR twice: as a key event
/// in the focused window and as an SMTC button press. Which of the two
/// arrives (and in what order) depends on the OS, so instead of guessing,
/// a command that matches one accepted from the *other* source moments ago
/// is dropped. Repeated presses through the same source always go through.
class MediaCommands {
  MediaCommands(this._ref, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  /// How far apart the two deliveries of one press can be.
  static const duplicateWindow = Duration(milliseconds: 400);

  final Ref _ref;
  final DateTime Function() _clock;
  ({_Kind kind, MediaCommandSource source, DateTime at})? _last;

  Future<void> handle(MediaCommand command, MediaCommandSource source) async {
    final kind = _kindOf(command);
    final now = _clock();
    final last = _last;
    if (last != null &&
        last.kind == kind &&
        last.source != source &&
        now.difference(last.at) < duplicateWindow) {
      return;
    }
    _last = (kind: kind, source: source, at: now);

    final ctrl = _ref.read(playbackProvider.notifier);
    switch (command) {
      case MediaCommand.playPause:
        await ctrl.togglePlayPause();
      case MediaCommand.play:
        await ctrl.resume();
      case MediaCommand.pause:
      case MediaCommand.stop:
        await ctrl.pause();
      case MediaCommand.next:
        await ctrl.next();
      case MediaCommand.previous:
        await ctrl.previous();
    }
  }

  // SMTC turns the Play/Pause key into "play" or "pause" depending on the
  // state it was told about, so all three count as the same press.
  static _Kind _kindOf(MediaCommand command) => switch (command) {
    MediaCommand.playPause ||
    MediaCommand.play ||
    MediaCommand.pause => _Kind.playPause,
    MediaCommand.stop => _Kind.stop,
    MediaCommand.next => _Kind.next,
    MediaCommand.previous => _Kind.previous,
  };
}

enum _Kind { playPause, stop, next, previous }
