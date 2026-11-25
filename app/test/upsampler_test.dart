import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tetra_terminal/services/upsampler.dart';

Int16List sine8k(double f, int n, {double amp = 10000}) => Int16List.fromList([for (var i = 0; i < n; i++) (amp * math.sin(2 * math.pi * f * i / 8000)).round()]);

/// Amplitude of the [f] Hz component of [x] sampled at [rate] (single-bin DFT).
double level(List<int> x, double f, int rate) {
  var re = 0.0, im = 0.0;
  for (var i = 0; i < x.length; i++) {
    re += x[i] * math.cos(2 * math.pi * f * i / rate);
    im -= x[i] * math.sin(2 * math.pi * f * i / rate);
  }
  return 2 * math.sqrt(re * re + im * im) / x.length;
}

double db(double r) => 20 * math.log(r) / math.ln10;

void main() {
  test('speech band passes at full level, the spectral images are gone', () {
    for (final f in [300.0, 1000.0, 2500.0]) {
      final out = Upsampler().process(sine8k(f, 4000)).sublist(4800); // skip the start-up
      expect(out.length, 4000 * 6 - 4800);
      expect(db(level(out, f, 48000) / 10000).abs(), lessThan(0.5), reason: '$f Hz passes');
      // First images of an 8 kHz signal: 8000 - f and 8000 + f.
      expect(db(level(out, 8000 - f, 48000) / 10000), lessThan(-55), reason: 'image at ${8000 - f} Hz');
      expect(db(level(out, 8000 + f, 48000) / 10000), lessThan(-55), reason: 'image at ${8000 + f} Hz');
    }
  });

  test('chunked input gives the same output as one block', () {
    final x = sine8k(700, 2000);
    final whole = Upsampler().process(x);
    final u = Upsampler();
    final parts = <int>[];
    for (var i = 0; i < x.length; i += 333) {
      parts.addAll(u.process(Int16List.sublistView(x, i, math.min(i + 333, x.length))));
    }
    expect(parts, whole);
  });

  test('silence stays silence and full scale does not wrap', () {
    expect(Upsampler().process(Int16List(480)).every((v) => v == 0), isTrue);
    final sq = Int16List.fromList([for (var i = 0; i < 800; i++) (i ~/ 20).isEven ? 32767 : -32768]);
    final out = Upsampler().process(sq);
    // A wrapped sample would flip sign right next to a full-scale neighbour.
    for (var i = 1; i < out.length; i++) {
      expect((out[i] - out[i - 1]).abs(), lessThan(30000));
    }
  });
}
