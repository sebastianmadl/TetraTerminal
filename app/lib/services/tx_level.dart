import 'dart:math' as math;
import 'dart:typed_data';

/// Automatic level for the transmit path (8 kHz samples, before the limiter).
///
/// Brings speech to a fixed level before the ACELP encoder, whatever the
/// microphone delivers. A phone microphone without system voice processing is
/// much hotter than the nominal level speech codecs are specified for
/// (about -26 dBov active speech level); the fixed gain plus peak limiter that
/// was used alone lets loud speech through 10 dB and more above that, which
/// radios reproduce as very loud, harsh audio.
///
/// Fast down (a loud onset is turned down within a few milliseconds), slow up
/// (pauses do not pump the background noise), and no change at all below the
/// gate, so silence and room noise are never amplified.
class TxLevel {
  TxLevel({this.targetRms = 2000, this.maxGainDb = 12, this.minGainDb = -30, this.gateRms = 120});

  /// Speech level after the control (about -24 dBov).
  final double targetRms;
  final double maxGainDb;
  final double minGainDb;

  /// Below this level the gain is held.
  final double gateRms;

  // One-pole coefficients at 8 kHz.
  static const _envCoef = 0.004; // level detector, ~30 ms
  static const _down = 0.02; // ~6 ms
  static const _up = 0.00025; // ~0.5 s
  static const _nowCoef = 0.03; // ~4 ms

  double _pow = 0;
  double _now = 0;
  double _g = 1;

  /// Current gain (for tests).
  double get gain => _g;

  void reset() {
    _pow = 0;
    _now = 0;
    _g = 1;
  }

  double process(double x) {
    _pow += (x * x - _pow) * _envCoef;
    _now += (x * x - _now) * _nowCoef;
    final rms = math.sqrt(_pow);
    if (rms > gateRms) {
      final want = (targetRms / rms).clamp(_lin(minGainDb), _lin(maxGainDb));
      if (want < _g) {
        _g += (want - _g) * _down;
      } else if (_now > gateRms * gateRms) {
        // Up only while there is signal right now: in the pause after loud
        // speech the detector is still falling, which must not raise the gain.
        _g += (want - _g) * _up;
      }
    }
    return x * _g;
  }

  static double _lin(double db) => math.pow(10, db / 20).toDouble();
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
