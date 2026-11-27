import AVFoundation
import Flutter

/// Microphone capture with AVAudioEngine.
///
/// Channel "tetra/mic": hasPermission, start {sampleRate, voiceProcessing},
/// play {pcm, sampleRate}, stop. Event channel "tetra/mic/pcm": mono PCM16
/// chunks at sampleRate.
///
/// With voice processing (full-duplex calls) the received audio is played
/// through the same engine ("play"): the echo canceller of the voice
/// processing unit only removes what goes out through that unit, so audio
/// played by another output unit came straight back into the microphone.
///
/// The tap and the converter are rebuilt whenever the engine reports a
/// configuration change (route or output override, hardware sample rate,
/// interruption) or a buffer arrives in a format other than the one the
/// converter was made for. Such buffers are dropped, never converted with the
/// wrong format: misread samples turn into a loud tone after the ACELP
/// encoder. The audio session itself (category, mode, route) is owned by the
/// Flutter side and not touched here.
public class TetraMicPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var sink: FlutterEventSink?
  private var engine: AVAudioEngine?
  private var converter: AVAudioConverter?
  private var outFormat: AVAudioFormat?
  private var rate: Double = 16000
  private var voiceProcessing = false
  private var observers: [NSObjectProtocol] = []
  /// Set from the audio thread when a buffer's format no longer matches.
  private var stale = false
  private var restartPending = false
  /// Plays the received audio during full-duplex calls (voice processing only).
  private var player: AVAudioPlayerNode?
  private var playFormat: AVAudioFormat?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = TetraMicPlugin()
    let methods = FlutterMethodChannel(name: "tetra/mic", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    let events = FlutterEventChannel(name: "tetra/mic/pcm", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "hasPermission":
      let session = AVAudioSession.sharedInstance()
      switch session.recordPermission {
      case .granted:
        result(true)
      case .denied:
        result(false)
      default:
        session.requestRecordPermission { ok in DispatchQueue.main.async { result(ok) } }
      }
    case "start":
      let a = call.arguments as? [String: Any] ?? [:]
      rate = (a["sampleRate"] as? NSNumber)?.doubleValue ?? 16000
      voiceProcessing = a["voiceProcessing"] as? Bool ?? false
      do {
        try start()
        result(nil)
      } catch {
        stop()
        result(FlutterError(code: "mic", message: "Microphone start failed: \(error.localizedDescription)", details: nil))
      }
    case "play":
      let a = call.arguments as? [String: Any] ?? [:]
      if let pcm = a["pcm"] as? FlutterStandardTypedData {
        play(pcm.data, sampleRate: (a["sampleRate"] as? NSNumber)?.doubleValue ?? 48000)
      }
      result(nil)
    case "stop":
      stop()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private enum MicError: LocalizedError {
    case noInput, badFormat
    var errorDescription: String? {
      switch self {
      case .noInput: return "no audio input available"
      case .badFormat: return "unsupported format"
      }
    }
  }

  private func start() throws {
    stop()
    let engine = AVAudioEngine()
    self.engine = engine
    if voiceProcessing {
      try? engine.inputNode.setVoiceProcessingEnabled(true)
    }
    try installTap()
    if voiceProcessing {
      let node = AVAudioPlayerNode()
      engine.attach(node)
      player = node
      connectPlayer()
    }
    engine.prepare()
    try engine.start()
    player?.play()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
      self?.restart()
    })
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
      guard let raw = n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
            AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
      self?.restart()
    })
  }

  /// (Re)installs the tap in the input's current format with a matching converter.
  private func installTap() throws {
    guard let engine = engine else { return }
    let input = engine.inputNode
    input.removeTap(onBus: 0)
    let src = input.outputFormat(forBus: 0)
    guard src.sampleRate > 0, src.channelCount > 0 else { throw MicError.noInput }
    guard let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true),
          let conv = AVAudioConverter(from: src, to: dst) else { throw MicError.badFormat }
    if src.channelCount > 1 { conv.channelMap = [0] }
    conv.sampleRateConverterQuality = AVAudioQuality.high.rawValue
    converter = conv
    outFormat = dst
    stale = false
    input.installTap(onBus: 0, bufferSize: 1024, format: src) { [weak self] buffer, _ in
      self?.process(buffer, conv, dst)
    }
  }

  private func restart() {
    restartPending = false
    guard let engine = engine else { return }
    engine.stop()
    do {
      try installTap()
      connectPlayer()
      engine.prepare()
      try engine.start()
      player?.play()
    } catch {
      sink?(FlutterError(code: "mic", message: "Microphone restart failed: \(error.localizedDescription)", details: nil))
    }
  }

  /// Connects the player to the mixer (again after a configuration change).
  private func connectPlayer() {
    guard let engine = engine, let node = player else { return }
    let rate = playFormat?.sampleRate ?? 48000
    guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1) else { return }
    playFormat = format
    engine.disconnectNodeOutput(node)
    engine.connect(node, to: engine.mainMixerNode, format: format)
  }

  /// Queues mono PCM16 for playback behind what is already queued.
  private func play(_ data: Data, sampleRate: Double) {
    guard let engine = engine, let node = player else { return }
    if playFormat?.sampleRate != sampleRate {
      playFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)
      connectPlayer()
    }
    guard let format = playFormat else { return }
    let frames = data.count / MemoryLayout<Int16>.size
    guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
          let out = buffer.floatChannelData?[0] else { return }
    buffer.frameLength = AVAudioFrameCount(frames)
    data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      for i in 0..<frames { out[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768 }
    }
    node.scheduleBuffer(buffer, completionHandler: nil)
    if engine.isRunning && !node.isPlaying { node.play() }
  }

  /// Audio thread: convert one buffer and hand it to Flutter.
  private func process(_ buffer: AVAudioPCMBuffer, _ conv: AVAudioConverter, _ dst: AVAudioFormat) {
    if stale { return }
    guard buffer.format == conv.inputFormat else {
      stale = true
      DispatchQueue.main.async { [weak self] in
        guard let self = self, !self.restartPending else { return }
        self.restartPending = true
        self.restart()
      }
      return
    }
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * dst.sampleRate / buffer.format.sampleRate) + 64
    guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return }
    var fed = false
    var error: NSError?
    let status = conv.convert(to: out, error: &error) { _, outStatus in
      if fed {
        outStatus.pointee = .noDataNow
        return nil
      }
      fed = true
      outStatus.pointee = .haveData
      return buffer
    }
    guard status != .error, error == nil, out.frameLength > 0, let ch = out.int16ChannelData else { return }
    let data = Data(bytes: ch[0], count: Int(out.frameLength) * MemoryLayout<Int16>.size)
    DispatchQueue.main.async { [weak self] in
      self?.sink?(FlutterStandardTypedData(bytes: data))
    }
  }

  private func stop() {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers = []
    if let engine = engine {
      engine.inputNode.removeTap(onBus: 0)
      player?.stop()
      engine.stop()
      if let node = player { engine.detach(node) }
      if voiceProcessing {
        try? engine.inputNode.setVoiceProcessingEnabled(false)
      }
    }
    engine = nil
    player = nil
    playFormat = nil
    converter = nil
    outFormat = nil
  }
}
