import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:noir/features/playback/domain/playback_engine.dart';

/// The official YouTube player (IFrame Player API) running in a web view,
/// as the video layer needs it on any platform.
abstract interface class EmbeddedYouTubePlayer implements PlaybackEngine {
  /// True once the web view and the IFrame API are ready.
  ValueListenable<bool> get ready;

  /// The web view showing the player, once [ready].
  Widget buildView(BuildContext context);
}
