import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/tx_capture_store.dart';
import 'package:tetra_terminal/services/tx_level.dart';

/// Speech-like test signal: a 200 Hz + 900 Hz mix with a syllable rhythm.
List<double> speech(double rms, {double seconds = 3}) {
  final n = (8000 * seconds).round();
  final raw = List<double>.generate(n, (i) {
    final t = i / 8000;
    final env = 0.5 - 0.5 * math.cos(2 * math.pi * 4 * t);
    return env * (math.sin(2 * math.pi * 200 * t) + 0.6 * math.sin(2 * math.pi * 900 * t));
  });
  final r = rmsOf(raw);
  return [for (final v in raw) v / r * rms];
}

double rmsOf(Iterable<double> v) {
  var s = 0.0, n = 0;
  for (final x in v) {
    s += x * x;
    n++;
  }
  return math.sqrt(s / n);
}

double db(double ratio) => 20 * math.log(ratio) / math.ln10;

void main() {
  test('loud and quiet speech both leave near the nominal level', () {
    // A hot phone microphone (rms 12000, peaks clipping) and a quiet talker.
    for (final inRms in [12000.0, 5000.0, 2000.0, 800.0]) {
      final l = TxLevel();
      final out = speech(inRms).map(l.process).toList();
      final settled = rmsOf(out.skip(8000)); // after the first second
      expect(db(settled / l.targetRms).abs(), lessThan(3), reason: 'input rms $inRms -> $settled');
    }
  });

  test('a loud onset is turned down within 20 ms', () {
    final l = TxLevel();
    final out = speech(12000, seconds: 0.5).map(l.process).toList();
    expect(l.gain, lessThan(0.3));
    expect(rmsOf(out.skip(160).take(800)), lessThan(l.targetRms * 2.5), reason: '20..120 ms');
  });

  test('silence and room noise are not amplified', () {
    final l = TxLevel();
    final rnd = math.Random(1);
    final noise = List<double>.generate(8000 * 5, (_) => (rnd.nextDouble() * 2 - 1) * 100); // rms ~58
    final out = noise.map(l.process).toList();
    expect(l.gain, 1.0);
    expect(rmsOf(out), closeTo(rmsOf(noise), 0.01));
  });

  test('a pause after loud speech does not pump up the noise', () {
    final l = TxLevel();
    speech(12000, seconds: 1).forEach(l.process);
    final g = l.gain;
    final rnd = math.Random(2);
    for (var i = 0; i < 8000 * 3; i++) {
      l.process((rnd.nextDouble() * 2 - 1) * 100);
    }
    expect(l.gain, closeTo(g, g * 0.3), reason: 'gain held below the gate');
  });

  test('very quiet speech is raised by at most the cap', () {
    final l = TxLevel();
    speech(200, seconds: 5).forEach(l.process);
    expect(db(l.gain), closeTo(12, 0.5));
  });

  test('WAV header and samples', () {
    final w = wavBytes(Int16List.fromList([1, -2, 300]), 8000);
    expect(w.length, 44 + 6);
    expect(String.fromCharCodes(w.sublist(0, 4)), 'RIFF');
    expect(String.fromCharCodes(w.sublist(8, 16)), 'WAVEfmt ');
    final b = ByteData.sublistView(w);
    expect(b.getUint32(24, Endian.little), 8000);
    expect(b.getUint16(22, Endian.little), 1);
    expect(b.getUint32(40, Endian.little), 6);
    expect([b.getInt16(44, Endian.little), b.getInt16(46, Endian.little), b.getInt16(48, Endian.little)], [1, -2, 300]);
  });

  test('a capture is capped and its file names sort by time', () {
    final c = TxCapture(maxSeconds: 1);
    for (var i = 0; i < 30; i++) {
      c.addRaw(Int16List(1600), 16000);
      c.addEncoderInput(Int16List(800), 8000);
    }
    expect(c.raw.length, 16000);
    expect(c.encoderInput.length, 8000);
    expect(TxCaptureStore.stem(DateTime(2026, 11, 5, 9, 3, 7)), 'tx-20261105-090307');
  });
}
