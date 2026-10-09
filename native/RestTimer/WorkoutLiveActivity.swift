import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RestTimerBundle: WidgetBundle {
    var body: some Widget { WorkoutLiveActivity() }
}

private let accent = Color(red: 0.49, green: 0.77, blue: 1.0)

struct WorkoutLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: WorkoutActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(isResting(context.state) ? "Rest" : context.attributes.name, systemImage: isResting(context.state) ? "timer" : "dumbbell.fill")
                        .font(.headline)
                        .foregroundStyle(accent)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ClockText(state: context.state, startedAt: context.attributes.startedAt)
                        .font(.system(.title2, design: .rounded).monospacedDigit().bold())
                        .multilineTextAlignment(.trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(subtitle(context.state))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } compactLeading: {
                Image(systemName: isResting(context.state) ? "timer" : "dumbbell.fill").foregroundStyle(accent)
            } compactTrailing: {
                ClockText(state: context.state, startedAt: context.attributes.startedAt)
                    .monospacedDigit()
                    .frame(maxWidth: 52)
                    .foregroundStyle(accent)
            } minimal: {
                Image(systemName: "timer").foregroundStyle(accent)
            }
        }
    }
}

private struct LockScreenView: View {
    let context: ActivityViewContext<WorkoutActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: isResting(context.state) ? "timer" : "dumbbell.fill")
                .font(.title2)
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(isResting(context.state) ? "Rest" : context.attributes.name)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(subtitle(context.state))
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            ClockText(state: context.state, startedAt: context.attributes.startedAt)
                .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(isResting(context.state) ? accent : .white)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 120, alignment: .trailing)
        }
        .padding(16)
    }
}

/// Counts the rest down while resting, otherwise counts the session up. Both tick on their own.
private struct ClockText: View {
    let state: WorkoutActivityAttributes.ContentState
    let startedAt: Date

    var body: some View {
        if let ends = state.restEnds, ends > Date() {
            Text(timerInterval: Date()...ends, countsDown: true)
        } else {
            Text(startedAt, style: .timer)
        }
    }
}

private func isResting(_ state: WorkoutActivityAttributes.ContentState) -> Bool {
    if let ends = state.restEnds { return ends > Date() }
    return false
}

private func subtitle(_ state: WorkoutActivityAttributes.ContentState) -> String {
    if !state.next.isEmpty { return "Next: \(state.next)" }
    return "\(state.setsDone) set\(state.setsDone == 1 ? "" : "s") done"
}
