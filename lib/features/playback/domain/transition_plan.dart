import 'dart:math' as math;

/// How one track hands over to the next.
enum TransitionType {
  /// Tempo- and phase-locked blend over whole bars (DJ style).
  beatmatch,

  /// Outgoing track filtered down and faded while the next fades in.
  filterFade,

  /// Outgoing track stops on a downbeat with a short tail (an echo where
  /// the mixer can render one).
  echoOut,

  /// Straight cut from the end of one track's content to the next.
  cut,

  /// No gap and no overlap: the album's own continuity.
  gapless,

  /// Plain equal-power crossfade (no analysis to do better).
  simpleCrossfade,
}

/// Where the vocal timing of a side came from.
enum VocalSource { lyrics, audio, none }

enum KeyRelation { compatible, unknown, clash }

enum MixDeck { outgoing, incoming }

enum FilterKind { highPass, lowPass }

/// A filter cutoff moving from [startHz] to [endHz] (log-linearly) while the
/// blend progresses from [from] to [to] (0–1). Outside that range the
/// filter holds its nearest end value; before [from] it is bypassed unless
/// [holdBefore].
class FilterSweep {
  const FilterSweep({
    required this.deck,
    required this.kind,
    required this.from,
    required this.to,
    required this.startHz,
    required this.endHz,
    this.holdBefore = false,
  });

  final MixDeck deck;
  final FilterKind kind;
  final double from;
  final double to;
  final double startHz;
  final double endHz;
  final bool holdBefore;

  /// Cutoff at [progress], null while bypassed.
  double? cutoffAt(double progress) {
    if (progress < from && !holdBefore) return null;
    final t = to <= from ? 1.0 : ((progress - from) / (to - from));
    final c = t.clamp(0.0, 1.0);
    return math.exp(
      math.log(startHz) + (math.log(endHz) - math.log(startHz)) * c,
    );
  }

  @override
  String toString() =>
      '${deck.name} ${kind.name} ${startHz.round()}→${endHz.round()} Hz '
      '@$from–$to';
}

/// Everything the mixer needs to perform one transition. Times are seconds
/// of each track's own media timeline; speeds are playback-rate factors
/// (pitch is preserved).
class TransitionPlan {
  const TransitionPlan({
    required this.type,
    required this.startInA,
    required this.endInA,
    required this.entryInB,
    required this.reason,
    this.bars,
    this.speedAEnd = 1,
    this.speedBStart = 1,
    this.beatRatio = 1,
    this.beatA = 0,
    this.beatB = 0,
    this.easeSeconds = 0,
    this.overlap = 0,
    this.gainA = 1,
    this.gainB = 1,
    this.bassSwapAt,
    this.filters = const [],
    this.vocalOutA,
    this.vocalInB,
    this.vocalSourceA = VocalSource.none,
    this.vocalSourceB = VocalSource.none,
    this.keys = KeyRelation.unknown,
    this.quick = false,
    this.bRise,
    this.aFall,
    this.skippedA = 0,
    this.alternatives = const [],
  });

  final TransitionType type;

  /// Outgoing time at which the incoming track becomes audible (and the
  /// controller switches to it).
  final double startInA;

  /// Outgoing time at which the outgoing track is silent and stops.
  final double endInA;

  /// Incoming time that plays at [startInA] (a downbeat for beat types).
  final double entryInB;

  /// Blend length in bars of the outgoing track (beat types only).
  final int? bars;

  /// The outgoing speed ramps linearly from 1 to this over the blend.
  final double speedAEnd;

  /// Incoming speed when the blend starts; while phase-locked it follows
  /// the outgoing tempo.
  final double speedBStart;

  /// Incoming beats per outgoing beat while locked (1, 2 or 0.5).
  final double beatRatio;

  /// Beat periods in media seconds (0 when not beat-based).
  final double beatA;
  final double beatB;

  /// After the blend, the incoming speed and gain trim return to normal
  /// over this long.
  final double easeSeconds;

  /// 0 = equal-power crossfade; up to 0.5 = both tracks near full level in
  /// the middle (DJ style, used with a bass swap).
  final double overlap;

  /// Loudness-matching trims (linear amplitude, ≤ 1) for the blend.
  final double gainA;
  final double gainB;

  /// Blend progress (0–1) where the low end swaps from A to B.
  final double? bassSwapAt;

  final List<FilterSweep> filters;

  final double? vocalOutA;
  final double? vocalInB;
  final VocalSource vocalSourceA;
  final VocalSource vocalSourceB;
  final KeyRelation keys;

  /// Blend progress where B reaches full level / A starts to fall; null:
  /// from [overlap].
  final double? bRise;
  final double? aFall;

  /// Seconds of A's content after [endInA] that are never played (its
  /// weak tail).
  final double skippedA;

  /// The runner-up plans the planner considered, best first, for the log.
  final List<String> alternatives;

  /// A last-resort quick fade: nothing better fitted the time left or the
  /// vocals (it may touch them).
  final bool quick;

  /// Human-readable explanation, for logs and tests.
  final String reason;

  bool get phaseLocked => type == TransitionType.beatmatch;

  /// Outgoing media seconds the blend covers.
  double get spanInA => endInA - startInA;

  /// Incoming media seconds the blend covers (the incoming speed follows
  /// the outgoing one, so the ratio holds throughout).
  double get spanInB => spanInA * speedBStart;

  /// Incoming time at which the blend ends.
  double get blendEndInB => entryInB + spanInB;

  /// Nominal wall-clock length of the blend.
  double get seconds => spanInA / ((1 + speedAEnd) / 2);

  /// Speed of the outgoing track at blend progress [t].
  double speedAAt(double t) => 1 + (speedAEnd - 1) * t.clamp(0, 1);

  /// Outgoing and incoming gains (before trims and user volume) at [t].
  (double, double) gainsAt(double t) {
    final c = t.clamp(0.0, 1.0);
    if (spanInA <= 0) return (c >= 1 ? 0 : 1, c >= 1 ? gainB : 0);
    if (type == TransitionType.echoOut) {
      // A drops and dies away like an echo tail over its last bar; B lands
      // on the next downbeat at full level, right as the tail ends.
      final tail = 0.5 * (1 - c) * (1 - c);
      final land = ((c - 0.96) / 0.04).clamp(0.0, 1.0);
      return (tail * gainA, land * gainB);
    }
    final o = overlap.clamp(0.0, 0.49);
    final rise = (bRise ?? 1 - o).clamp(0.05, 1.0);
    final fall = (aFall ?? o).clamp(0.0, 0.95);
    final inT = (c / rise).clamp(0.0, 1.0);
    final outT = ((c - fall) / (1 - fall)).clamp(0.0, 1.0);
    var a = math.cos(math.pi / 2 * outT);
    var b = math.sin(math.pi / 2 * inT);
    final swap = bassSwapAt;
    if (swap != null) {
      // Without EQ, emulate the swap with levels: B waits at -6 dB until
      // the swap, then the two trade places within about a beat and A
      // dips sharply (-9 dB) for the rest of the blend.
      const width = 0.06;
      final s = ((c - swap) / width + 0.5).clamp(0.0, 1.0);
      b = math.min(b, 0.5 + 0.5 * s);
      a = math.min(a, 1 - 0.65 * s);
    }
    final trimA = 1 + (gainA - 1) * c;
    return (a * trimA, b * gainB);
  }

  @override
  String toString() =>
      'TransitionPlan(${type.name}, A ${startInA.toStringAsFixed(2)}→'
      '${endInA.toStringAsFixed(2)}, B @${entryInB.toStringAsFixed(2)}'
      '${bars == null ? '' : ', $bars bars'}, $reason)';
}
