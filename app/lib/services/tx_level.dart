import 'dart:math' as math;
import 'dart:typed_data';

/// High-pass for the transmit path (8 kHz): 4th-order Butterworth at 300 Hz, the lower edge of TETRA speech.
///
/// A phone microphone without the system's voice processing passes rumble and
/// hum (handling, wind, mains, 25..100 Hz). TETRA speech only uses 300..3400
/// Hz, but the energy below eats the encoder's dynamic range and buries the
/// voice: in a capture from an iPhone (2026-11-26) 73 % of the microphone
/// energy was below 300 Hz, constantly at about -28 dBFS.
class HighPass {
  HighPass({double cutoff = 300, int rate = 8000}) {
    // Two cascaded biquads, Q of a 4th-order Butterworth.
    for (final q in [0.5412, 1.3066]) {
      final w = 2 * math.pi * cutoff / rate;
      final alpha = math.sin(w) / (2 * q);
      final c = math.cos(w);
      final a0 = 1 + alpha;
      _s.add(_Biquad((1 + c) / 2 / a0, -(1 + c) / a0, (1 + c) / 2 / a0, -2 * c / a0, (1 - alpha) / a0));
    }
  }

  final _s = <_Biquad>[];

  void reset() {
    for (final b in _s) {
      b.reset();
    }
  }

  double process(double x) {
    for (final b in _s) {
      x = b.process(x);
    }
    return x;
  }
}

class _Biquad {
  _Biquad(this.b0, this.b1, this.b2, this.a1, this.a2);
  final double b0, b1, b2, a1, a2;
  double _z1 = 0, _z2 = 0;

  void reset() => _z1 = _z2 = 0;

  double process(double x) {
    final y = b0 * x + _z1;
    _z1 = b1 * x - a1 * y + _z2;
    _z2 = b2 * x - a2 * y;
    return y;
  }
}

/// Automatic level for the transmit path (8 kHz samples, after [HighPass],
/// before the limiter).
///
/// Brings speech to a fixed level before the ACELP encoder, whatever the
/// microphone delivers. A phone microphone without system voice processing is
/// much hotter than the nominal level speech codecs are specified for
/// (about -26 dBov active speech level); the fixed gain plus peak limiter that
/// was used alone lets loud speech through 10 dB and more above that.
///
/// Fast down (a loud onset is turned down within a few milliseconds), slow up,
/// and up only for speech: the control tracks the background level (falls at
/// once, rises slowly) and raises the gain only while the signal is clearly
/// above it. Room noise, hum and pauses are never raised.
class TxLevel {
  TxLevel({this.targetRms = 2000, this.maxGainDb = 12, this.minGainDb = -30, this.gateRms = 120, this.speechOverNoiseDb = 9});

  /// Speech level after the control (about -24 dBov).
  double targetRms;
  final double maxGainDb;
  final double minGainDb;

  /// Below this level the gain is held.
  final double gateRms;

  /// The gain only rises while the signal is this far above the background.
  final double speechOverNoiseDb;

  // One-pole coefficients at 8 kHz.
  static const _envCoef = 0.004; // level detector, ~30 ms
  static const _down = 0.02; // ~6 ms
  static const _up = 0.00025; // ~0.5 s
  static const _nowCoef = 0.03; // ~4 ms
  static const _floorRise = 0.0005; // background estimate rises ~17 dB/s

  double _pow = 0;
  double _now = 0;
  double _floor = 0;
  double _g = 1;
  int _warm = 0;

  /// Current gain (for tests).
  double get gain => _g;

  /// Current background estimate as rms (for tests).
  double get noiseRms => math.sqrt(_floor);

  void reset() {
    _pow = 0;
    _now = 0;
    _floor = 0;
    _g = 1;
    _warm = 0;
  }

  // The first 50 ms only learn the background: the level detector is still
  // rising, and the background estimate would lag far behind it.
  static const _warmup = 400;

  double process(double x) {
    _pow += (x * x - _pow) * _envCoef;
    _now += (x * x - _now) * _nowCoef;
    final warming = _warm < _warmup;
    if (warming) {
      _warm++;
      _floor = _pow;
    } else if (_pow < _floor) {
      _floor = _pow;
    } else {
      _floor += _floor * _floorRise;
    }
    final rms = math.sqrt(_pow);
    if (rms > gateRms) {
      final want = (targetRms / rms).clamp(_lin(minGainDb), _lin(maxGainDb));
      final speech = _now > _floor * _lin(speechOverNoiseDb) * _lin(speechOverNoiseDb);
      if (want < _g) {
        _g += (want - _g) * _down;
      } else if (speech && !warming) {
        // Up only while there is speech right now: not on the background, and
        // not in the pause after loud speech while the detector still falls.
        _g += (want - _g) * _up;
      }
    }
    return x * _g;
  }

  static double _lin(double db) => math.pow(10, db / 20).toDouble();
}

/// Received speech at one level: quiet and loud talkers, and radios with
/// different microphone gain, all come out about equally loud. Same control
/// as on the transmit side (fast down, slow up, only for speech, background
/// never raised), aimed a little hotter, with a hard ceiling against clipping.
class RxLeveller {
  RxLeveller({this.enabled = true});

  /// Automatic level on or off. Off: only [gainDb] and the ceiling apply.
  bool enabled;

  /// Default speech level after the control (about -21 dBov).
  static const targetRms = 3000.0;

  /// Look-ahead (30 ms): the gain for a sample is the one the control has
  /// reached after hearing the 30 ms that follow it. Without it the first
  /// milliseconds of a loud syllable after a quiet stretch went out at the
  /// quiet stretch's gain, as loud clicks and beeps up to clipping.
  static const lookAhead = 240;

  final _level = TxLevel(targetRms: targetRms, maxGainDb: 15, gateRms: 60);
  final _lim = PeakLimiter(limit: 32767 * 0.7079);
  final _delay = Float64List(lookAhead);
  int _pos = 0;
  double _boost = 1;

  /// Extra gain on top of everything else, in dB (0 = none).
  double get gainDb => 20 * math.log(_boost) / math.ln10;
  set gainDb(double db) => _boost = math.pow(10, db / 20).toDouble();

  /// Speech level the automatic level aims for, in dB below full scale (rms).
  double get targetDb => 20 * math.log(_level.targetRms / 32768) / math.ln10;
  set targetDb(double db) => _level.targetRms = 32768 * math.pow(10, db / 20).toDouble();

  /// Highest peak that leaves the control, in dB below full scale.
  double get maxDb => 20 * math.log(_lim.limit / 32767) / math.ln10;
  set maxDb(double db) => _lim.limit = 32767 * math.pow(10, db.clamp(-40, 0) / 20).toDouble();

  Int16List process(Int16List pcm) {
    // Nothing to do: hand the decoder output through untouched.
    if (!enabled && _boost == 1) return pcm;
    final out = Int16List(pcm.length);
    for (var i = 0; i < pcm.length; i++) {
      var x = pcm[i].toDouble();
      if (enabled) {
        _level.process(x);
        final g = _level.gain;
        final late = _delay[_pos];
        _delay[_pos] = x;
        _pos = (_pos + 1) % lookAhead;
        x = late * g;
      }
      out[i] = _lim.process(x * _boost).round().clamp(-32767, 32767);
    }
    return out;
  }
}

/// Look-ahead peak limiter. Louder input is attenuated instead of clipping
/// (on transmit: instead of overdriving the ACELP encoder, harsh beeps on loud
/// speech). The gain ramps down smoothly *before* a peak (the signal is
/// delayed by [look] samples), so limiting adds no clicks, and recovers slowly
/// (~100 ms) so sustained loud speech is not amplitude-modulated.
class PeakLimiter {
  PeakLimiter({this.limit = 12000.0});

  static const look = 16; // 2 ms at 8 kHz
  static const _release = 0.0012;

  /// Highest absolute sample value that leaves the limiter.
  double limit;

  // growable: we shift these (removeAt/add) every sample; filled() is fixed-length by default.
  final List<double> _g = List<double>.filled(2 * look + 1, 1.0, growable: true); // wanted gains, oldest first
  final List<double> _x = List<double>.filled(look + 1, 0.0, growable: true); // delayed signal
  double _r = 1.0;

  void reset() {
    _g.fillRange(0, _g.length, 1.0);
    _x.fillRange(0, _x.length, 0.0);
    _r = 1.0;
  }

  double process(double x) {
    _g.removeAt(0);
    final a = x.abs();
    _g.add(a > limit ? limit / a : 1.0);
    _x.removeAt(0);
    _x.add(x);
    // Sliding minimum over the look-ahead window, averaged over the same length:
    // guarantees the smoothed gain is <= the wanted gain at every sample.
    var sum = 0.0;
    for (var p = 0; p <= look; p++) {
      var m = 1.0;
      for (var q = p; q <= p + look; q++) {
        if (_g[q] < m) m = _g[q];
      }
      sum += m;
    }
    final smooth = sum / (look + 1);
    final recovering = _r + (1.0 - _r) * _release;
    _r = smooth < recovering ? smooth : recovering;
    return _x[0] * _r;
  }
}

/// Peak level of the audio that last went through, for the level meters.
class LevelMeter {
  LevelMeter({DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final DateTime Function() _clock;

  /// Shown as "no signal".
  static const floorDb = -60.0;

  /// A reading older than this counts as silence (frames come every 60 ms).
  static const stale = Duration(milliseconds: 200);

  double _db = floorDb;
  DateTime _at = DateTime.fromMillisecondsSinceEpoch(0);

  void add(Int16List pcm) {
    if (pcm.isEmpty) return;
    var peak = 0;
    for (final v in pcm) {
      final a = v.abs();
      if (a > peak) peak = a;
    }
    _db = peak == 0 ? floorDb : (20 * math.log(peak / 32768) / math.ln10).clamp(floorDb, 0.0);
    _at = _clock();
  }

  /// Peak of the newest block in dB below full scale, [floorDb] when silent.
  double get db => _clock().difference(_at) > stale ? floorDb : _db;
}

/// A mono PCM16 WAV file.
Uint8List wavBytes(Int16List pcm, int sampleRate) {
  final data = pcm.length * 2;
  final b = ByteData(44 + data);
  void tag(int at, String s) {
    for (var i = 0; i < 4; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < pcm.length; i++) {
    b.setInt16(44 + i * 2, pcm[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Keeps one transmission for diagnostics: what the microphone delivered
/// (16 kHz) and what went into the voice encoder (8 kHz). Capped in length.
class TxCapture {
  TxCapture({this.maxSeconds = 60});
  final int maxSeconds;
  final _raw = <int>[];
  final _enc = <int>[];

  void addRaw(Int16List pcm, int rate) {
    if (_raw.length < maxSeconds * rate) _raw.addAll(pcm);
  }

  void addEncoderInput(Int16List pcm, int rate) {
    if (_enc.length < maxSeconds * rate) _enc.addAll(pcm);
  }

  bool get isEmpty => _raw.isEmpty && _enc.isEmpty;
  Int16List get raw => Int16List.fromList(_raw);
  Int16List get encoderInput => Int16List.fromList(_enc);
}
