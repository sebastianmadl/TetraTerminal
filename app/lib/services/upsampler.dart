import 'dart:math' as math;
import 'dart:typed_data';

/// 8 kHz -> 48 kHz for playback: polyphase windowed-sinc interpolation with
/// the cut-off at the edge of the speech band (3.4 kHz).
///
/// Feeding the 8 kHz decoder output to the system directly leaves the rate
/// conversion to the audio unit, whose converter lets the spectral images of
/// the narrow-band signal (4..8 kHz and above) through audibly: speech sounds
/// rough and metallic. Converting here with a steep low-pass hands the system
/// a signal at the hardware rate that needs no further conversion.
/// Streaming: keeps its filter history between calls.
class Upsampler {
  Upsampler({this.factor = 6, this.tapsPerPhase = 16}) {
    final n = factor * tapsPerPhase;
    final fc = 3400 / (8000 * factor); // cycles per output sample
    final m = (n - 1) / 2;
    final h = List<double>.generate(n, (i) {
      final x = i - m;
      final sinc = x == 0 ? 2 * fc : math.sin(2 * math.pi * fc * x) / (math.pi * x);
      // Blackman window: images more than 70 dB down.
      final w = 0.42 - 0.5 * math.cos(2 * math.pi * i / (n - 1)) + 0.08 * math.cos(4 * math.pi * i / (n - 1));
      return sinc * w;
    });
    final sum = h.fold<double>(0, (a, b) => a + b);
    // Unity gain in the pass band: each phase sums to 1.
    _phases = List.generate(factor, (p) => Float64List.fromList([for (var k = 0; k < tapsPerPhase; k++) h[p + k * factor] * factor / sum]));
    _hist = Float64List(tapsPerPhase - 1);
  }

  final int factor;
  final int tapsPerPhase;
  late final List<Float64List> _phases;
  late Float64List _hist;

  void reset() => _hist = Float64List(tapsPerPhase - 1);

  Int16List process(Int16List input) {
    final n = input.length;
    final t = tapsPerPhase;
    final c = Float64List(t - 1 + n);
    c.setRange(0, t - 1, _hist);
    for (var i = 0; i < n; i++) {
      c[t - 1 + i] = input[i].toDouble();
    }
    final out = Int16List(n * factor);
    for (var i = 0; i < n; i++) {
      final base = t - 1 + i;
      for (var p = 0; p < factor; p++) {
        final h = _phases[p];
        var y = 0.0;
        for (var k = 0; k < t; k++) {
          y += h[k] * c[base - k];
        }
        out[i * factor + p] = y.round().clamp(-32768, 32767);
      }
    }
    _hist = Float64List.sublistView(c, n);
    return out;
  }
}
