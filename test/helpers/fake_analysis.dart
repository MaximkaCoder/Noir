import 'package:noir/features/analysis/domain/track_analysis.dart';

/// A synthetic analysis on an exact grid: [bars] bars at [bpm] starting at
/// [downbeat], with optional vocals between bar numbers.
TrackAnalysis fake({
  double bpm = 124,
  int bars = 96,
  double downbeat = 0.5,
  int introBars = 16,
  int outroBars = 16,
  String? key = 'A minor',
  double keyConfidence = 0.6,
  double lufs = -10,
  (int, int)? vocalBars,
  bool steady = true,
  double tempoConfidence = 0.8,
  double tail = 2,
}) {
  final beat = 60 / bpm;
  final bar = beat * 4;
  final beats = [for (var i = 0; i < bars * 4; i++) downbeat + i * beat];
  final end = downbeat + bars * bar;
  return TrackAnalysis(
    analysisVersion: TrackAnalysis.currentVersion,
    duration: end + tail,
    loudnessLufs: lufs,
    peakDb: -1,
    energyCurve: const [],
    contentStart: downbeat,
    contentEnd: end,
    bpm: bpm,
    tempoConfidence: tempoConfidence,
    steadyTempo: steady,
    beats: beats,
    firstDownbeat: downbeat,
    beatsPerBar: 4,
    key: key == null ? null : MusicalKey.parse(key),
    keyConfidence: keyConfidence,
    tuningCents: 0,
    introEnd: downbeat + introBars * bar,
    outroStart: downbeat + (bars - outroBars) * bar,
    mixInPoints: [for (var i = 0; i <= introBars; i += 8) downbeat + i * bar],
    mixOutPoints: [
      for (var i = bars - outroBars; i <= bars - 8; i += 8) downbeat + i * bar,
    ],
    sections: const [],
    vocals: vocalBars == null
        ? const []
        : [
            VocalSpan(
              downbeat + vocalBars.$1 * bar,
              downbeat + vocalBars.$2 * bar,
            ),
          ],
  );
}
