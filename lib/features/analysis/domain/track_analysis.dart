/// Musical key mode.
enum KeyMode { major, minor }

/// A musical key with its Camelot wheel code (e.g. A minor = 8A).
class MusicalKey {
  const MusicalKey(this.root, this.mode);

  /// Parses `"A minor"`, `"Eb major"`… as written by [name].
  factory MusicalKey.parse(String name) {
    final parts = name.split(' ');
    final mode = parts.last == 'minor' ? KeyMode.minor : KeyMode.major;
    final names = mode == KeyMode.minor ? _minorNames : _majorNames;
    final root = names.indexOf(parts.first);
    if (parts.length != 2 || root < 0) {
      throw FormatException('Unknown key "$name"');
    }
    return MusicalKey(root, mode);
  }

  /// Pitch class of the tonic, 0 = C … 11 = B.
  final int root;
  final KeyMode mode;

  static const _majorNames = [
    'C', 'Db', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'Ab', 'A', 'Bb', 'B', //
  ];
  static const _minorNames = [
    'C', 'C#', 'D', 'Eb', 'E', 'F', 'F#', 'G', 'G#', 'A', 'Bb', 'B', //
  ];

  /// E.g. "A minor", "Db major".
  String get name =>
      '${(mode == KeyMode.minor ? _minorNames : _majorNames)[root]} '
      '${mode.name}';

  /// Camelot number 1–12: neighbours on the wheel are a fifth apart.
  int get camelotNumber {
    // C major = 8B; each fifth up adds one. A minor shares 8 with C major.
    final majorRoot = mode == KeyMode.major ? root : (root + 3) % 12;
    return (majorRoot * 7 + 7) % 12 + 1;
  }

  /// E.g. "8A" (minor) or "8B" (major).
  String get camelot => '$camelotNumber${mode == KeyMode.minor ? 'A' : 'B'}';

  @override
  String toString() => name;
}

/// Relative energy of a stretch of the track.
enum EnergyLevel { low, mid, high }

/// A bar-aligned stretch of roughly constant energy.
class EnergySection {
  const EnergySection({
    required this.start,
    required this.end,
    required this.level,
    required this.loudnessDb,
  });

  factory EnergySection.fromJson(Map<String, Object?> json) => EnergySection(
    start: _d(json['start']),
    end: _d(json['end']),
    level: EnergyLevel.values.byName(json['level']! as String),
    loudnessDb: _d(json['db']),
  );

  /// Seconds from the start of the file.
  final double start;
  final double end;
  final EnergyLevel level;

  /// Mean RMS level in dBFS.
  final double loudnessDb;

  Map<String, Object?> toJson() => {
    'start': _r3(start),
    'end': _r3(end),
    'level': level.name,
    'db': _r1(loudnessDb),
  };
}

/// A stretch where someone is probably singing (bar-aligned).
class VocalSpan {
  const VocalSpan(this.start, this.end);

  factory VocalSpan.fromJson(List<Object?> json) =>
      VocalSpan(_d(json[0]), _d(json[1]));

  /// Seconds from the start of the file.
  final double start;
  final double end;

  List<Object?> toJson() => [_r3(start), _r3(end)];
}

/// Everything the mixing planner needs to know about one track.
///
/// All times are seconds from the start of the decoded file. Loudness is
/// measured on the mono analysis downmix (an evenly panned stereo master
/// reads ~3 dB lower than its stereo LUFS); compare tracks with each other,
/// not with external meters.
class TrackAnalysis {
  const TrackAnalysis({
    required this.analysisVersion,
    required this.duration,
    required this.loudnessLufs,
    required this.peakDb,
    required this.energyCurve,
    required this.contentStart,
    required this.contentEnd,
    required this.bpm,
    required this.tempoConfidence,
    required this.steadyTempo,
    required this.beats,
    required this.firstDownbeat,
    required this.beatsPerBar,
    required this.key,
    required this.keyConfidence,
    required this.tuningCents,
    required this.introEnd,
    required this.outroStart,
    required this.mixInPoints,
    required this.mixOutPoints,
    required this.sections,
    this.vocals = const [],
    this.analyzedAt,
    this.elapsedMs,
    this.source,
  });

  factory TrackAnalysis.fromJson(Map<String, Object?> json) => TrackAnalysis(
    analysisVersion: json['version']! as int,
    duration: _d(json['duration']),
    loudnessLufs: _d(json['lufs']),
    peakDb: _d(json['peakDb']),
    energyCurve: _doubles(json['energy']),
    contentStart: _d(json['contentStart']),
    contentEnd: _d(json['contentEnd']),
    bpm: _d(json['bpm']),
    tempoConfidence: _d(json['tempoConfidence']),
    steadyTempo: json['steadyTempo']! as bool,
    beats: _doubles(json['beats']),
    firstDownbeat: (json['firstDownbeat'] as num?)?.toDouble(),
    beatsPerBar: json['beatsPerBar']! as int,
    key: json['key'] == null ? null : MusicalKey.parse(json['key']! as String),
    keyConfidence: _d(json['keyConfidence']),
    tuningCents: _d(json['tuningCents']),
    introEnd: _d(json['introEnd']),
    outroStart: _d(json['outroStart']),
    mixInPoints: _doubles(json['mixIn']),
    mixOutPoints: _doubles(json['mixOut']),
    sections: [
      for (final s in (json['sections'] as List<Object?>? ?? const []))
        EnergySection.fromJson((s! as Map).cast<String, Object?>()),
    ],
    vocals: [
      for (final v in (json['vocals'] as List<Object?>? ?? const []))
        VocalSpan.fromJson(v! as List<Object?>),
    ],
    analyzedAt: json['analyzedAt'] == null
        ? null
        : DateTime.parse(json['analyzedAt']! as String),
    elapsedMs: json['elapsedMs'] as int?,
    source: json['source'] as String?,
  );

  /// Bump whenever an algorithm change makes stored results stale; the
  /// queue re-analyses anything older.
  static const currentVersion = 2;

  final int analysisVersion;

  /// Decoded length in seconds.
  final double duration;

  /// Integrated loudness (ITU-R BS.1770 K-weighting and gating) of the mono
  /// downmix, in LUFS.
  final double loudnessLufs;

  /// Sample peak in dBFS.
  final double peakDb;

  /// RMS level per second, dBFS (index = second).
  final List<double> energyCurve;

  /// First and last audible moment (leading/trailing silence trimmed).
  final double contentStart;
  final double contentEnd;

  /// Tempo in beats per minute (60–200), 0 when no pulse was found.
  final double bpm;

  /// 0–1: how clearly periodic the onsets are.
  final double tempoConfidence;

  /// True when the tempo holds within ~2 % for the whole track — safe to
  /// beat-match on a fixed grid.
  final bool steadyTempo;

  /// Beat times as tracked (they follow drift in live recordings).
  final List<double> beats;

  /// Time of the first bar's downbeat, null without a beat grid.
  final double? firstDownbeat;

  /// Beats per bar (always 4 for now).
  final int beatsPerBar;

  /// Detected key, null when the audio is too atonal to tell.
  final MusicalKey? key;

  /// 0–1 margin of the best key over the runner-up.
  final double keyConfidence;

  /// Deviation of the track's tuning from A440, in cents (-50…50).
  final double tuningCents;

  /// End of the low-energy intro (bar-aligned); equals the first downbeat
  /// when the track starts at full energy.
  final double introEnd;

  /// Start of the outro (bar-aligned), placed at least 16 bars before the
  /// end when the track is long enough.
  final double outroStart;

  /// Phrase starts (every 8 bars) where an incoming mix can begin, earliest
  /// first.
  final List<double> mixInPoints;

  /// Phrase starts in the outro where an outgoing mix can begin, earliest
  /// first.
  final List<double> mixOutPoints;

  final List<EnergySection> sections;

  /// Where singing was detected from the audio alone (a rough estimate;
  /// empty when the track is instrumental or the detector is unsure).
  /// Time-synced lyrics, when available, are the better source.
  final List<VocalSpan> vocals;

  /// Start of the first / end of the last detected vocal, null when none.
  double? get firstVocal => vocals.isEmpty ? null : vocals.first.start;
  double? get lastVocal => vocals.isEmpty ? null : vocals.last.end;

  final DateTime? analyzedAt;

  /// Decode + analysis wall time.
  final int? elapsedMs;

  /// Fingerprint of the analysed file (size and modification time), used to
  /// notice when a local file changed.
  final String? source;

  /// Seconds per beat; 0 without a tempo.
  double get beatDuration => bpm > 0 ? 60 / bpm : 0;

  /// Seconds per bar; 0 without a tempo.
  double get barDuration => beatDuration * beatsPerBar;

  bool get isCurrent => analysisVersion == currentVersion;

  TrackAnalysis copyWith({
    DateTime? analyzedAt,
    int? elapsedMs,
    String? source,
  }) => TrackAnalysis(
    analysisVersion: analysisVersion,
    duration: duration,
    loudnessLufs: loudnessLufs,
    peakDb: peakDb,
    energyCurve: energyCurve,
    contentStart: contentStart,
    contentEnd: contentEnd,
    bpm: bpm,
    tempoConfidence: tempoConfidence,
    steadyTempo: steadyTempo,
    beats: beats,
    firstDownbeat: firstDownbeat,
    beatsPerBar: beatsPerBar,
    key: key,
    keyConfidence: keyConfidence,
    tuningCents: tuningCents,
    introEnd: introEnd,
    outroStart: outroStart,
    mixInPoints: mixInPoints,
    mixOutPoints: mixOutPoints,
    sections: sections,
    vocals: vocals,
    analyzedAt: analyzedAt ?? this.analyzedAt,
    elapsedMs: elapsedMs ?? this.elapsedMs,
    source: source ?? this.source,
  );

  Map<String, Object?> toJson() => {
    'version': analysisVersion,
    'duration': _r3(duration),
    'lufs': _r1(loudnessLufs),
    'peakDb': _r1(peakDb),
    'energy': [for (final e in energyCurve) _r1(e)],
    'contentStart': _r3(contentStart),
    'contentEnd': _r3(contentEnd),
    'bpm': (bpm * 100).round() / 100,
    'tempoConfidence': _r3(tempoConfidence),
    'steadyTempo': steadyTempo,
    'beats': [for (final b in beats) _r3(b)],
    'firstDownbeat': firstDownbeat == null ? null : _r3(firstDownbeat!),
    'beatsPerBar': beatsPerBar,
    'key': key?.name,
    'camelot': key?.camelot,
    'keyConfidence': _r3(keyConfidence),
    'tuningCents': _r1(tuningCents),
    'introEnd': _r3(introEnd),
    'outroStart': _r3(outroStart),
    'mixIn': [for (final t in mixInPoints) _r3(t)],
    'mixOut': [for (final t in mixOutPoints) _r3(t)],
    'sections': [for (final s in sections) s.toJson()],
    'vocals': [for (final v in vocals) v.toJson()],
    'analyzedAt': analyzedAt?.toUtc().toIso8601String(),
    'elapsedMs': elapsedMs,
    'source': source,
  };
}

double _d(Object? v) => (v! as num).toDouble();

List<double> _doubles(Object? v) => [
  for (final x in (v as List<Object?>? ?? const [])) (x! as num).toDouble(),
];

double _r1(double v) => v.isFinite ? (v * 10).round() / 10 : -120;

double _r3(double v) => (v * 1000).round() / 1000;
