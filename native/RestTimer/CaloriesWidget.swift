import SwiftUI
import WidgetKit

private let accent = Color(red: 0.49, green: 0.77, blue: 1.0)
private let warn = Color(red: 0.95, green: 0.71, blue: 0.36)
private let bg = Color(red: 0.06, green: 0.10, blue: 0.15)

struct CaloriesEntry: TimelineEntry {
    let date: Date
    let snap: TodaySnapshot
}

/// Today's numbers from the app; at midnight the widget turns over to a fresh day on its own.
struct CaloriesProvider: TimelineProvider {
    func placeholder(in context: Context) -> CaloriesEntry { CaloriesEntry(date: Date(), snap: .placeholder) }
    func getSnapshot(in context: Context, completion: @escaping (CaloriesEntry) -> Void) {
        completion(CaloriesEntry(date: Date(), snap: TodaySnapshot.load() ?? .placeholder))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<CaloriesEntry>) -> Void) {
        let now = Date()
        var snap = TodaySnapshot.load() ?? .placeholder
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        // numbers from an earlier day: it's a new day now, nothing eaten yet
        if !snap.date.isEmpty, snap.date != f.string(from: now) { snap = fresh(snap, on: now, f) }
        var entries = [CaloriesEntry(date: now, snap: snap)]
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86400))
        entries.append(CaloriesEntry(date: midnight, snap: fresh(snap, on: midnight, f)))
        completion(Timeline(entries: entries, policy: .after(midnight.addingTimeInterval(60))))
    }
    private func fresh(_ s: TodaySnapshot, on day: Date, _ f: DateFormatter) -> TodaySnapshot {
        var n = s
        n.date = f.string(from: day); n.budget = s.tomorrowBudget; n.eaten = 0; n.protein = 0; n.cheatToday = false
        return n
    }
}

struct CaloriesWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CaloriesLeft", provider: CaloriesProvider()) { e in
            CaloriesWidgetView(snap: e.snap)
                .containerBackground(for: .widget) { bg }
                .widgetURL(URL(string: "cheatdays://add"))
        }
        .configurationDisplayName("Calories left")
        .description("What's left of today's budget, and your protein. Tap to add food.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct CaloriesWidgetView: View {
    let snap: TodaySnapshot
    @Environment(\.widgetFamily) private var family

    private var over: Bool { snap.left < 0 }
    private var tint: Color { over ? warn : accent }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: snap.share) {
                Text("kcal")
            } currentValueLabel: {
                Text(short(abs(snap.left))).font(.system(size: 13, weight: .heavy, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text(over ? "Over today" : "Left to eat").font(.caption2.weight(.semibold))
                Text("\(Int(abs(snap.left).rounded())) kcal").font(.headline.weight(.heavy))
                Gauge(value: snap.share) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }
        case .accessoryInline:
            Text(over ? "\(Int(-snap.left)) kcal over" : "\(Int(snap.left)) kcal left")
        case .systemMedium:
            HStack(spacing: 16) {
                main
                VStack(alignment: .leading, spacing: 8) {
                    stat("\(Int(snap.eaten.rounded()))", "eaten of \(Int(snap.budget.rounded()))")
                    stat(snap.proteinGoal.map { "\(Int(snap.protein))/\(Int($0))g" } ?? "\(Int(snap.protein))g", "protein")
                    if let c = snap.cheatDayName { stat(snap.cheatToday ? "Today" : c, "cheat day 🍕") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        default:
            main
        }
    }

    private var main: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(over ? "OVER TODAY" : "LEFT TO EAT").font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(Color(red: 0.56, green: 0.73, blue: 0.87))
            Text("\(Int(abs(snap.left).rounded()))").font(.system(size: 36, weight: .heavy, design: .rounded)).foregroundStyle(.white).minimumScaleFactor(0.6).lineLimit(1)
            Text("kcal").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(tint).frame(width: max(6, g.size.width * snap.share))
                }
            }
            .frame(height: 7)
            if family == .systemSmall, let goal = snap.proteinGoal {
                Text("\(Int(snap.protein))/\(Int(goal))g protein").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
    }

    private func stat(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(v).font(.subheadline.weight(.heavy)).foregroundStyle(.white).monospacedDigit()
            Text(l).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func short(_ v: Double) -> String { v >= 1000 ? String(format: "%.1fk", v / 1000) : "\(Int(v.rounded()))" }
}
