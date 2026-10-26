import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:noir/features/analysis/application/analysis_providers.dart';
import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/shared/models/media.dart';

enum TransitionPhase {
  /// Planned; waiting for the outgoing track to reach the start point.
  planned,

  /// Both tracks are audible.
  mixing,
}

/// What the smart transition between the current and the next track is
/// doing, for a "Mixing…" indicator.
@immutable
class TransitionStatus {
  const TransitionStatus({
    required this.plan,
    required this.phase,
    this.progress = 0,
  });

  final TransitionPlan plan;
  final TransitionPhase phase;

  /// 0–1 through the blend (0 while planned).
  final double progress;

  TransitionType get type => plan.type;

  bool get isMixing => phase == TransitionPhase.mixing;
}

/// The smart transition in flight, or null. Written by the playback
/// controller.
final transitionStatusProvider =
    NotifierProvider<TransitionStatusNotifier, TransitionStatus?>(
      TransitionStatusNotifier.new,
    );

class TransitionStatusNotifier extends Notifier<TransitionStatus?> {
  @override
  TransitionStatus? build() => null;

  // A method reads better than a setter at call sites.
  // ignore: use_setters_to_change_properties
  void set(TransitionStatus? status) => state = status;
}

/// Loads what the transition planner knows about a track without the
/// network: its stored analysis and tags. Never throws; missing pieces are
/// null.
final transitionSideLoaderProvider =
    Provider<Future<TransitionSide> Function(Track track)>((ref) {
      return (track) async => TransitionSide(
        analysis: await _orNull(
          ref.read(trackAnalysisProvider(track.id).future),
        ),
        duration: track.duration == null
            ? null
            : track.duration!.inMicroseconds / 1e6,
        album: track.album,
        artist: track.artist,
        trackNumber: track.trackNumber,
      );
    });

/// When a track's vocals start and end, from time-synced lyrics (null when
/// there are none, or the lookup fails or takes too long). Slow: it may ask
/// several services, so planning never waits for it.
///
/// Null timing by default; the module that supplies [transitionPlannerProvider]
/// supplies this too.
final vocalTimingLoaderProvider =
    Provider<Future<VocalTiming?> Function(Track track)>(
      (ref) =>
          (track) async => null,
    );

/// Plans smart transitions; null when no planner is installed (then the
/// Smart setting is hidden and transitions are plain crossfades).
final transitionPlannerProvider = Provider<TransitionPlanner?>((ref) => null);

/// Plans Disco transitions; null when no planner is installed (then the
/// Disco setting is hidden).
final discoPlannerProvider = Provider<TransitionPlanner?>((ref) => null);

/// Chooses the next track of Surprise me; null picks at random.
final nextTrackPickerProvider = Provider<NextTrackPicker?>((ref) => null);

Future<T?> _orNull<T>(Future<T?> future) async {
  try {
    return await future;
  } on Object catch (e) {
    debugPrint('Transition input unavailable: ${e.runtimeType}');
    return null;
  }
}
