import Foundation
import WidgetKit

/// Keeps the home-screen widget's numbers in step with today, without asking it to redraw more than it needs to.
@MainActor
enum WidgetBridge {
    private static var last: TodaySnapshot?

    static func update(_ store: Store) {
        let wd = store.cheatWeekday
        let snap = TodaySnapshot(
            date: store.today, budget: store.budgetToday, eaten: store.eaten, protein: store.macros(store.todayItems).p,
            proteinGoal: store.proteinGoal, tomorrowBudget: store.baseBudget(DayKey.shift(store.today, days: 1)),
            cheatDayName: wd.map { Calendar.current.weekdaySymbols[$0] }, cheatToday: wd == DayKey.weekday(store.today))
        guard snap != last else { return }
        last = snap
        snap.save()
        WidgetCenter.shared.reloadTimelines(ofKind: "CaloriesLeft")
    }
}
