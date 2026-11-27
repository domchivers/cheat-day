import SwiftUI

/// Instagram-style accounts (26 Nov, design/account-switcher-mockup.html): every account signed in on this phone keeps
/// its own sign-in (Supabase.swift, "acct.<id>"), so switching needs no password. A switch sends the account's last
/// changes up, then clears everything of it held in memory, becomes the other account and rebuilds the tabs, whose
/// loading brings the new account's record, feed and friends down.
@MainActor @Observable
final class Accounts {
    static let shared = Accounts()

    struct Saved: Codable, Identifiable, Equatable {
        var id: String
        var email: String
        var username = ""
        var name = ""
        /// What the sheet shows: the @name, else the name, else the start of the email.
        var title: String { !username.isEmpty ? username : !name.isEmpty ? name : String(email.split(separator: "@").first ?? "") }
    }

    private(set) var list: [Saved] = []
    /// The accounts sheet (the name at the top of your profile, Settings' Accounts).
    var sheet = false
    /// Signing in to another account, over the app.
    var adding = false
    /// A switch on its way.
    private(set) var busy = false
    /// "Switched to …", for a moment.
    private(set) var toast: String?
    /// Why a switch can't happen right now.
    var problem: String?
    /// Bumped on every switch: the tabs are rebuilt from scratch.
    private(set) var generation = 0

    private static let key = "accounts.list"
    private var leaving: String?   // the account an Add started from, for Cancel

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let l = try? JSONDecoder().decode([Saved].self, from: d) { list = l }
    }

    var current: String { Supabase.shared.userId ?? "" }
    /// The accounts whose sign-in this phone still holds, the one you're on first.
    var accounts: [Saved] {
        let kept = list.filter { Supabase.shared.hasAccount($0.id) }
        return kept.filter { $0.id == current } + kept.filter { $0.id != current }
    }

    /// The account you're on, with its names as they are now (after its profile loads, and on every switch).
    func remember() {
        let me = current
        guard !me.isEmpty else { return }
        Supabase.shared.keepCurrent()
        var s = list.first { $0.id == me } ?? Saved(id: me, email: Supabase.shared.email)
        if !Supabase.shared.email.isEmpty { s.email = Supabase.shared.email }
        if let p = Profiles.shared.all[me] { s.username = p.username; s.name = p.name }
        if let i = list.firstIndex(where: { $0.id == me }) { if list[i] == s { return }; list[i] = s } else { list.append(s) }
        save()
    }

    private func save() { if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: Self.key) } }

    /// Something still working that would land in whichever account is on when it finishes.
    private var blocked: String? {
        if AssistantLive.shared.busy { return "The assistant is still answering. Try again when it's done." }
        if !RecipeMaker.shared.working.isEmpty { return "A recipe is still being made. Try again when it's done." }
        if Feed.shared.sending?.state == .working { return "Your post is still sending. Try again when it's up." }
        if Stories.shared.posting { return "Your story is still posting. Try again when it's up." }
        return nil
    }

    /// The account you're leaving: its last changes up as itself, and its web part's sign-in kept. False if it can't go yet.
    private func leave() async -> Bool {
        if let why = blocked { problem = why; return false }
        remember()
        await Store.shared.sync()
        if !Store.shared.pending.isEmpty {
            problem = "Your latest changes haven't saved yet. Check your connection and try again."
            return false
        }
        if !current.isEmpty, let web = await WebHost.shared.currentSession() { Supabase.shared.keepWeb(web, for: current) }
        await WebHost.shared.clearForSwitch()
        return true
    }

    /// Everything of the last account held in memory, gone. The tabs are rebuilt after (generation).
    private func clearState(store: Bool) {
        if store {
            Store.shared.reset()
            UserDefaults.standard.set(current, forKey: "store.user")
        }
        Store.shared.undo = nil; Store.shared.notice = nil; Store.shared.logDay = nil
        let a = AssistantLive.shared
        a.turns = []; a.chatId = uid(); a.problem = nil; a.done = [:]; a.addedIDs = [:]; a.addedFoods = [:]; a.mealNames = [:]
        Family.shared.reset(); Follows.shared.reset(); Highlights.shared.reset(); Messages.shared.reset()
        Profiles.shared.reset(); Friends.shared.reset(); Stories.shared.reset(); WatchLink.shared.reset()
        FriendActivity.shared.reset(); Feed.shared.reset(); Inbox.shared.reset(); Moderation.shared.reset(); RecipeMaker.shared.reset()
        ProfileView.forgetAll()
        SongPlayer.shared.stop(); WorkoutTimer.shared.end(); Tour.shared.stop()
        let n = Nav.shared
        n.friendsSeg = 1; n.focusPost = nil; n.chatWith = nil; n.addCode = nil; n.planMeal = nil
        generation += 1
    }

    /// Become that account. False (with a problem to show) if it can't happen right now.
    @discardableResult
    func switchTo(_ id: String) async -> Bool {
        guard !busy, id != current, Supabase.shared.hasAccount(id) else { return false }
        busy = true
        defer { busy = false }
        problem = nil
        guard await leave() else { return false }
        guard Supabase.shared.use(account: id) else { problem = "That account needs signing in again."; return false }
        clearState(store: true)
        sheet = false
        show("Switched to \(list.first { $0.id == id }?.title ?? "your other account")")
        return true
    }

    /// A notification for another account on this phone: that account first.
    func ensure(_ id: String) async {
        if id != current, Supabase.shared.hasAccount(id) { await switchTo(id) }
    }

    /// Add account: sign in or make one over the app. The one you're on is saved first.
    func add() async {
        guard !busy else { return }
        problem = nil
        busy = true
        let ok = await leave()
        busy = false
        guard ok else { return }
        leaving = current
        sheet = false
        adding = true
    }

    /// Signed in to the added account (SignInView): it's on now.
    func added() {
        adding = false
        leaving = nil
        clearState(store: false)   // SignInView's sync already brought this account's record down
        remember()
        show("Switched to \(list.first { $0.id == current }?.title ?? "your new account")")
    }

    /// Add account closed without signing in: back as you were (its web part's sign-in too).
    func cancelAdd() {
        adding = false
        if let id = leaving { _ = Supabase.shared.use(account: id) }
        leaving = nil
    }

    /// Log out of the account you're on. Another account on the phone takes over; with none, the sign-in screen.
    func logOutHere() async {
        let me = current
        await Push.leave()
        if let next = accounts.first(where: { $0.id != me }) {
            busy = true
            await Store.shared.sync()
            await WebHost.shared.clearForSwitch()
            Supabase.shared.forget(account: me)
            list.removeAll { $0.id == me }; save()
            if Supabase.shared.use(account: next.id) {
                clearState(store: true)
                busy = false
                show("Logged out. You're on \(next.title)")
                return
            }
            busy = false
        }
        Supabase.shared.forget(account: me)
        list.removeAll { $0.id == me }; save()
        signOutCompletely()
    }

    /// Delete the account you're on, for good (App Store guideline 5.1.1(v)): the server's "delete-account" function removes
    /// its photos, its rows and the sign-in, then it's logged out here like Log out, without syncing anything back up.
    /// Nil when done, else what went wrong. The account's password comes first (27 Nov): checked here, then again by the
    /// server, so a wrong one deletes nothing.
    func deleteHere(password: String) async -> String? {
        let me = current
        guard !me.isEmpty else { return "You're not signed in." }
        busy = true
        let said = await Self.passwordFirst(password, check: { await Supabase.shared.passwordIsRight($0) }, then: { await self.deleteChecked(me, password: $0) })
        busy = false
        return said
    }

    static let wrongPassword = "That password isn't right."

    /// The password check, then the delete only when it passed. Apart so tests can stand in for the network.
    static func passwordFirst(_ password: String, check: (String) async -> Bool?, then delete: (String) async -> String?) async -> String? {
        guard !password.isEmpty else { return "Type your password to delete your account." }
        switch await check(password) {
        case .some(true): return await delete(password)
        case .some(false): return wrongPassword
        case .none: return "Couldn't check your password. Check your connection and try again."
        }
    }

    private func deleteChecked(_ me: String, password: String) async -> String? {
        await Push.leave()
        let got = try? await Supabase.shared.call("/functions/v1/delete-account", body: ["confirm": "delete", "password": password] as JSON, timeout: 60)
        guard let (d, status) = got else { busy = false; return "Couldn't reach Cheat Days. Check your connection and try again." }
        guard status == 200 else {
            busy = false
            let why = (try? JSONSerialization.jsonObject(with: d) as? JSON).flatMap { $0["error"] as? String }
            return why ?? "Couldn't delete the account (\(status)). Try again in a minute."
        }
        let note = Self.deletedNote(d)
        await WebHost.shared.clearForSwitch()
        Supabase.shared.forget(account: me)
        list.removeAll { $0.id == me }; save()
        if let next = accounts.first(where: { $0.id != me }), Supabase.shared.use(account: next.id) {
            clearState(store: true)
            busy = false
            show("\(note) You're on \(next.title).")
            return nil
        }
        busy = false
        farewell = note   // the sign-in screen says it, since no toast shows there
        signOutCompletely()
        return nil
    }

    /// What the sign-in screen says after this phone's last account was deleted (once).
    var farewell: String?


    /// What the server's answer means: waiting 30 days (1.4.75's delete-account), or gone now (an account with no
    /// profile, or the older function).
    static func deletedNote(_ d: Data) -> String {
        let j = (try? JSONSerialization.jsonObject(with: d) as? JSON) ?? [:]
        guard j["pending"] as? Bool == true, let s = j["delete_after"] as? String, let when = isoDate(s) else { return "Account deleted." }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_AU"); f.dateFormat = "EEEE d MMMM"
        return "Your account will be deleted on \(f.string(from: when)). Sign in before then to keep it."
    }

    static func isoDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static let welcomeBackNote = "Welcome back! Your account won't be deleted."

    /// Signing in again within the 30 days cancels the deletion. Nil when nothing was waiting (or it couldn't ask).
    static func welcomeBack(_ cancel: () async -> Bool?) async -> String? {
        await cancel() == true ? welcomeBackNote : nil
    }

    /// After every sign-in: an account that was waiting to be deleted isn't any more, and says so.
    func afterSignIn() async {
        if let t = await Self.welcomeBack({ await Supabase.shared.cancelDeletion() }) { show(t) }
    }

    /// Log out of every account on this phone.
    func logOutAll() async {
        await Push.leave()
        for a in list where a.id != current { Supabase.shared.forget(account: a.id) }
        Supabase.shared.forget(account: current)
        list = []; save()
        signOutCompletely()
    }

    private func signOutCompletely() {
        WebHost.shared.signOut()
        Supabase.shared.signOut()
        clearState(store: true)
    }

    private func show(_ text: String) {
        toast = text
        Task { try? await Task.sleep(nanoseconds: 2_400_000_000); if toast == text { toast = nil } }
    }
}

/// The accounts sheet: the ones on this phone (yours ticked), and Add account.
struct AccountsSheet: View {
    @Bindable private var accounts = Accounts.shared

    var body: some View {
        VStack(spacing: 0) {
            Text("Accounts").font(.headline).padding(.top, 22).padding(.bottom, 10)
            ForEach(accounts.accounts) { a in
                Button { Task { await accounts.switchTo(a.id) } } label: {
                    HStack(spacing: 12) {
                        Avatar(id: a.id, size: 46)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                            if !a.name.isEmpty && a.name != a.title { Text(a.name).font(.subheadline).foregroundStyle(.secondary) }
                        }
                        Spacer(minLength: 0)
                        if a.id == accounts.current {
                            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(Theme.accent)
                        } else if accounts.busy {
                            ProgressView()
                        } else {
                            Circle().strokeBorder(Color.secondary.opacity(0.5), lineWidth: 2).frame(width: 24, height: 24)
                        }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 9).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(a.id == accounts.current || accounts.busy)
                .accessibilityLabel(a.id == accounts.current ? "\(a.title), the account you're on" : "Switch to \(a.title)")
            }
            Divider().padding(.horizontal, 20).padding(.vertical, 6)
            Button { Task { await accounts.add() } } label: {
                HStack(spacing: 12) {
                    Image(systemName: "plus").font(.title3).foregroundStyle(Theme.accent)
                        .frame(width: 46, height: 46)
                        .overlay(Circle().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                    Text("Add account").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 9).contentShape(Rectangle())
            }
            .buttonStyle(.plain).disabled(accounts.busy)
            if let p = accounts.problem {
                Text(p).font(.footnote).foregroundStyle(Theme.warn).padding(.horizontal, 20).padding(.top, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .presentationDetents([.height(CGFloat(140 + accounts.accounts.count * 64 + (accounts.problem == nil ? 0 : 44)))])
        .presentationDragIndicator(.visible)
        .onAppear { accounts.remember(); accounts.problem = nil }
    }
}

/// "Switched to cheatdays", at the top for a moment.
struct AccountToast: View {
    let text: String
    var body: some View {
        HStack(spacing: 10) {
            Avatar(id: Accounts.shared.current, size: 28)
            Text(text).font(.subheadline.weight(.bold)).lineLimit(2)   // a deletion date or a welcome back runs to two
        }
        .padding(.leading, 8).padding(.trailing, 16).padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.top, 8)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityAddTraits(.isStaticText)
    }
}
