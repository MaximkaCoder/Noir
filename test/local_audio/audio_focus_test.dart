import 'dart:async';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:noir/integrations/local_audio/audio_deck.dart';
import 'package:noir/integrations/local_audio/local_audio_engine.dart';
import 'package:noir/shared/models/playback.dart';

/// A deck that only remembers whether it plays and how loud.
class _Deck implements AudioDeck {
  @override
  bool playing = false;
  double gain = 1;

  @override
  Stream<PlaybackStatus> get status => const Stream.empty();
  @override
  Stream<Duration?> get durations => const Stream.empty();
  @override
  Stream<String> get errors => const Stream.empty();
  @override
  Duration get position => Duration.zero;
  @override
  Duration? get duration => null;
  @override
  Future<double> exactPosition() async => 0;
  @override
  Future<void> open(String path, {Duration start = Duration.zero}) async {}
  @override
  Future<void> play() async => playing = true;
  @override
  Future<void> pause() async => playing = false;
  @override
  Future<void> seek(Duration position) async {}
  @override
  Future<void> stop() async => playing = false;
  @override
  Future<void> setLevel(double volume, {double gain = 1}) async =>
      this.gain = gain;
  @override
  Future<void> setSpeed(double speed) async {}
  @override
  Future<void> dispose() async {}
}

// Decks without audio focus of their own (libmpv) rely on the engine to
// give way to calls and other apps.
void main() {
  late List<_Deck> decks;
  late LocalAudioEngine engine;

  setUp(() {
    decks = [];
    engine = LocalAudioEngine(
      deckFactory: () {
        final d = _Deck();
        decks.add(d);
        return d;
      },
      audioSession: false,
      handleAudioFocus: true,
    );
  });
  tearDown(() => engine.dispose());

  _Deck active() => decks.first;

  Future<void> begin(AudioInterruptionType type) async {
    engine.onInterruption(AudioInterruptionEvent(true, type));
    await pumpEventQueue();
  }

  Future<void> end(AudioInterruptionType type) async {
    engine.onInterruption(AudioInterruptionEvent(false, type));
    await pumpEventQueue();
  }

  test('a call pauses and playback resumes after it', () async {
    await engine.play();
    await begin(AudioInterruptionType.pause);
    expect(active().playing, isFalse);
    await end(AudioInterruptionType.pause);
    expect(active().playing, isTrue);
  });

  test('an open-ended interruption pauses for good', () async {
    await engine.play();
    await begin(AudioInterruptionType.unknown);
    expect(active().playing, isFalse);
    await end(AudioInterruptionType.unknown);
    expect(active().playing, isFalse);
  });

  test('a short sound ducks, then the level comes back', () async {
    await engine.play();
    await begin(AudioInterruptionType.duck);
    expect(active().gain, lessThan(1));
    expect(active().playing, isTrue);
    await end(AudioInterruptionType.duck);
    expect(active().gain, 1);
  });

  test('nothing resumes what was already paused', () async {
    await begin(AudioInterruptionType.pause);
    await end(AudioInterruptionType.pause);
    expect(active().playing, isFalse);
  });

  test('pausing during a call keeps it paused afterwards', () async {
    await engine.play();
    await begin(AudioInterruptionType.pause);
    await engine.pause();
    await end(AudioInterruptionType.pause);
    expect(active().playing, isFalse);
  });
}
