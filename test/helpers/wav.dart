import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Writes a mono 16-bit PCM WAV with a quiet sine tone.
void writeSineWav(
  File file, {
  Duration duration = const Duration(seconds: 2),
  int sampleRate = 8000,
}) {
  final samples = sampleRate * duration.inMilliseconds ~/ 1000;
  final data = ByteData(44 + samples * 2);
  void ascii(int offset, String s) {
    for (var i = 0; i < s.length; i++) {
      data.setUint8(offset + i, s.codeUnitAt(i));
    }
  }

  ascii(0, 'RIFF');
  data.setUint32(4, 36 + samples * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  data
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little) // PCM
    ..setUint16(22, 1, Endian.little) // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little)
    ..setUint16(32, 2, Endian.little)
    ..setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  data.setUint32(40, samples * 2, Endian.little);
  for (var i = 0; i < samples; i++) {
    final v = (sin(2 * pi * 440 * i / sampleRate) * 3000).round();
    data.setInt16(44 + i * 2, v, Endian.little);
  }
  file
    ..createSync(recursive: true)
    ..writeAsBytesSync(data.buffer.asUint8List());
}
