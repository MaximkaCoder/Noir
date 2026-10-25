import 'dart:async';
import 'dart:math' as math;

import 'package:noir/features/playback/domain/transition_plan.dart';
import 'package:noir/integrations/local_audio/audio_deck.dart';
import 'package:noir/shared/models/playback.dart';

/// Wall-clock time for the mixer; tests substitute a simulated one.
abstract interface class MixClock {
  /// Seconds since an arbitrary origin.
  double now();
  Future<void> sleep(double seconds);
}

class RealMixClock implements MixClock {
  final _watch = Stopwatch()..start();

  @override
  double now() => _watch.elapsedMicroseconds / 1e6;

  @override
  Future<void> sleep(double seconds) => Future<void>.delayed(
    Duration(microseconds: (math.max(0, seconds) * 1e6).round()),
  );
}

/// Latencies learned across transitions of one engine.
class MixTiming {
  /// Seconds from play() until a paused deck is heard.
  double startLatency = 0.04;

  /// Seconds from seek() until the new position is heard.
  double seekLatency = 0.06;
}

/// One tick of a running transition, for diagnostics and tests.
class MixSample {
  const MixSample({
    required this.time,
    required this.a,
    required this.b,
    required this.error,
    required this.progress,
    required this.speedA,
    required this.speedB,
    required this.gainA,
    required this.gainB,
    required this.started,
  });

  /// Wall seconds ([MixClock.now]).
  final double time;

  /// Outgoing and incoming positions (media seconds, as heard).
  final double a;
  final double b;

  /// Incoming phase error in wall seconds (positive: incoming is ahead).
  final double error;
  final double progress;
  final double speedA;
  final double speedB;
  final double gainA;
  final double gainB;
  final bool started;
}

/// Plays one [TransitionPlan] from the outgoing deck into the incoming one.
abstract interface class MixRunner {
  /// Whether the incoming track became audible.
  bool get started;

  /// Ends the transition early: one that has not started is abandoned (the
  /// outgoing track keeps playing); a running one jumps to its end state.
  void settle();

  /// Returns whether the incoming track became the current one.
  Future<bool> run(String path);
}

typedef MixRunnerFactory = MixRunner Function({
  required AudioDeck outgoing,
  required AudioDeck incoming,
  required TransitionPlan plan,
  required double Function() volume,
  required MixTiming timing,
  MixClock? clock,
  void Function()? onStart,
  void Function(double progress)? onProgress,
  void Function(MixSample sample)? onSample,
});

/// A plain crossfade: the incoming track starts at the plan's entry point
/// when the outgoing one reaches its start, and the two are blended with
/// the plan's gain curves. No tempo or phase work.
class CrossfadeRunner implements MixRunner {
  CrossfadeRunner({
    required this.outgoing,
    required this.incoming,
    required this.plan,
    required this.volume,
    required this.timing,
    MixClock? clock,
    this.onStart,
    this.onProgress,
    this.onSample,
  }) : clock = clock ?? RealMixClock();

  final AudioDeck outgoing;
  final AudioDeck incoming;
  final TransitionPlan plan;
  final double Function() volume;
  final MixTiming timing;
  final MixClock clock;
  final void Function()? onStart;
  final void Function(double progress)? onProgress;
  final void Function(MixSample sample)? onSample;

  static const _tick = 0.02;

  bool _started = false;
  bool _settle = false;
  bool _outgoingDone = false;

  @override
  bool get started => _started;

  @override
  void settle() => _settle = true;

  @override
  Future<bool> run(String path) async {
    var startA = plan.startInA;
    var endA = plan.endInA;
    final length = outgoing.duration;
    final aDuration = length == null ? null : length.inMicroseconds / 1e6;
    if (aDuration != null && endA > aDuration) {
      startA = math.max(0, startA - (endA - aDuration));
      endA = aDuration;
    }
    final span = endA - startA;
    final sub = outgoing.status.listen((s) {
      if (s == PlaybackStatus.completed) _outgoingDone = true;
    });
    try {
      try {
        await incoming.setLevel(volume(), gain: 0);
        await incoming.open(path, start: _dur(plan.entryInB));
      } on DeckLoadException {
        return false;
      } on DeckInterrupted {
        return false;
      }
      while (true) {
        if (_settle) return await _abandon();
        final a = await outgoing.exactPosition();
        final trigger = startA - timing.startLatency;
        if (a >= trigger || _outgoingDone) break;
        final wait = trigger - a;
        await clock.sleep(wait > 0.06 ? math.min(wait - 0.04, 0.5) : wait);
      }
      await incoming.play();
      _started = true;
      onStart?.call();
      while (!_settle) {
        final a = await outgoing.exactPosition();
        final t = _outgoingDone || span <= 0
            ? 1.0
            : ((a - startA) / span).clamp(0.0, 1.0);
        final (gainA, gainB) = plan.gainsAt(t);
        await outgoing.setLevel(volume(), gain: gainA);
        await incoming.setLevel(volume(), gain: gainB);
        onProgress?.call(t);
        if (t >= 1) break;
        await clock.sleep(_tick);
      }
      await outgoing.setLevel(volume(), gain: 0);
      await outgoing.stop();
      await outgoing.setLevel(volume());
      await incoming.setLevel(volume());
      onProgress?.call(1);
      return true;
    } finally {
      await sub.cancel();
    }
  }

  Future<bool> _abandon() async {
    await incoming.stop();
    await outgoing.setLevel(volume());
    return false;
  }

  static Duration _dur(double seconds) =>
      Duration(microseconds: (seconds * 1e6).round());
}
