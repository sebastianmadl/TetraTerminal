import AppIntents
import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island while connected.
/// Talking: talker, group and timer. Standby: server, own callsign and ISSI.
struct TetraLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TetraActivityAttributes.self) { context in
      LockScreenActivityView(status: context.state)
        .activitySystemActionForegroundColor(Palette.tint(context.state))
    } dynamicIsland: { context in
      let s = context.state
      let tint = Palette.tint(s)
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: Palette.symbol(s))
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 40, height: 40)
            .glass(tint, circle: true)
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let since = s.talkerSince {
            Text(since, style: .timer)
              .font(.title3.weight(.semibold))
              .monospacedDigit()
              .multilineTextAlignment(.trailing)
              .frame(width: 64, alignment: .trailing)
              .foregroundStyle(tint)
          } else {
            StatePill(status: s)
          }
        }
        DynamicIslandExpandedRegion(.center) {
          VStack(spacing: 1) {
            Text(s.talker ?? s.server).font(.headline).lineLimit(1)
            Text(s.talker == nil ? s.ownLine : s.group).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        DynamicIslandExpandedRegion(.bottom) {
          HStack(spacing: 10) {
            Text(s.talker == nil ? s.group : s.server)
              .font(.footnote)
              .foregroundStyle(.secondary)
              .lineLimit(1)
            Spacer(minLength: 4)
            PttButton(status: s, compact: false)
          }
          .padding(.horizontal, 6)
        }
      } compactLeading: {
        TwoLines(
          top: s.talker ?? s.server,
          bottom: s.group,
          topColor: s.talker == nil ? .primary : tint)
          .frame(maxWidth: 78, alignment: .leading)
      } compactTrailing: {
        if let since = s.talkerSince {
          VStack(alignment: .trailing, spacing: 0) {
            Text(since, style: .timer)
              .font(.system(size: 12, weight: .semibold))
              .monospacedDigit()
              .multilineTextAlignment(.trailing)
              .foregroundStyle(tint)
            Text(s.emergency ? "SOS" : (s.transmitting ? "TX" : "RX"))
              .font(.system(size: 10, weight: .bold))
              .foregroundStyle(.secondary)
          }
          .frame(width: 44, alignment: .trailing)
        } else {
          TwoLines(top: s.ownName?.isEmpty == false ? s.ownName! : "Standby",
                   bottom: s.ownIssi.map(String.init) ?? "",
                   topColor: .primary, alignment: .trailing)
            .frame(maxWidth: 78, alignment: .trailing)
        }
      } minimal: {
        Image(systemName: Palette.symbol(s)).foregroundStyle(tint)
      }
      .keylineTint(tint)
    }
  }
}

/// Two small lines for the compact Dynamic Island.
struct TwoLines: View {
  let top: String
  let bottom: String
  var topColor: Color = .primary
  var alignment: HorizontalAlignment = .leading

  var body: some View {
    VStack(alignment: alignment, spacing: 0) {
      Text(top).font(.system(size: 12, weight: .semibold)).foregroundStyle(topColor)
      if !bottom.isEmpty {
        Text(bottom).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
      }
    }
    .lineLimit(1)
    .minimumScaleFactor(0.8)
  }
}

/// "STANDBY" / "OFFLINE" next to the server name, like the status pills of iOS.
struct StatePill: View {
  let status: TetraStatus
  var body: some View {
    let online = status.online
    let tint = online ? Palette.accent : Color.gray
    Text(online ? "STANDBY" : "OFFLINE")
      .font(.system(size: 10, weight: .bold))
      .foregroundStyle(tint)
      .padding(.horizontal, 8)
      .padding(.vertical, 3)
      .glass(tint, circle: false)
  }
}

/// Tap to transmit, tap again to stop (Live Activity buttons cannot be held).
struct PttButton: View {
  let status: TetraStatus
  let compact: Bool

  var body: some View {
    if #available(iOS 17.0, *) {
      if status.transmitting || status.canTalk == true {
      let tint = status.transmitting ? Palette.talk : Palette.accent
      Button(intent: TogglePttIntent()) {
        HStack(spacing: 6) {
          Image(systemName: status.transmitting ? "stop.fill" : "mic.fill")
            .font(.system(size: compact ? 18 : 15, weight: .semibold))
          if !compact {
            if status.transmitting, let end = status.txEndsAt {
              Text(timerInterval: Date()...max(end, Date()), countsDown: true)
                .monospacedDigit()
                .frame(width: 40)
            } else {
              Text(status.transmitting ? "Stop" : "Talk")
            }
          }
        }
        .font(.system(size: 15, weight: .semibold))
        .foregroundStyle(status.transmitting ? Color.white : tint)
        .frame(width: compact ? 48 : nil, height: compact ? 48 : 36)
        .padding(.horizontal, compact ? 0 : 14)
        .background(status.transmitting ? tint : Color.clear, in: Capsule())
        .glass(tint, circle: compact)
      }
      .buttonStyle(.plain)
      }
    }
  }
}

extension View {
  /// Liquid Glass on iOS 26 (when built with the iOS 26 SDK), a tinted fill before.
  @ViewBuilder
  func glass(_ tint: Color, circle: Bool) -> some View {
    #if compiler(>=6.2)
    if #available(iOS 26.0, *) {
      if circle {
        self.glassEffect(.regular.tint(tint.opacity(0.25)).interactive(), in: Circle())
      } else {
        self.glassEffect(.regular.tint(tint.opacity(0.25)).interactive(), in: Capsule())
      }
    } else {
      fallbackGlass(tint, circle: circle)
    }
    #else
    fallbackGlass(tint, circle: circle)
    #endif
  }

  @ViewBuilder
  private func fallbackGlass(_ tint: Color, circle: Bool) -> some View {
    if circle {
      self.background(tint.opacity(0.18), in: Circle())
    } else {
      self.background(tint.opacity(0.18), in: Capsule())
    }
  }
}

struct LockScreenActivityView: View {
  let status: TetraStatus
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let tint = Palette.tint(status, dark: scheme == .dark)
    HStack(spacing: 12) {
      Image(systemName: Palette.symbol(status))
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(tint)
        .frame(width: 44, height: 44)
        .glass(tint, circle: true)
      VStack(alignment: .leading, spacing: 2) {
        if let talker = status.talker {
          Text(talker).font(.headline).lineLimit(1)
          Text(status.emergency ? "Emergency · \(status.group)" : "\(status.group) · \(status.server)")
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        } else {
          HStack(spacing: 6) {
            Text(status.server).font(.headline).lineLimit(1)
            StatePill(status: status)
          }
          Text([status.ownLine, status.group].filter { !$0.isEmpty }.joined(separator: " · "))
            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Spacer(minLength: 8)
      if let since = status.talkerSince {
        Text(since, style: .timer)
          .font(.title2.weight(.semibold))
          .monospacedDigit()
          .multilineTextAlignment(.trailing)
          .frame(width: 72, alignment: .trailing)
          .foregroundStyle(tint)
      }
      PttButton(status: status, compact: true)
    }
    .padding(16)
  }
}
