import SwiftUI

/// The workouts a workout sticker can be made from (19 Nov): today's, then the last two weeks', newest first.
struct WorkoutStickerPicker: View {
    var pick: (JSON) -> Void
    @Environment(\.dismiss) private var dismiss

    /// Each workout with the day it was on.
    static func recent() -> [(day: String, workout: JSON)] {
        let s = Store.shared
        var out: [(day: String, workout: JSON)] = s.todayWorkouts.reversed().map { (s.today, $0) }
        let since = DayKey.shift(s.today, days: -14)
        for h in list(s.doc["history"]) where str(h["date"]) >= since && str(h["date"]) != s.today {
            for w in list(h["workouts"]).reversed() { out.append((str(h["date"]), w)) }
        }
        return out
    }

    var body: some View {
        let all = Self.recent()
        NavigationStack {
            List {
                if all.isEmpty { Text("Finish a workout to share it as a sticker.").foregroundStyle(.secondary) }
                ForEach(all.indices, id: \.self) { i in
                    let w = all[i].workout, sticker = StoryItem.workoutSticker(w)
                    Button { pick(sticker); dismiss() } label: {
                        HStack(spacing: 12) {
                            Text("🏋️").font(.title3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(str(sticker["name"])).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                                Text(Self.line(sticker, day: all[i].day)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Workout sticker").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private static func line(_ o: JSON, day: String) -> String {
        var bits = [day == Store.shared.today ? "Today" : DayKey.date(day).formatted(.dateTime.weekday(.wide).day())]
        if let m = num(o["minutes"]), m > 0 { bits.append("\(Int(m)) min") }
        if let n = num(o["n"]), n > 0 { bits.append("\(Int(n)) exercises") }
        if let kg = num(o["kg"]), kg > 0 { bits.append(Fmt.int(kg) + " kg") }
        return bits.joined(separator: " · ")
    }
}
