import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;
import 'package:tetra_mic/tetra_mic.dart';

import '../src/rust/api.dart' show TxDenoiser;
import 'noise_suppressor.dart';
import 'tx_level.dart';
import 'upsampler.dart';

/// 8 kHz mono PCM16 microphone capture and speaker playback.
///
/// The Rust core does all ACELP work; this layer only moves raw samples.
/// Third-party audio plugin calls are confined to this file so they can be
/// swapped (e.g. for a native AudioRecord/AudioTrack channel) without
/// touching the rest of the app.
class AudioIO {
  static const sampleRate = 8000;

  /// iOS plays at 48 kHz, converted here (see [Upsampler]); elsewhere the
  /// player takes the 8 kHz audio as it is.
  final Upsampler? _up = _isApple ? Upsampler() : null;
  int get _outRate => sampleRate * (_up?.factor ?? 1);

  /// The mic is captured at 16 kHz and decimated here with a proper low-pass.
  /// Asking Android for 8 kHz directly makes many devices resample badly
  /// (aliasing = glitches and whistles that the ACELP codec amplifies).
  static const _micRate = 16000;
  // iOS: automatic level. The raw iOS microphone is far hotter than the fixed
  // gain was made for (it was tuned on Android, which keeps it).
  final _decim = _Decimator2(level: _isApple ? TxLevel() : null);

  /// Diagnostics: keep each transmission's microphone and encoder input and
  /// hand them to [onTxCapture] when it ends.
  bool captureTx = false;
  void Function(TxCapture capture)? onTxCapture;
  TxCapture? _capture;

  /// Microphone trim in dB (applies immediately, also mid-transmission).
  set micGainDb(double db) => _decim.setTrimDb(db);

  /// Background noise suppression on the transmit path (from the next
  /// transmission on). See [NoiseSuppressor].
  bool get noiseSuppression => _decim.suppress;
  set noiseSuppression(bool on) => _decim.suppress = on;

  /// Received speech brought to one level, whoever talks.
  bool get rxLevel => _rx.enabled;
  set rxLevel(bool on) => _rx.enabled = on;
  final _rx = RxLeveller();

  /// Extra receive gain in dB, on top of the device volume.
  set rxGainDb(double db) => _rx.gainDb = db;

  /// Speech level the receive level control aims for (dB below full scale).
  set rxTargetDb(double db) => _rx.targetDb = db;

  /// Highest receive peak (dB below full scale).
  set rxMaxDb(double db) => _rx.maxDb = db;

  /// Peak levels for the meters: encoder input and what goes to the speaker.
  final txMeter = LevelMeter();
  final rxMeter = LevelMeter();

  /// Plays a 1 kHz tone at -12 dBFS for two seconds through the receive
  /// chain, to set the receive level without waiting for a call.
  void playTestTone() {
    _tone?.cancel();
    var n = 0;
    _tone = Timer.periodic(const Duration(milliseconds: 60), (t) {
      if (n >= 34) {
        t.cancel();
        _tone = null;
        return;
      }
      play(Int16List.fromList([for (var i = 0; i < 480; i++) (8231 * math.sin(2 * math.pi * 1000 * (n * 480 + i) / sampleRate)).round()]));
      n++;
    });
  }

  bool get testTonePlaying => _tone != null;
  Timer? _tone;

  /// Android capture; iOS uses [TetraMic], which survives hardware changes.
  /// Created on first use, so iOS never instantiates it.
  AudioRecorder? _rec;
  AudioRecorder get _recorder => _rec ??= AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _playerReady = false;
  DateTime _lastPlay = DateTime.fromMillisecondsSinceEpoch(0);
  final _carry = BytesBuilder(copy: false);

  /// Loudspeaker (true) or earpiece, the "phone mode" (false). A headset or
  /// Bluetooth device always wins over both.
  bool speaker = true;
  AudioSession? _session;

  Future<void> init() async {
    // flutter_pcm_sound sets its own AVAudioSession category in setup(), so it
    // goes first and our configuration below wins. iosAllowBackgroundAudio is
    // essential: without it the plugin silently drops every frame fed while the
    // app is not active (screen locked or in the background).
    await FlutterPcmSound.setup(
      sampleRate: _outRate,
      channelCount: 1,
      iosAudioCategory: IosAudioCategory.playAndRecord,
      iosAllowBackgroundAudio: true,
    );
    // iOS: playAndRecord so mic and speaker work together; normal playback
    // mode unless a full-duplex call runs (see sessionConfig). On Android
    // this requests voice-communication audio focus.
    final session = await AudioSession.instance;
    _session = session;
    await session.configure(_config());
    await session.setActive(true);
    // After a phone call or Siri the session is deactivated and the output unit
    // stopped. Reactivate and, in the background, restart the silence at once,
    // since iOS only lets an app keep (not start) audio there.
    session.interruptionEventStream.listen((e) async {
      if (e.begin) return;
      try {
        await session.setActive(true);
      } catch (_) {}
      await _applyRoute();
      if (_keepAlive != null) _feedSilenceIfLow();
    });
    // A plugin or the system can change the category or the route (headset
    // plugged in or out, another app): put the chosen output back. Our own
    // override is not answered, so this cannot loop.
    session.devicesChangedEventStream.listen((_) => _applyRoute());
    if (_isApple) {
      AVAudioSession().routeChangeStream.listen((c) {
        if (c.reason != AVAudioSessionRouteChangeReason.override) _applyRoute();
      });
    }
    await _applyRoute();
    // ~120 ms of headroom: two Brew frames of jitter.
    await FlutterPcmSound.setFeedThreshold(_outRate ~/ 8);
    // The plugin reports how much is really queued; keeps our estimate honest.
    FlutterPcmSound.setFeedCallback((remaining) {
      _queue.sync(remaining ~/ (_up?.factor ?? 1));
      if (_keepAlive != null) _feedSilenceIfLow();
    });
    _playerReady = true;
  }

  static bool get _isApple => defaultTargetPlatform == TargetPlatform.iOS;

  AudioSessionConfiguration _config() => sessionConfig(speaker: speaker, duplex: _duplex);

  /// A full-duplex call with echo cancellation is running (see [startMic]).
  bool _duplex = false;

  /// Switches between loudspeaker and earpiece at once (also mid-call).
  Future<void> setSpeaker(bool on) async {
    speaker = on;
    if (!_playerReady || _session == null) return;
    try {
      await _session!.configure(_config());
    } catch (_) {}
    await _applyRoute();
  }

  bool _routing = false;
  String? _androidRoute;

  /// Puts the output where [speaker] says, unless a headset is connected.
  Future<void> _applyRoute() async {
    if (_session == null || _routing) return;
    _routing = true;
    try {
      if (_isApple) {
        final av = AVAudioSession();
        final outputs = (await av.currentRoute).outputs.map((o) => o.portType).toList();
        final o = iosOverride(speaker: speaker, outputs: outputs);
        if (o != null) await av.overrideOutputAudioPort(o);
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        final am = AndroidAudioManager();
        final devices = await am.getDevices(AndroidGetAudioDevicesFlags.outputs);
        final headset = devices.any((d) => isHeadset(d.type));
        final want = headset ? 'headset' : (speaker ? 'speaker' : 'earpiece');
        // Same as last time: nothing to do (each call can glitch the output).
        if (want == _androidRoute) return;
        _androidRoute = want;
        if (headset) {
          await am.setMode(AndroidAudioHardwareMode.normal);
          await am.setSpeakerphoneOn(false);
        } else if (speaker) {
          await am.setMode(AndroidAudioHardwareMode.normal);
          await am.setSpeakerphoneOn(true);
        } else {
          // Earpiece: communication mode with the speakerphone off.
          await am.setMode(AndroidAudioHardwareMode.inCommunication);
          await am.setSpeakerphoneOn(false);
        }
      }
    } catch (_) {
      // Routing is best effort; audio keeps playing on the current output.
    } finally {
      _routing = false;
    }
  }

  bool get micRunning => _micSub != null;

  /// Starts streaming microphone audio to [onPcm]. Echo cancellation is on
  /// so full-duplex calls do not feed the speaker back into the mic.
  ///
  /// [voiceProcessing] enables platform echo cancellation / noise suppression /
  /// AGC. Only full-duplex calls need it; in half-duplex PTT the speaker is
  /// silent while the mic is live, and the processing only distorts the signal
  /// the ACELP encoder sees (and on iOS contends with the playback engine).
  Future<void> startMic(void Function(Int16List pcm) onPcm, {bool voiceProcessing = false}) async {
    if (_micSub != null) return;
    _decim.reset();
    _carry.clear();
    final granted = _isApple ? await TetraMic.hasPermission() : await _recorder.hasPermission();
    if (!granted) {
      throw StateError('Microphone permission denied');
    }
    await _setDuplex(voiceProcessing);
    final capture = _capture = captureTx ? TxCapture() : null;
    void onBytes(Uint8List bytes) {
      // Chunks can split a sample; keep any odd trailing byte for next time.
      _carry.add(bytes);
      final all = _carry.takeBytes();
      final even = all.length & ~1;
      if (even > 0) {
        final copy = Uint8List.fromList(all.sublist(0, even));
        final raw = copy.buffer.asInt16List();
        final samples = _decim.process(raw);
        txMeter.add(samples);
        capture?.addRaw(raw, _micRate);
        capture?.addEncoderInput(samples, sampleRate);
        if (samples.isNotEmpty) onPcm(samples);
      }
      if (even < all.length) _carry.add(all.sublist(even));
    }

    if (_isApple) {
      // Own capture: the record plugin fixes its converter at start and keeps
      // converting with it after the hardware was reconfigured mid-recording,
      // which the ACELP encoder turns into a loud tone.
      try {
        _micSub = await TetraMic.start(sampleRate: _micRate, voiceProcessing: voiceProcessing, onData: onBytes);
      } catch (_) {
        await _setDuplex(false);
        rethrow;
      }
    } else {
      final stream = await _recorder.startStream(RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _micRate,
        numChannels: 1,
        echoCancel: voiceProcessing,
        noiseSuppress: voiceProcessing,
        autoGain: voiceProcessing,
        androidConfig: const AndroidRecordConfig(
          // Plain mic: on Samsung (and others) voiceCommunication yields near-silent input
          // unless the whole system is in call mode.
          audioSource: AndroidAudioSource.mic,
        ),
      ));
      _micSub = stream.listen(onBytes);
    }
    await _applyRoute();
  }

  Future<void> stopMic() async {
    await _micSub?.cancel();
    final wasRunning = _micSub != null;
    _micSub = null;
    _carry.clear();
    if (_isApple) {
      if (wasRunning) await TetraMic.stop();
    } else if (await _recorder.isRecording()) {
      await _recorder.stop();
    }
    await _setDuplex(false);
    await _applyRoute();
    final capture = _capture;
    _capture = null;
    if (capture != null && !capture.isEmpty) onTxCapture?.call(capture);
  }

  /// Switches the session between call mode (full duplex) and normal playback.
  Future<void> _setDuplex(bool on) async {
    if (_duplex == on) return;
    _duplex = on;
    if (_session == null) return;
    try {
      await _session!.configure(_config());
    } catch (_) {}
  }

  final _queue = PlayoutQueue(sampleRate);

  void _feed(Int16List pcm) {
    _queue.fed(pcm.length);
    final up = _up;
    if (up != null) pcm = up.process(pcm);
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
  }

  /// Plays one decoded Brew frame (480 samples = 60 ms).
  void play(Int16List pcm) {
    if (!_playerReady) return;
    // New talk spurt (or after an underrun): queue 60 ms of silence first so
    // network jitter between frames does not turn into clicks and gaps. Not
    // needed when keep-alive silence is still queued ahead of the frame.
    final now = DateTime.now();
    if (now.difference(_lastPlay) > const Duration(milliseconds: 150) && _queue.queuedSamples() < pcm.length) {
      _feed(Int16List(pcm.length));
    }
    _lastPlay = now;
    final out = _rx.process(pcm);
    rxMeter.add(out);
    _feed(out);
  }

  Timer? _keepAlive;

  void _feedSilenceIfLow() {
    if (!_playerReady) return;
    if (DateTime.now().difference(_lastPlay) < const Duration(milliseconds: 300)) return; // a call is playing
    final n = _queue.silenceToFeed();
    if (n > 0) _feed(Int16List(n));
  }

  /// Background operation on iOS: the app may keep running in the background
  /// (UIBackgroundModes `audio`) only while its audio session plays, and iOS
  /// refuses to *start* playback once the app is in the background. So silence
  /// must already be flowing when the app leaves the foreground: the model
  /// turns this on as soon as the app becomes inactive, and the first block is
  /// fed right away. Afterwards a short queue of silence is topped up (timer
  /// plus the plugin's low-buffer callback) so the output unit never runs dry;
  /// calls then play as usual. Costs some battery.
  void keepAlive(bool on) {
    if (on && _keepAlive != null) return;
    _keepAlive?.cancel();
    _keepAlive = null;
    if (!on || !_playerReady) return;
    _keepAlive = Timer.periodic(const Duration(milliseconds: 100), (_) => _feedSilenceIfLow());
    _feedSilenceIfLow();
  }

  Future<void> dispose() async {
    _tone?.cancel();
    keepAlive(false);
    await stopMic();
    await _rec?.dispose();
    await FlutterPcmSound.release();
  }
}

/// The audio session for the current state.
///
/// iOS: `playAndRecord` so mic and speaker work together, Bluetooth headsets
/// allowed, `defaultToSpeaker` only in loudspeaker mode. The session mode is
/// `voiceChat` only while a full-duplex call runs with echo cancellation:
/// that mode makes iOS treat the app as a phone call, so the volume buttons
/// set the call volume and the output is the quieter call level, even on the
/// loudspeaker. Group calls and PTT play in the default mode, at media volume.
/// Android: voice-communication audio focus (playback itself is media audio).
AudioSessionConfiguration sessionConfig({required bool speaker, required bool duplex}) => AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: (speaker ? AVAudioSessionCategoryOptions.defaultToSpeaker : AVAudioSessionCategoryOptions.none) |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      avAudioSessionMode: duplex ? AVAudioSessionMode.voiceChat : AVAudioSessionMode.defaultMode,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    );

/// Output ports that are a headset or another external device: they always
/// win over the loudspeaker / earpiece choice.
const _externalPorts = {
  AVAudioSessionPort.headphones,
  AVAudioSessionPort.bluetoothA2dp,
  AVAudioSessionPort.bluetoothHfp,
  AVAudioSessionPort.bluetoothLe,
  AVAudioSessionPort.carAudio,
  AVAudioSessionPort.usbAudio,
  AVAudioSessionPort.airPlay,
  AVAudioSessionPort.lineOut,
  AVAudioSessionPort.hdmi,
};

/// iOS output override needed for the current route, or `null` when the
/// route is already right. Only a wrong route is touched: every override
/// reconfigures the audio hardware, and doing it again and again on each route
/// notification (mic start/stop, category changes) breaks up the playback
/// into short dropouts, heard as chirping.
///
/// Loudspeaker mode: move off the receiver if iOS fell back to it. Earpiece
/// mode: clear the override if the loudspeaker is playing. A headset or other
/// external device is left alone.
AVAudioSessionPortOverride? iosOverride({required bool speaker, required List<AVAudioSessionPort?> outputs}) {
  if (outputs.any(_externalPorts.contains)) return null;
  if (speaker && outputs.contains(AVAudioSessionPort.builtInReceiver)) return AVAudioSessionPortOverride.speaker;
  if (!speaker && outputs.contains(AVAudioSessionPort.builtInSpeaker)) return AVAudioSessionPortOverride.none;
  return null;
}

/// Android device types that count as a headset (they win over the choice).
bool isHeadset(AndroidAudioDeviceType t) => const {
      AndroidAudioDeviceType.wiredHeadset,
      AndroidAudioDeviceType.wiredHeadphones,
      AndroidAudioDeviceType.bluetoothSco,
      AndroidAudioDeviceType.bluetoothA2dp,
      AndroidAudioDeviceType.usbHeadset,
      AndroidAudioDeviceType.hearingAid,
    }.contains(t);

/// Estimates how much audio is still queued in the player, so keep-alive
/// silence keeps it from running dry (on iOS the output unit stops when empty
/// and cannot be restarted in the background) without piling up latency in
/// front of the next call. Corrected by the plugin's remaining-frames reports.
class PlayoutQueue {
  PlayoutQueue(this.rate, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final int rate;
  final DateTime Function() _clock;
  DateTime _until = DateTime.fromMillisecondsSinceEpoch(0);

  /// Top up when less than this is queued...
  int get lowWater => rate * 15 ~/ 100; // 150 ms
  /// ...with this much silence (keeps the queue, and call latency, under ~400 ms).
  int get block => rate * 25 ~/ 100; // 250 ms

  Duration _dur(int samples) => Duration(microseconds: samples * 1000000 ~/ rate);

  void fed(int samples) {
    final now = _clock();
    _until = (_until.isAfter(now) ? _until : now).add(_dur(samples));
  }

  void sync(int remainingSamples) => _until = _clock().add(_dur(remainingSamples));

  int queuedSamples() {
    final left = _until.difference(_clock());
    return left.isNegative ? 0 : left.inMicroseconds * rate ~/ 1000000;
  }

  /// Samples of silence to feed now (0 = enough queued).
  int silenceToFeed() => queuedSamples() < lowWater ? block : 0;
}

/// 16 kHz -> 8 kHz: windowed-sinc low-pass (cut-off 3.4 kHz) then keep every
/// second sample. Streaming: carries filter history between chunks.
class _Decimator2 {
  _Decimator2({this.level});

  /// Rumble and hum off before level control and encoder (both platforms).
  final _hp = HighPass();

  /// Background noise suppression, switched in the settings: speexdsp in the
  /// Rust core; the Dart [NoiseSuppressor] only where the core is not loaded
  /// (unit tests).
  Int16List Function(Int16List)? _ns;
  TxDenoiser? _speex;
  bool suppress = false;
  bool _suppressing = false; // fixed for one transmission

  /// Automatic level instead of the fixed built-in gain (the trim still applies).
  final TxLevel? level;

  static const _taps = 47;
  /// Built-in level (-4.4 dB); the user's trim is applied on top.
  static const _baseGain = 0.6;
  late double gain = level == null ? _baseGain : 1.0;

  void setTrimDb(double db) => gain = (level == null ? _baseGain : 1.0) * math.pow(10, db / 20).toDouble();
  final _lim = PeakLimiter();
  static final List<double> _h = _design();

  static List<double> _design() {
    const fc = 3400 / 16000; // cycles per input sample
    const m = (_taps - 1) / 2;
    final h = List<double>.generate(_taps, (n) {
      final x = n - m;
      final sinc = x == 0 ? 2 * fc : math.sin(2 * math.pi * fc * x) / (math.pi * x);
      final w = 0.54 - 0.46 * math.cos(2 * math.pi * n / (_taps - 1));
      return sinc * w;
    });
    final sum = h.fold<double>(0, (a, b) => a + b);
    // Unity DC gain; level is applied in [process] (phone mics run hot, and a
    // near-clipping input makes the ACELP encoder produce harsh beeps).
    return [for (final v in h) v / sum];
  }

  List<double> _hist = List<double>.filled(_taps - 1, 0);
  int _count = 0;

  void reset() {
    _lim.reset();
    level?.reset();
    _hp.reset();
    _speex?.dispose();
    _speex = null;
    _ns = null;
    _suppressing = suppress;
    if (_suppressing) _ns = _newDenoiser();
    _hist = List<double>.filled(_taps - 1, 0);
    _count = 0;
  }

  Int16List Function(Int16List) _newDenoiser() {
    try {
      final d = _speex = TxDenoiser();
      return (x) => d.process(pcm: x);
    } catch (_) {
      final ns = NoiseSuppressor();
      return (x) => Int16List.fromList([for (final v in x) ns.process(v.toDouble()).round().clamp(-32768, 32767)]);
    }
  }

  Int16List process(Int16List input) {
    final n = input.length;
    final c = List<double>.filled(_taps - 1 + n, 0);
    for (var i = 0; i < _taps - 1; i++) {
      c[i] = _hist[i];
    }
    for (var i = 0; i < n; i++) {
      c[_taps - 1 + i] = input[i].toDouble();
    }
    final hp = <double>[];
    for (var k = 0; k < n; k++) {
      if ((_count + k).isEven) {
        var y = 0.0;
        final base = _taps - 1 + k;
        for (var t = 0; t < _taps; t++) {
          y += _h[t] * c[base - t];
        }
        hp.add(_hp.process(y));
      }
    }
    _count += n;
    _hist = c.sublist(n);
    final ns = _ns;
    final List<num> clean = (_suppressing && ns != null && hp.isNotEmpty)
        ? ns(Int16List.fromList([for (final v in hp) v.round().clamp(-32768, 32767)]))
        : hp;
    return Int16List.fromList([
      for (final h in clean) _lim.process((level?.process(h.toDouble()) ?? h.toDouble()) * gain).round().clamp(-32768, 32767),
    ]);
  }

}
