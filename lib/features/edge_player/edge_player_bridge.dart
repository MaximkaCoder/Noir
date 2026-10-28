import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/accounts/domain/account_connection.dart';
import 'package:noir/features/artwork/application/artwork_providers.dart';
import 'package:noir/features/edge_player/edge_snapshot.dart';
import 'package:noir/features/playback/application/playback_controller.dart';
import 'package:noir/features/settings/domain/app_settings.dart';
import 'package:noir/features/settings/presentation/settings_controller.dart';
import 'package:noir/features/youtube/application/youtube_save.dart';
import 'package:noir/shared/models/media.dart';
import 'package:window_manager/window_manager.dart';

/// Implemented by the Windows runner (windows/runner/edge_player.cpp).
const edgeChannel = MethodChannel('noir/edge');

/// The edge player's state, apart from the position and duration (those
/// move on their own and are added when sent).
final edgeSnapshotProvider = Provider<EdgeSnapshot>((ref) {
  final side = ref.watch(settingsProvider.select((s) => s.edgePlayer));
  final state = ref.watch(playbackProvider);
  final track = state.current?.track;
  if (side == EdgePlayerSide.off || track == null) {
    return EdgeSnapshot(side: side.name);
  }

  var canLike = false;
  var liked = false;
  String? art;
  if (track.source == MediaSource.youtube) {
    // The heart saves to the chosen YouTube playlist, as in the app.
    final account =
        ref.watch(accountConnectionProvider).value ??
        ref.watch(accountServiceProvider).current;
    if (account.isConnected) {
      canLike = true;
      liked = ref.watch(youTubeSavedProvider(track.uri));
    }
    art = ref.watch(resolvedArtProvider(track.uri))?.squareUrl(544);
  } else if (track.localId != null) {
    canLike = true;
    liked = track.isFavorite;
  }

  return EdgeSnapshot(
    side: side.name,
    visible: true,
    title: track.title,
    artist: track.artist ?? '',
    artwork: art ?? track.artwork ?? '',
    playing: state.isPlaying,
    canPrevious: state.capabilities.canSkip,
    canNext: state.capabilities.canSkip && state.hasNext,
    volume: state.volume,
    canLike: canLike,
    liked: liked,
  );
});

/// Keeps the Windows edge player in step with playback and carries out what
/// it asks for. Never throws: without the runner's side, nothing happens.
void startEdgePlayer(ProviderContainer container) {
  try {
    EdgePlayerBridge(container).start();
  } on Object catch (e) {
    debugPrint('Edge player unavailable: $e');
  }
}

class EdgePlayerBridge {
  EdgePlayerBridge(
    this._container, {
    this._channel = edgeChannel,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// A position further than this from where the edge player thinks it is
  /// means a seek, and is sent.
  static const seekTolerance = Duration(seconds: 1);

  final ProviderContainer _container;
  final MethodChannel _channel;
  final DateTime Function() _clock;

  ProviderSubscription<EdgeSnapshot>? _snapshotSub;
  final _subscriptions = <StreamSubscription<Object?>>[];
  bool _failed = false;

  Map<String, Object?>? _sent;
  EdgeSnapshot? _sentSnapshot;

  void start() {
    _channel.setMethodCallHandler(_onNativeCall);
    final engine = _container.read(playbackEngineProvider);
    _subscriptions
      ..add(engine.position.listen((_) => _checkPosition()))
      ..add(engine.duration.listen((_) => _send()));
    _snapshotSub = _container.listen<EdgeSnapshot>(
      edgeSnapshotProvider,
      (_, _) => _send(),
      fireImmediately: true,
    );
  }

  void dispose() {
    _snapshotSub?.close();
    for (final sub in _subscriptions) {
      unawaited(sub.cancel());
    }
    _channel.setMethodCallHandler(null);
  }

  /// Sends the state when anything but the moving position changed, or
  /// when [force]d.
  void _send({bool force = false}) {
    final base = _container.read(edgeSnapshotProvider);
    final map = base.toMap();
    if (base.visible) {
      final engine = _container.read(playbackEngineProvider);
      final duration = engine.currentDuration ?? Duration.zero;
      map['durationMs'] = duration.inMilliseconds;
      if (!force &&
          _sent != null &&
          mapEquals(_withoutTime(_sent!), _withoutTime(map))) {
        return;
      }
      map
        ..['positionMs'] = engine.currentPosition.inMilliseconds
        ..['atMs'] = _clock().millisecondsSinceEpoch;
    } else if (mapEquals(_sent, map)) {
      return;
    }
    _sent = map;
    _sentSnapshot = EdgeSnapshot.fromMap(map);
    unawaited(_invoke(map));
  }

  static Map<String, Object?> _withoutTime(Map<String, Object?> map) => {...map}
    ..remove('positionMs')
    ..remove('atMs');

  void _checkPosition() {
    final sent = _sentSnapshot;
    if (sent == null || !sent.visible) return;
    final engine = _container.read(playbackEngineProvider);
    final expected = sent.positionAt(_clock());
    if ((engine.currentPosition - expected).abs() > seekTolerance) {
      _send(force: true);
    }
  }

  Future<void> _invoke(Map<String, Object?> map) async {
    if (_failed) return;
    try {
      await _channel.invokeMethod<void>('update', map);
    } on Object catch (e) {
      _failed = true;
      debugPrint('Edge player unavailable: $e');
    }
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'command') return;
    final args = call.arguments;
    if (args is! Map) return;
    final command = EdgeCommand.values.asNameMap()[args['name']];
    final value = args['value'];
    final ctrl = _container.read(playbackProvider.notifier);
    switch (command) {
      case EdgeCommand.playPause:
        await ctrl.togglePlayPause();
      case EdgeCommand.previous:
        await ctrl.previous();
      case EdgeCommand.next:
        await ctrl.next();
      case EdgeCommand.seek:
        if (value is num) {
          await ctrl.seek(Duration(milliseconds: value.round()));
        }
      case EdgeCommand.volume:
        if (value is num) await ctrl.setVolume(value.toDouble());
      case EdgeCommand.like:
        await _like();
      case EdgeCommand.open:
        await _openApp();
      case null:
        break;
    }
  }

  Future<void> _like() async {
    final track = _container.read(playbackProvider).current?.track;
    if (track == null) return;
    if (track.source != MediaSource.youtube) {
      await _container.read(playbackProvider.notifier).toggleFavorite(track);
      return;
    }
    final outcome = await _container
        .read(youTubeSaveProvider.notifier)
        .toggle(track);
    // Choosing a playlist or allowing access happens in the app.
    if (outcome.result == SaveResult.needsTarget ||
        outcome.result == SaveResult.needsPermission) {
      await _openApp();
    }
  }

  Future<void> _openApp() async {
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      await windowManager.show();
      await windowManager.focus();
    } on Object catch (e) {
      debugPrint('NOIR window could not be shown: $e');
    }
  }
}
