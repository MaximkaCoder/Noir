import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/playback/application/playback_controller.dart';

/// Space plays or pauses, Ctrl+→ and Ctrl+← skip, anywhere under [child].
///
/// They take precedence over a focused button (Space would otherwise press
/// the button that was clicked last) but not over a text field: while one
/// has focus the keys go on to it.
class PlaybackShortcuts extends ConsumerWidget {
  const PlaybackShortcuts({required this.child, super.key});

  final Widget child;

  static const _bindings = <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.space): _PlaybackIntent(_Key.toggle),
    SingleActivator(LogicalKeyboardKey.arrowRight, control: true):
        _PlaybackIntent(_Key.next),
    SingleActivator(LogicalKeyboardKey.arrowLeft, control: true):
        _PlaybackIntent(_Key.previous),
  };

  @override
  Widget build(BuildContext context, WidgetRef ref) => Shortcuts(
    shortcuts: _bindings,
    child: Actions(
      actions: {_PlaybackIntent: _PlaybackAction(ref)},
      child: child,
    ),
  );
}

enum _Key { toggle, next, previous }

class _PlaybackIntent extends Intent {
  const _PlaybackIntent(this.key);

  final _Key key;
}

class _PlaybackAction extends Action<_PlaybackIntent> {
  _PlaybackAction(this.ref);

  final WidgetRef ref;

  /// Off while typing, so the key reaches the text field.
  @override
  bool isEnabled(_PlaybackIntent intent) =>
      primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>() ==
      null;

  @override
  void invoke(_PlaybackIntent intent) {
    final playback = ref.read(playbackProvider.notifier);
    unawaited(switch (intent.key) {
      _Key.toggle => playback.togglePlayPause(),
      _Key.next => playback.next(),
      _Key.previous => playback.previous(),
    });
  }
}
