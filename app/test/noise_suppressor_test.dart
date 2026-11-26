import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/noise_suppressor.dart';

double rmsOf(Iterable<double> v) {
  var s = 0.0, n = 0;
  for (final x in v) {
    s += x * x;
    n++;
  }
  return math.sqrt(s / n);
}

double db(double r) => 20 * math.log(r) / math.ln10;

/// Speech-like: 700 + 1300 + 2100 Hz in 300 ms words with 200 ms pauses.
List<double> speech(double rms, int n, {int offset = 0}) {
  final raw = List<double>.generate(n, (j) {
    final t = (j + offset) / 8000;
    final w = t % 0.5;
    final env = w < 0.3 ? math.pow(math.sin(math.pi * w / 0.3), 2).toDouble() : 0.0;
    return env * (math.sin(2 * math.pi * 700 * t) + 0.7 * math.sin(2 * math.pi * 1300 * t) + 0.4 * math.sin(2 * math.pi * 2100 * t));
  });
  final r = rmsOf(raw);
  return [for (final v in raw) v / r * rms];
}

List<double> noise(double rms, int n, int seed) {
  final rnd = math.Random(seed);
  return List.generate(n, (_) => (rnd.nextDouble() * 2 - 1) * rms * math.sqrt(3));
}

void main() {
  test('without noise the signal passes unchanged, delayed by the frame', () {
    final ns = NoiseSuppressor();
    final x = speech(3000, 16000);
    final y = x.map(ns.process).toList();
    const d = NoiseSuppressor.latency;
    final err = [for (var i = 8000; i < 16000; i++) y[i] - x[i - d]];
    expect(db(rmsOf(err) / 3000), lessThan(-20));
  });

  test('steady background noise is turned down', () {
    final ns = NoiseSuppressor();
    final x = noise(1000, 8000 * 4, 1);
    final y = x.map(ns.process).toList();
    expect(db(rmsOf(y.skip(8000)) / 1000), lessThan(-10));
  });

  test('speech over noise keeps its level and gains distance from the noise', () {
    const n = 8000 * 6;
    final s = speech(2000, n), w = noise(700, n, 2);
    // The weights are applied to the mix; measure what they do to each part.
    final ns = NoiseSuppressor();
    final mix = [for (var i = 0; i < n; i++) s[i] + w[i]];
    final out = mix.map(ns.process).toList();
    const d = NoiseSuppressor.latency;
    const tail = 8000 * 2;
    final sOut = [for (var i = tail; i < n; i++) s[i - d]];
    final resid = [for (var i = tail; i < n; i++) out[i] - s[i - d]];
    final inSnr = db(rmsOf(s.skip(tail)) / rmsOf(w.skip(tail)));
    final outSnr = db(rmsOf(sOut) / rmsOf(resid));
    final level = db(rmsOf(out.skip(tail)) / rmsOf(mix.skip(tail)));
    expect(outSnr - inSnr, greaterThan(4));
    expect(level, greaterThan(-3), reason: 'speech is not turned down with the noise');
  });
}
