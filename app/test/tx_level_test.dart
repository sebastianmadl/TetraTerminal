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
      // The gain only rises during speech, so the syllable peaks set it and
      // the long-term rms (pauses included) ends up a few dB below target.
      expect(db(settled / l.targetRms).abs(), lessThan(4), reason: 'input rms $inRms -> $settled');
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

  test('the high-pass removes rumble and keeps the TETRA speech band', () {
    double gainAt(double f) {
      final h = HighPass();
      final x = [for (var i = 0; i < 16000; i++) math.sin(2 * math.pi * f * i / 8000) * 10000];
      final y = x.map(h.process).toList();
      return db(rmsOf(y.skip(8000)) / rmsOf(x.skip(8000)));
    }

    expect(gainAt(50), lessThan(-50), reason: 'mains hum and handling rumble');
    expect(gainAt(100), lessThan(-35));
    expect(gainAt(300), closeTo(-3, 0.5), reason: '-3 dB at the lower edge of TETRA speech');
    expect(gainAt(1000).abs(), lessThan(0.5));
    expect(gainAt(3000).abs(), lessThan(0.5));
  });

  test('steady background noise is learnt and not raised to speech level', () {
    // A raw iPhone microphone in a room, rms about 1000: below the target, but
    // far above the gate. Raising it would bury the speech that follows.
    final l = TxLevel();
    final rnd = math.Random(3);
    for (var i = 0; i < 8000 * 5; i++) {
      l.process((rnd.nextDouble() * 2 - 1) * 1730);
    }
    expect(l.noiseRms, closeTo(1000, 150));
    expect(db(l.gain), lessThan(1), reason: 'gain ${l.gain}');
  });

  test('speech over learnt noise is still raised', () {
    final l = TxLevel();
    final rnd = math.Random(4);
    for (var i = 0; i < 8000 * 2; i++) {
      l.process((rnd.nextDouble() * 2 - 1) * 170); // rms ~100
    }
    final out = speech(800).map(l.process).toList();
    expect(db(rmsOf(out.skip(8000)) / l.targetRms).abs(), lessThan(4));
  });

  test('received talkers of different loudness play at one level, or untouched when off', () {
    Int16List frames(double rms) => Int16List.fromList(speech(rms, seconds: 4.32).map((v) => v.round().clamp(-32768, 32767)).toList());
    for (final rms in [400.0, 1500.0, 9000.0]) {
      final r = RxLeveller();
      final pcm = frames(rms);
      final out = <int>[];
      for (var i = 0; i < pcm.length; i += 480) {
        out.addAll(r.process(Int16List.sublistView(pcm, i, i + 480)));
      }
      final settled = rmsOf(out.skip(16000).map((v) => v.toDouble()));
      expect(db(settled / RxLeveller.targetRms).abs(), lessThan(4), reason: 'talker rms $rms -> $settled');
    }
    final off = RxLeveller(enabled: false);
    final pcm = frames(400);
    expect(off.process(pcm), same(pcm));
  });

  test('a loud syllable after a quiet stretch does not blast out at the quiet gain', () {
    // 2 s of a quiet talker (the gain climbs), then a loud one at once.
    final quiet = speech(300, seconds: 2.04), loud = speech(6000, seconds: 0.96);
    final pcm = Int16List.fromList([...quiet, ...loud].map((v) => v.round()).toList());
    final r = RxLeveller();
    final out = <int>[];
    for (var i = 0; i < pcm.length; i += 480) {
      out.addAll(r.process(Int16List.sublistView(pcm, i, i + 480)));
    }
    // The loud part, shifted by the look-ahead: no peak beyond what its settled level gives.
    final start = quiet.length + RxLeveller.lookAhead;
    final onset = out.sublist(start, start + 400).map((v) => v.abs()).reduce(math.max);
    final settled = out.sublist(out.length - 2400).map((v) => v.abs()).reduce(math.max);
    expect(onset, lessThan(settled * 1.5), reason: 'onset peak $onset, settled peak $settled');
  });

  test('receive boost raises the level, and the maximum level is never exceeded', () {
    Int16List tone(int amp) => Int16List.fromList([for (var i = 0; i < 4800; i++) (amp * math.sin(2 * math.pi * 1000 * i / 8000)).round()]);
    int peak(Int16List p) => p.skip(800).map((v) => v.abs()).reduce(math.max);
    // Level control off: +6 dB doubles a quiet tone.
    final boost = RxLeveller(enabled: false)..gainDb = 6;
    expect(peak(boost.process(tone(2000))), closeTo(3990, 60));
    // A loud tone with +18 dB stays under the -6 dB ceiling instead of clipping.
    final hot = RxLeveller(enabled: false)
      ..gainDb = 18
      ..maxDb = -6;
    final ceiling = 32767 * math.pow(10, -6 / 20);
    expect(peak(hot.process(tone(20000))), lessThanOrEqualTo(ceiling.ceil()));
    expect(peak(hot.process(tone(20000))), greaterThan(ceiling * .9));
    // The level control aims for the chosen target.
    for (final target in [-27.0, -15.0]) {
      final r = RxLeveller()..targetDb = target;
      final pcm = Int16List.fromList(speech(1500, seconds: 6).map((v) => v.round()).toList());
      final out = r.process(pcm);
      final tail = out.sublist(out.length - 8000);
      final rms = math.sqrt(tail.map((v) => v * v).reduce((a, b) => a + b) / tail.length);
      expect(20 * math.log(rms / 32768) / math.ln10, closeTo(target, 4), reason: 'target $target');
    }
  });

  test('level meter: peak in dB, silent again when no audio follows', () {
    var now = DateTime(2026);
    final meter = LevelMeter(clock: () => now);
    expect(meter.db, LevelMeter.floorDb);
    meter.add(Int16List.fromList([0, 16384, -100]));
    expect(meter.db, closeTo(-6.02, .01));
    meter.add(Int16List(480));
    expect(meter.db, LevelMeter.floorDb);
    meter.add(Int16List.fromList([-32768]));
    expect(meter.db, 0);
    now = now.add(const Duration(milliseconds: 300));
    expect(meter.db, LevelMeter.floorDb);
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
