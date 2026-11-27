import AVFoundation
import AudioToolbox
import CallKit
import Flutter
import UIKit
import UserNotifications

/// Channel "tetra/call": incoming private calls ring on the system call screen
/// (Lock Screen included) and are answered or declined there. Works while the
/// app is running, in front or in the background; a terminated app is not
/// woken up (that would need VoIP pushes).
///
/// App -> native: incoming, connected, ended, answer, end, message,
/// messagePermission, ringtones, preview.
/// Native -> app: answer, end, mute, dtmf, audio.
public final class TetraCallPlugin: NSObject, FlutterPlugin, CXProviderDelegate {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "tetra/call", binaryMessenger: registrar.messenger())
    let plugin = TetraCallPlugin(channel: channel)
    registrar.addMethodCallDelegate(plugin, channel: channel)
  }

  private let channel: FlutterMethodChannel
  private let controller = CXCallController()
  private var provider: CXProvider?
  /// Call id of the app -> CallKit call.
  private var calls: [String: UUID] = [:]
  private var answered: Set<String> = []
  private var player: AVAudioPlayer?

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  /// Created on first use, so the app does not register with CallKit while the
  /// feature is switched off.
  /// [ringtone]: a sound file of the app bundle, nil for the iPhone's ring tone.
  private func callProvider(ringtone: String?) -> CXProvider {
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = true
    if let name = ringtone, Bundle.main.url(forResource: name, withExtension: nil) != nil {
      config.ringtoneSound = name
    }
    if let p = provider {
      p.configuration = config
      return p
    }
    let p = CXProvider(configuration: config)
    p.setDelegate(self, queue: nil)
    provider = p
    return p
  }

  /// The ring tones found in the app bundle (ring_*.wav).
  private func bundledRingtones() -> [String] {
    (Bundle.main.urls(forResourcesWithExtension: "wav", subdirectory: nil) ?? [])
      .map { $0.lastPathComponent }
      .filter { $0.hasPrefix("ring_") }
      .sorted()
  }

  /// Plays a ring tone once, for choosing one in the settings.
  private func preview(_ name: String?) {
    player?.stop()
    player = nil
    guard let name = name, let url = Bundle.main.url(forResource: name, withExtension: nil) else { return }
    player = try? AVAudioPlayer(contentsOf: url)
    player?.play()
  }

  private func id(of uuid: UUID) -> String? {
    calls.first(where: { $0.value == uuid })?.key
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    let id = args["id"] as? String ?? ""
    switch call.method {
    case "incoming":
      let name = args["name"] as? String ?? ""
      let sub = args["sub"] as? String
      let update = CXCallUpdate()
      update.remoteHandle = CXHandle(type: .generic, value: sub ?? name)
      update.localizedCallerName = name
      update.hasVideo = false
      update.supportsHolding = false
      update.supportsGrouping = false
      update.supportsUngrouping = false
      update.supportsDTMF = args["duplex"] as? Bool ?? false
      let uuid = UUID()
      calls[id] = uuid
      player?.stop()
      callProvider(ringtone: args["ringtone"] as? String).reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
        DispatchQueue.main.async {
          if error != nil { self?.calls.removeValue(forKey: id) }
          // false: the system did not take the call (Do Not Disturb, blocked);
          // the app then shows it on its own.
          result(error == nil)
        }
      }
    case "connected":
      result(nil)
    case "ended":
      if let uuid = calls.removeValue(forKey: id) {
        let reason: CXCallEndedReason = answered.contains(id) ? .remoteEnded : .unanswered
        provider?.reportCall(with: uuid, endedAt: nil, reason: reason)
      }
      answered.remove(id)
      result(nil)
    case "answer":
      guard let uuid = calls[id] else { return result(false) }
      request(CXAnswerCallAction(call: uuid), result)
    case "end":
      guard let uuid = calls[id] else { return result(false) }
      request(CXEndCallAction(call: uuid), result)
    case "message":
      // A received text message: the tone alone while the app is on screen,
      // a notification with sound otherwise.
      if UIApplication.shared.applicationState == .active {
        AudioServicesPlaySystemSound(1007)
      } else {
        let content = UNMutableNotificationContent()
        content.title = args["title"] as? String ?? ""
        content.body = args["text"] as? String ?? ""
        content.sound = .default
        let peer = args["peer"] as? Int ?? 0
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sds-\(peer)", content: content, trigger: nil))
      }
      result(nil)
    case "messagePermission":
      UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
        DispatchQueue.main.async { result(granted) }
      }
    case "ringtones":
      result(bundledRingtones())
    case "preview":
      preview(args["name"] as? String)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func request(_ action: CXAction, _ result: @escaping FlutterResult) {
    controller.request(CXTransaction(action: action)) { error in
      DispatchQueue.main.async { result(error == nil) }
    }
  }

  // MARK: CXProviderDelegate

  public func providerDidReset(_ provider: CXProvider) {
    for id in calls.keys { channel.invokeMethod("end", arguments: id) }
    calls.removeAll()
    answered.removeAll()
  }

  public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    if let id = id(of: action.callUUID) {
      answered.insert(id)
      channel.invokeMethod("answer", arguments: id)
      action.fulfill()
    } else {
      action.fail()
    }
  }

  public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    if let id = id(of: action.callUUID) {
      calls.removeValue(forKey: id)
      answered.remove(id)
      channel.invokeMethod("end", arguments: id)
    }
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
    channel.invokeMethod("mute", arguments: action.isMuted)
    action.fulfill()
  }

  public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
    channel.invokeMethod("dtmf", arguments: action.digits)
    action.fulfill()
  }

  // The system owns the audio session during a call: the app starts its audio
  // when the session is handed over and takes it back when the call is over.
  public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    channel.invokeMethod("audio", arguments: true)
  }

  public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    channel.invokeMethod("audio", arguments: false)
  }
}
