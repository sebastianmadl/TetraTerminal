import AVFoundation
import CallKit
import Flutter
import UIKit

/// Channel "tetra/call": incoming private calls ring on the system call screen
/// (Lock Screen included) and are answered or declined there. Works while the
/// app is running, in front or in the background; a terminated app is not
/// woken up (that would need VoIP pushes).
///
/// App -> native: incoming, connected, ended, answer, end.
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

  init(channel: FlutterMethodChannel) {
    self.channel = channel
    super.init()
  }

  /// Created on first use, so the app does not register with CallKit while the
  /// feature is switched off.
  private func callProvider() -> CXProvider {
    if let p = provider { return p }
    let config = CXProviderConfiguration()
    config.supportsVideo = false
    config.maximumCallGroups = 1
    config.maximumCallsPerCallGroup = 1
    config.supportedHandleTypes = [.generic]
    config.includesCallsInRecents = true
    let p = CXProvider(configuration: config)
    p.setDelegate(self, queue: nil)
    provider = p
    return p
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
      callProvider().reportNewIncomingCall(with: uuid, update: update) { [weak self] error in
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
