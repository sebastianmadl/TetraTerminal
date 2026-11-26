import 'dart:math' as math;
import 'dart:typed_data';

/// Background noise suppression for the transmit path (8 kHz, before the
/// level control and the ACELP encoder).
///
/// Short-time spectral weighting: 256-sample frames (32 ms) with 50 % overlap
/// and a square-root Hann window for analysis and synthesis. Per frequency bin
/// the noise power is tracked as the minimum of the smoothed signal power
/// (it falls at once and creeps up slowly, so speech, which keeps pausing, is
/// not learnt as noise), and the bin is weighted with a Wiener gain from the
/// decision-directed a-priori SNR (Ephraim and Malah). The gain never goes
/// below [maxReductionDb] below unity, which keeps the remaining background
/// smooth instead of "musical".
///
/// Adds [latency] samples (32 ms) of delay.
class NoiseSuppressor {
  NoiseSuppressor({this.maxReductionDb = 10}) {
    _prevG.fillRange(0, _bins, 1);
  }

  /// The largest attenuation applied to a bin.
  final double maxReductionDb;

  static const _n = 256;
  static const _hop = 128;
  static const _bins = _n ~/ 2 + 1;

  /// Delay from input to output in samples.
  static const latency = _n;

  static const _learnFrames = 8; // the first 64 ms only learn the background
  static const _smooth = 0.7; // power smoothing per frame
  static const _rise = 1.006; // noise estimate creeps up ~1.6 dB/s
  static const _overEstimate = 2.0; // the minimum sits below the mean noise
  static const _dd = 0.98; // decision-directed weight

  static final Float64List _win = Float64List.fromList(
      List.generate(_n, (i) => math.sqrt(0.5 - 0.5 * math.cos(2 * math.pi * i / _n))));

  late final double _gMin = math.pow(10, -maxReductionDb / 20).toDouble();

  final _in = Float64List(_n);
  final _ola = Float64List(_n);
  var _ready = Float64List(_hop);
  int _fill = 0;
  int _frames = 0;

  final _re = Float64List(_n);
  final _im = Float64List(_n);
  final _ps = Float64List(_bins);
  final _noise = Float64List(_bins);
  final _prevG = Float64List(_bins);
  final _prevP = Float64List(_bins);

  void reset() {
    _in.fillRange(0, _n, 0);
    _ola.fillRange(0, _n, 0);
    _ready = Float64List(_hop);
    _fill = 0;
    _frames = 0;
    _ps.fillRange(0, _bins, 0);
    _noise.fillRange(0, _bins, 0);
    _prevG.fillRange(0, _bins, 1);
    _prevP.fillRange(0, _bins, 0);
  }

  double process(double x) {
    _in[_n - _hop + _fill] = x;
    final y = _ready[_fill];
    if (++_fill == _hop) {
      _fill = 0;
      _frame();
    }
    return y;
  }

  void _frame() {
    for (var i = 0; i < _n; i++) {
      _re[i] = _in[i] * _win[i];
      _im[i] = 0;
    }
    _fft(_re, _im, false);

    final learning = _frames < _learnFrames;
    for (var k = 0; k < _bins; k++) {
      final p = _re[k] * _re[k] + _im[k] * _im[k];
      if (learning) {
        _ps[k] = _frames == 0 ? p : _ps[k] + (p - _ps[k]) / (_frames + 1);
        _noise[k] = _ps[k];
      } else {
        _ps[k] = _smooth * _ps[k] + (1 - _smooth) * p;
        _noise[k] = _ps[k] < _noise[k] ? _ps[k] : _noise[k] * _rise;
      }
      final nz = math.max(_noise[k] * _overEstimate, 1e-3);
      final post = p / nz;
      final prio = _dd * _prevG[k] * _prevG[k] * _prevP[k] / nz + (1 - _dd) * math.max(post - 1, 0);
      final g = math.max(prio / (1 + prio), _gMin);
      _prevG[k] = g;
      _prevP[k] = p;
      _re[k] *= g;
      _im[k] *= g;
      if (k > 0 && k < _n ~/ 2) {
        _re[_n - k] *= g;
        _im[_n - k] *= g;
      }
    }
    _frames++;

    _fft(_re, _im, true);
    for (var i = 0; i < _n; i++) {
      _ola[i] += _re[i] * _win[i];
    }
    _ready = Float64List.fromList(_ola.sublist(0, _hop));
    _ola.setRange(0, _n - _hop, _ola, _hop);
    _ola.fillRange(_n - _hop, _n, 0);
    _in.setRange(0, _n - _hop, _in, _hop);
  }

  /// In-place radix-2 FFT; [inverse] includes the 1/n scaling.
  static void _fft(Float64List re, Float64List im, bool inverse) {
    final n = re.length;
    for (var i = 1, j = 0; i < n; i++) {
      var bit = n >> 1;
      for (; j & bit != 0; bit >>= 1) {
        j ^= bit;
      }
      j ^= bit;
      if (i < j) {
        var t = re[i];
        re[i] = re[j];
        re[j] = t;
        t = im[i];
        im[i] = im[j];
        im[j] = t;
      }
    }
    for (var len = 2; len <= n; len <<= 1) {
      final ang = 2 * math.pi / len * (inverse ? 1 : -1);
      final wr = math.cos(ang), wi = math.sin(ang);
      for (var i = 0; i < n; i += len) {
        var cr = 1.0, ci = 0.0;
        for (var k = 0; k < len ~/ 2; k++) {
          final a = i + k, b = a + len ~/ 2;
          final xr = re[b] * cr - im[b] * ci;
          final xi = re[b] * ci + im[b] * cr;
          re[b] = re[a] - xr;
          im[b] = im[a] - xi;
          re[a] += xr;
          im[a] += xi;
          final t = cr * wr - ci * wi;
          ci = cr * wi + ci * wr;
          cr = t;
        }
      }
    }
    if (inverse) {
      for (var i = 0; i < n; i++) {
        re[i] /= n;
        im[i] /= n;
      }
    }
  }
}
