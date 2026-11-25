import ActivityKit
import SwiftUI
import WidgetKit

/// Lock Screen banner and Dynamic Island while connected.
struct TetraLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: TetraActivityAttributes.self) { context in
      LockScreenActivityView(status: context.state)
        .activitySystemActionForegroundColor(Palette.tint(context.state))
    } dynamicIsland: { context in
      let s = context.state
      return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          Image(systemName: Palette.symbol(s))
            .font(.title2.weight(.semibold))
            .foregroundStyle(Palette.tint(s))
            .padding(.leading, 4)
        }
        DynamicIslandExpandedRegion(.trailing) {
          if let since = s.talkerSince {
            Text(since, style: .timer)
              .font(.title3.weight(.semibold))
              .monospacedDigit()
              .multilineTextAlignment(.trailing)
              .frame(width: 64, alignment: .trailing)
              .foregroundStyle(Palette.tint(s))
          }
        }
        DynamicIslandExpandedRegion(.center) {
          Text(s.group).font(.headline).lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          Text(activitySubtitle(s)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
        }
      } compactLeading: {
        Image(systemName: Palette.symbol(s)).foregroundStyle(Palette.tint(s))
      } compactTrailing: {
        if let since = s.talkerSince {
          Text(since, style: .timer)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 42)
            .foregroundStyle(Palette.tint(s))
        } else {
          Text(s.group).lineLimit(1).frame(maxWidth: 72)
        }
      } minimal: {
        Image(systemName: Palette.symbol(s)).foregroundStyle(Palette.tint(s))
      }
      .keylineTint(Palette.tint(s))
    }
  }
}

func activitySubtitle(_ s: TetraStatus) -> String {
  if let talker = s.talker { return s.emergency ? "Emergency · \(talker)" : "\(talker) · \(s.server)" }
  return s.online ? s.server : "Reconnecting · \(s.server)"
}

struct LockScreenActivityView: View {
  let status: TetraStatus
  @Environment(\.colorScheme) private var scheme

  var body: some View {
    let tint = Palette.tint(status, dark: scheme == .dark)
    HStack(spacing: 12) {
      ZStack {
        Circle().fill(tint.opacity(0.16))
        Image(systemName: Palette.symbol(status))
          .font(.system(size: 18, weight: .semibold))
          .foregroundStyle(tint)
      }
      .frame(width: 44, height: 44)
      VStack(alignment: .leading, spacing: 2) {
        Text(status.group).font(.headline).lineLimit(1)
        Text(activitySubtitle(status)).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
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
    }
    .padding(16)
  }
}
