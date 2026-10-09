import Foundation

/// One of the website's achievements: earned when its stat reaches the target (or, for one-offs, becomes true).
struct Badge: Identifiable {
    let id: String
    let group: String
    let stat: String
    let icon: String
    let name: String
    let target: Double      // 0 for one-offs
    let how: String
    let xp: Int

    static let groups = ["Logging", "Budget", "Nutrition", "Workouts", "Body", "Social", "Level up"]

    private static func B(_ id: String, _ group: String, _ stat: String, _ icon: String, _ name: String, _ target: Double, _ how: String, _ xp: Int) -> Badge {
        Badge(id: id, group: group, stat: stat, icon: icon, name: name, target: target, how: how, xp: xp)
    }

    /// Generated from app.js's BADGES, in the same order.
    static let all: [Badge] = [
        B("first", "Logging", "daysLogged", "🌱", "First bite", 1, "Log your first day", 25),
        B("days10", "Logging", "daysLogged", "📒", "Getting the hang", 10, "Log 10 days", 50),
        B("days50", "Logging", "daysLogged", "📚", "Habit formed", 50, "Log 50 days", 100),
        B("days100", "Logging", "daysLogged", "💯", "Centurion", 100, "Log 100 days", 200),
        B("days250", "Logging", "daysLogged", "🗂️", "Record keeper", 250, "Log 250 days", 400),
        B("streak3", "Logging", "streak", "✨", "Warming up", 3, "Log 3 days in a row", 25),
        B("streak7", "Logging", "streak", "🔥", "One week", 7, "Log 7 days in a row", 50),
        B("streak14", "Logging", "streak", "🔥", "Fortnight", 14, "Log 14 days in a row", 100),
        B("streak30", "Logging", "streak", "🏆", "One month", 30, "Log 30 days in a row", 200),
        B("streak100", "Logging", "streak", "🌋", "Unstoppable", 100, "Log 100 days in a row", 400),
        B("streak365", "Logging", "streak", "👑", "A whole year", 365, "Log 365 days in a row", 800),
        B("early", "Logging", "earlyBird", "🌅", "Early bird", 0, "Log something before 8am", 50),
        B("owl", "Logging", "nightOwl", "🦉", "Night owl", 0, "Log something after 10pm", 50),
        B("comeback", "Logging", "comeback", "🔁", "Comeback", 0, "Start logging again after a week off", 50),
        B("rest1", "Logging", "rests", "🛋️", "Rest day", 1, "Use a rest day without breaking your streak", 25),
        B("under3", "Budget", "under", "🎯", "On target", 3, "3 days under budget in a row", 25),
        B("under7", "Budget", "under", "🎯", "Bullseye week", 7, "7 days under budget in a row", 50),
        B("under14", "Budget", "under", "💎", "Iron will", 14, "14 days under budget in a row", 100),
        B("under30", "Budget", "under", "🧊", "Ice cold", 30, "30 days under budget in a row", 200),
        B("ud10", "Budget", "underDays", "🟢", "Ten good days", 10, "10 days under budget", 25),
        B("ud50", "Budget", "underDays", "🌿", "Fifty good days", 50, "50 days under budget", 50),
        B("ud100", "Budget", "underDays", "🌳", "Hundred good days", 100, "100 days under budget", 100),
        B("cheat1", "Budget", "overDays", "🍰", "It's a cheat day", 1, "Go over budget once. It happens!", 25),
        B("protein5", "Nutrition", "proteinDays", "🥩", "Protein pro", 5, "Hit your protein goal 5 times", 25),
        B("protein20", "Nutrition", "proteinDays", "🍗", "Protein machine", 20, "Hit your protein goal 20 times", 50),
        B("protein50", "Nutrition", "proteinDays", "🦾", "Built different", 50, "Hit your protein goal 50 times", 100),
        B("foods25", "Nutrition", "foods", "🥗", "Explorer", 25, "Log 25 different foods", 25),
        B("foods100", "Nutrition", "foods", "🌍", "Adventurous eater", 100, "Log 100 different foods", 50),
        B("scan1", "Nutrition", "scans", "🔍", "Scanner", 1, "Scan a barcode or label", 25),
        B("scan25", "Nutrition", "scans", "📷", "Label reader", 25, "Scan 25 barcodes or labels", 50),
        B("photo1", "Nutrition", "photos", "🖼️", "Food photographer", 1, "Add a photo to something you log", 25),
        B("photo25", "Nutrition", "photos", "🎞️", "Food diary", 25, "Log 25 things with photos", 50),
        B("meal1", "Nutrition", "meals", "🍲", "Home cook", 1, "Save a meal", 25),
        B("meal10", "Nutrition", "meals", "👩‍🍳", "Recipe book", 10, "Save 10 meals", 50),
        B("recipe1", "Nutrition", "recipes", "📝", "Chef's notes", 1, "Save a meal with method steps", 25),
        B("ask1", "Nutrition", "askItems", "💬", "Just ask", 1, "Log something through the assistant", 25),
        B("wo1", "Workouts", "workouts", "👟", "Moved", 1, "Log a workout", 25),
        B("wo10", "Workouts", "workouts", "💪", "Ten strong", 10, "Log 10 workouts", 50),
        B("wo25", "Workouts", "workouts", "🏃", "Regular", 25, "Log 25 workouts", 100),
        B("wo50", "Workouts", "workouts", "🏋️", "Gym rat", 50, "Log 50 workouts", 200),
        B("wo100", "Workouts", "workouts", "🥇", "Hundred club", 100, "Log 100 workouts", 400),
        B("min600", "Workouts", "workoutMins", "⏱️", "Ten hours in", 600, "Train for 10 hours in total", 25),
        B("min3000", "Workouts", "workoutMins", "⏳", "Fifty hours in", 3000, "Train for 50 hours in total", 50),
        B("burn10k", "Workouts", "burned", "🔥", "Furnace", 10000, "Burn 10,000 kcal in workouts", 25),
        B("pb", "Workouts", "pbs", "🥇", "New best", 1, "Beat a lifting PB", 25),
        B("pb10", "Workouts", "pbs", "📈", "Getting stronger", 10, "Beat 10 lifting PBs", 50),
        B("pb25", "Workouts", "pbs", "🦍", "Beast mode", 25, "Beat 25 lifting PBs", 100),
        B("routine1", "Workouts", "routines", "📋", "Creature of habit", 1, "Save a workout routine", 25),
        B("weekend", "Workouts", "weekendWorkout", "🗓️", "Weekend warrior", 0, "Work out on a Saturday and the Sunday after", 50),
        B("weigh1", "Body", "weighins", "⚖️", "Stepped on", 1, "Record a weigh-in", 25),
        B("weigh10", "Body", "weighins", "📉", "Tracking it", 10, "Record 10 weigh-ins", 50),
        B("weigh50", "Body", "weighins", "📊", "Data driven", 50, "Record 50 weigh-ins", 100),
        B("goalset", "Body", "goalSet", "🏁", "Eyes on the prize", 0, "Set a goal weight", 50),
        B("lost1", "Body", "lost", "🪶", "First kilo", 1, "Lose 1 kg", 25),
        B("lost5", "Body", "lost", "🎈", "Five down", 5, "Lose 5 kg", 50),
        B("lost10", "Body", "lost", "🚀", "Ten down", 10, "Lose 10 kg", 100),
        B("goalhit", "Body", "goalReached", "🎉", "Made it", 0, "Reach your goal weight", 50),
        B("friend1", "Social", "friends", "🤝", "Buddy up", 1, "Add a friend", 25),
        B("friend5", "Social", "friends", "👥", "The crew", 5, "Have 5 friends", 50),
        B("post1", "Social", "posts", "📸", "Shared", 1, "Post to the feed", 25),
        B("post10", "Social", "posts", "🌟", "Influencer", 10, "Post 10 times", 50),
        B("post50", "Social", "posts", "📣", "Celebrity chef", 50, "Post 50 times", 100),
        B("react10", "Social", "reacts", "❤️", "Hype squad", 10, "React to 10 posts", 25),
        B("comment10", "Social", "comments", "💭", "Chatterbox", 10, "Leave 10 comments", 25),
        B("send1", "Social", "sends", "🎁", "Sharing is caring", 1, "Send food to a friend", 25),
        B("lvl5", "Level up", "level", "👑", "Level 5", 5, "Reach level 5", 25),
        B("lvl10", "Level up", "level", "🏅", "Level 10", 10, "Reach level 10", 50),
        B("lvl20", "Level up", "level", "🌠", "Level 20", 20, "Reach level 20", 100),
        B("goal", "Level up", "weeklyWins", "✅", "Goal getter", 1, "Finish a weekly goal", 25),
        B("goal10", "Level up", "weeklyWins", "📆", "Consistent", 10, "Finish 10 weekly goals", 50),
        B("goal50", "Level up", "weeklyWins", "🗓️", "Relentless", 50, "Finish 50 weekly goals", 100),
        B("perfect1", "Level up", "perfectWeeks", "💫", "Perfect week", 1, "Finish every weekly goal in one week", 25),
        B("perfect5", "Level up", "perfectWeeks", "🌈", "Perfect month", 5, "Have 5 perfect weeks", 50),
    ]

    func earned(_ stats: [String: Double]) -> Bool { target > 0 ? (stats[stat] ?? 0) >= target : (stats[stat] ?? 0) > 0 }
}

/// The weekly goals (the website's GOAL_DEFS).
struct WeekGoal { let key: String; let name: String; let symbol: String; let max: Int }

extension Store {
    static let weekGoalDefs = [
        WeekGoal(key: "under", name: "Days under budget", symbol: "target", max: 7),
        WeekGoal(key: "protein", name: "Days hitting protein", symbol: "fork.knife", max: 7),
        WeekGoal(key: "workouts", name: "Workouts", symbol: "dumbbell.fill", max: 14),
        WeekGoal(key: "log", name: "Days logged", symbol: "pencil", max: 7)
    ]

    var weekGoals: [String: Int] {
        let g = dict(doc["weekGoals"])
        if g.isEmpty { return ["under": 5, "protein": 4, "workouts": 3, "log": 7] }
        return g.compactMapValues { num($0).map { Int($0) } }
    }

    /// The goals that count: protein only when there's a protein goal.
    var activeWeekGoals: [WeekGoal] { Self.weekGoalDefs.filter { (weekGoals[$0.key] ?? 0) > 0 && ($0.key != "protein" || proteinGoal != nil) } }

    struct DayFacts { let logged: Bool; let kcal: Double; let budget: Double; let p: Double; let workouts: Int }

    /// A day's facts, like the website's dayFacts.
    func dayFacts(_ date: String) -> DayFacts {
        if date == today {
            return DayFacts(logged: !todayItems.isEmpty, kcal: todayItems.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, budget: budgetToday, p: macros(todayItems).p, workouts: todayWorkouts.count)
        }
        if str(day["date"]) == date, let pd = pastDay(date) {
            return DayFacts(logged: !pd.items.isEmpty, kcal: pd.kcal, budget: pd.budget, p: macros(pd.items).p, workouts: list(day["workouts"]).count)
        }
        guard let h = list(doc["history"]).first(where: { str($0["date"]) == date }) else { return DayFacts(logged: false, kcal: 0, budget: 0, p: 0, workouts: 0) }
        let items = list(h["items"])
        return DayFacts(logged: !items.isEmpty || (num(h["kcal"]) ?? 0) > 0, kcal: num(h["kcal"]) ?? 0, budget: num(h["budget"]) ?? 0, p: num(h["p"]) ?? 0, workouts: list(h["workouts"]).count)
    }
    func underBudget(_ d: DayFacts) -> Bool { d.logged && d.budget > 0 && d.kcal <= d.budget }
    func hitProtein(_ d: DayFacts) -> Bool { d.logged && (proteinGoal ?? 0) > 0 && d.p >= (proteinGoal ?? 0) }

    var weekDates: [String] { let mon = WorkoutPlan.monday(today); return (0..<7).map { DayKey.shift(mon, days: $0) }.filter { $0 <= today } }

    var weekProgress: [String: Int] {
        let days = weekDates.map(dayFacts)
        return ["under": days.filter(underBudget).count, "protein": days.filter(hitProtein).count,
                "workouts": days.reduce(0) { $0 + $1.workouts }, "log": days.filter(\.logged).count]
    }

    /// Days logged in a row; one missed day a week is a free rest day (never two misses in a row). The website's streakInfo.
    var streakInfo: (days: Int, rests: [String]) {
        var n = 0, lastRest = false, rests: [String] = []
        var i = dayFacts(today).logged ? 0 : 1
        while i < 400 {
            let d = DayKey.shift(today, days: -i)
            if dayFacts(d).logged { n += 1; lastRest = false; i += 1; continue }
            let wk = WorkoutPlan.monday(d)
            if !lastRest && n > 0 && !rests.contains(where: { WorkoutPlan.monday($0) == wk }) { rests.append(d); lastRest = true; i += 1; continue }
            if !lastRest && n == 0 && i == 1 && rests.isEmpty { rests.append(d); lastRest = true; i += 1; continue }
            break
        }
        while let last = rests.last, last == DayKey.shift(today, days: -(i - 1)) { rests.removeLast() }
        return (n, rests)
    }

    var underStreak: Int {
        var n = 0
        for i in 1..<400 { if underBudget(dayFacts(DayKey.shift(today, days: -i))) { n += 1 } else { break } }
        return n
    }

    /// Everything the achievements count, like the website's badgeStats.
    var badgeStats: [String: Double] {
        cached("badgeStats") {
            let hist = list(doc["history"]).map { (date: str($0["date"]), f: dayFacts(str($0["date"]))) }
            let staleItems = str(day["date"]) != today ? list(day["items"]) : []
            let allItems = list(doc["history"]).flatMap { list($0["items"]) } + staleItems + todayItems
            let allWorkouts = list(doc["history"]).flatMap { list($0["workouts"]) } + (str(day["date"]) != today ? list(day["workouts"]) : []) + todayWorkouts
            let weights = bodyRows.compactMap { pos($0["weight"]) }
            let wins = (doc["goalWins"] as? [String]) ?? []
            var byWeek: [String: Int] = [:]; for w in wins { byWeek[String(w.split(separator: ":").first ?? ""), default: 0] += 1 }
            let active = max(1, activeWeekGoals.count)
            let loggedDates = (hist.filter { $0.f.logged }.map(\.date) + (dayFacts(today).logged ? [today] : [])).sorted()
            var comeback = false
            for i in loggedDates.indices.dropFirst() {
                let gap = Calendar.current.dateComponents([.day], from: DayKey.date(loggedDates[i - 1]), to: DayKey.date(loggedDates[i])).day ?? 0
                if gap >= 7 { comeback = true }
            }
            let hours = allItems.compactMap { ISO.date(str($0["addedAt"])).map { Calendar.current.component(.hour, from: $0) } }
            var workoutDays = Set(list(doc["history"]).filter { !list($0["workouts"]).isEmpty }.map { str($0["date"]) })
            if !todayWorkouts.isEmpty { workoutDays.insert(today) }
            let weekend = workoutDays.contains { DayKey.weekday($0) == 6 && workoutDays.contains(DayKey.shift($0, days: 1)) }
            let goalW = pos(doc["goalWeight"])
            let saved = list(doc["meals"]).filter { $0["saved"] as? Bool == true }
            let b = { (x: Bool) -> Double in x ? 1 : 0 }
            let si = streakInfo
            return [
                "daysLogged": Double(loggedDates.count), "streak": Double(si.days), "under": Double(underStreak),
                "underDays": Double(hist.filter { underBudget($0.f) }.count),
                "overDays": Double(hist.filter { $0.f.logged && $0.f.budget > 0 && $0.f.kcal > $0.f.budget }.count),
                "proteinDays": Double(hist.filter { hitProtein($0.f) }.count),
                "workouts": Double(allWorkouts.count), "workoutMins": allWorkouts.reduce(0) { $0 + (num($1["minutes"]) ?? 0) },
                "burned": allWorkouts.reduce(0) { $0 + (num($1["kcal"]) ?? 0) }, "pbs": num(doc["pbCount"]) ?? 0,
                "routines": Double(routines.count), "weekendWorkout": b(weekend),
                "weighins": Double(weights.count), "lost": weights.count > 1 ? max(0, weights[0] - weights[weights.count - 1]) : 0,
                "goalSet": b(goalW != nil), "goalReached": b(goalW != nil && !weights.isEmpty && abs((weights.last ?? 0) - (goalW ?? 0)) < 0.25),
                "posts": num(doc["postCount"]) ?? 0, "reacts": num(doc["reactCount"]) ?? 0, "comments": num(doc["commentCount"]) ?? 0,
                "sends": num(doc["sendCount"]) ?? 0, "friends": num(doc["friendCount"]) ?? 0,
                "meals": Double(saved.count), "recipes": Double(saved.filter { !((($0["steps"] as? [Any]) ?? []).isEmpty) }.count),
                "foods": Double(Set(allItems.map { str($0["name"]).lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }).count),
                "scans": Double(allItems.filter { ["barcode", "label"].contains(str($0["source"])) }.count),
                "photos": Double(allItems.filter { !str($0["photo"]).isEmpty }.count),
                "askItems": Double(allItems.filter { str($0["source"]) == "claude" }.count),
                "earlyBird": b(hours.contains { $0 < 8 }), "nightOwl": b(hours.contains { $0 >= 22 }), "comeback": b(comeback),
                "level": Double(Rank.level(for: totalXP)), "weeklyWins": Double(wins.count),
                "perfectWeeks": Double(byWeek.values.filter { $0 >= active }.count), "rests": Double(si.rests.count)
            ]
        }
    }

    var seenBadges: Set<String> { Set((doc["seenBadges"] as? [String]) ?? []) }

    /// Bank this week's finished goals and award new achievements, as the website's checkBadges does.
    /// Returns what was newly earned, for a note on screen.
    @discardableResult
    func checkBadges() -> [Badge] {
        guard lastSynced != nil else { return [] }
        let wk = weekDates.first ?? today, prog = weekProgress, goals = weekGoals
        let have = Set((doc["goalWins"] as? [String]) ?? [])
        let banked = activeWeekGoals.filter { (prog[$0.key] ?? 0) >= (goals[$0.key] ?? 0) }.map { "\(wk):\($0.key)" }.filter { !have.contains($0) }
        if !banked.isEmpty { perform(["type": "goalWins", "keys": banked], syncAfter: 2) }
        var fresh: [Badge] = []
        for _ in 0..<3 {   // level badges can unlock from badge XP
            let seen = seenBadges, stats = badgeStats
            let more = Badge.all.filter { !seen.contains($0.id) && $0.earned(stats) }
            if more.isEmpty { break }
            perform(["type": "badges", "ids": more.map(\.id)], syncAfter: 2)
            fresh += more
        }
        return fresh
    }

    static func applyBadgeOp(_ op: JSON, to d: inout JSON) {
        switch str(op["type"]) {
        case "badges":
            var seen = (d["seenBadges"] as? [String]) ?? []
            for id in (op["ids"] as? [String]) ?? [] where !seen.contains(id) { seen.append(id) }
            d["seenBadges"] = seen
        case "bump":   // the social counters the badges read
            let key = str(op["key"])
            if ["postCount", "reactCount", "commentCount", "sendCount", "friendCount"].contains(key) { d[key] = Int(num(d[key]) ?? 0) + 1 }
        case "shareMeal":
            var ids = (d["sharedMealIds"] as? [String]) ?? []
            let id = str(op["id"])
            if op["on"] as? Bool == true { if !ids.contains(id) { ids.append(id) } } else { ids.removeAll { $0 == id } }
            d["sharedMealIds"] = ids
        case "goalWins":
            var wins = (d["goalWins"] as? [String]) ?? []
            for k in (op["keys"] as? [String]) ?? [] where !wins.contains(k) { wins.append(k) }
            d["goalWins"] = wins
        default: break
        }
    }
}
