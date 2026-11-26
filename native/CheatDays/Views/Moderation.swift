import SwiftUI

/// Keeping the feed safe. What's about to be posted is looked at by the AI first (the server's "moderate" function);
/// what's reported is looked at by it too, hidden when it plainly breaks the rules, and passed to a person when the AI
/// isn't sure. Whoever's content is removed is told, and can dispute it; three removals in 90 days suspend an account
/// for a week and five ban it, which can be disputed as well. A dispute is always a person's to settle.
///
/// Until the owner has run supabase/moderation.sql and deployed the function, all of this stands aside: posts go
/// through unchecked and a report is the plain one it always was.
@Observable @MainActor
final class Moderation {
    static let shared = Moderation()
    /// Switching accounts (26 Nov): back to how it starts, so nothing of the last account shows.
    func reset() { removals = []; appealed = []; banAppealed = false; suspendedUntil = nil; isModerator = false; reports = []; appeals = [] }
    private var api: Supabase { Supabase.shared }
    private var me: String { api.userId ?? "" }

    private(set) var removals: [JSON] = []      // mine, still removed
    private(set) var appealed: Set<String> = [] // the removals of mine I've disputed
    private(set) var banAppealed = false
    private(set) var suspendedUntil: Date?
    private(set) var isModerator = false
    private(set) var reports: [JSON] = []       // waiting for a person (reviewers only)
    private(set) var appeals: [JSON] = []       // disputes waiting (reviewers only)
    var waiting: Int { reports.count + appeals.count }
    var suspended: Bool { suspendedUntil.map { $0 > Date() } ?? false }
    /// Far enough off to be for good.
    var banned: Bool { suspendedUntil.map { $0.timeIntervalSinceNow > 86400 * 365 * 5 } ?? false }

    /// The AI said no: why, as a sentence for whoever tried to post it.
    struct Blocked: LocalizedError {
        let why: String
        var errorDescription: String? { "Not posted. " + why }
    }

    private static let categories: [String: String] = [
        "Nudity or sexual content": "nudity", "Harassment or bullying": "harassment", "It involves a child": "child",
        "Violence or self-harm": "violence", "Spam or a scam": "spam", "Pretending to be someone": "impersonation", "Something else": "other"]

    /// A picture small enough to send for a look: 512 dots on its long side.
    private static func small(_ img: UIImage) -> String? {
        PhotoEditor.shrink(img, to: 512).jpegData(compressionQuality: 0.6)?.base64EncodedString()
    }

    private func rows(_ path: String) async -> [JSON] {
        guard let d = try? await api.rest(path) else { return [] }
        return (try? JSONSerialization.jsonObject(with: d)) as? [JSON] ?? []
    }

    // MARK: before it's posted

    /// The AI's look at something about to go up. Throws `Blocked` when it plainly breaks the rules. True when the AI
    /// couldn't tell: it goes up, and a person is asked to look (`flag`). When the check can't be made (not set up
    /// yet, no signal, the AI down) it goes through.
    func gate(kind: String, text: String, image: UIImage?) async throws -> Bool {
        guard !me.isEmpty, image != nil || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var body: JSON = ["action": "check", "kind": kind, "text": text]
        if let image, let b = Self.small(image) { body["image"] = b }
        guard let (d, code) = try? await api.call("/functions/v1/moderate", body: body, timeout: 20), code == 200,
              let r = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return false }
        if str(r["verdict"]) == "block" { throw Blocked(why: str(r["why"]).isEmpty ? "It looks like it breaks the rules." : str(r["why"])) }
        return str(r["verdict"]) == "unsure"
    }

    /// Several pictures at once (a post's photos): the first that's refused stops it; true when any couldn't be told.
    func gate(kind: String, text: String, images: [UIImage]) async throws -> Bool {
        guard images.count > 1 else { return try await gate(kind: kind, text: text, image: images.first) }
        return try await withThrowingTaskGroup(of: Bool.self) { group in
            for (i, img) in images.prefix(10).enumerated() { group.addTask { try await self.gate(kind: kind, text: i == 0 ? text : "", image: img) } }
            var unsure = false
            for try await u in group { unsure = unsure || u }
            return unsure
        }
    }

    /// Something of mine the AI couldn't tell about: up, and waiting for a person to look.
    func flag(kind: String, target: String, text: String, media: String, video: Bool = false) async {
        guard !me.isEmpty, !target.isEmpty else { return }
        let row: JSON = ["id": UUID().uuidString.lowercased(), "reporter": me, "reported": me, "reason": "The AI wasn't sure about this before it was posted",
                         "kind": kind, "target": target, "category": "auto", "status": "human",
                         "snapshot": ["text": text, "media": media, "video": video] as JSON]
        _ = try? await api.rest("/rest/v1/reports", method: "POST", body: [row])
    }

    /// Something of mine posted without waiting for a look (a comment, so sending one isn't slowed): looked at now, and
    /// taken down if it breaks the rules.
    func screen(kind: String, target: String, text: String) {
        guard !me.isEmpty, !target.isEmpty, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let row: JSON = ["id": id, "reporter": me, "reported": me, "reason": "Looked at when it was posted", "kind": kind, "target": target,
                         "category": "auto", "snapshot": ["text": text, "media": "", "video": false] as JSON]
        Task {
            guard (try? await api.rest("/rest/v1/reports", method: "POST", body: [row])) != nil else { return }
            _ = try? await api.call("/functions/v1/moderate", body: ["action": "report", "id": id] as JSON, timeout: 30)
        }
    }

    // MARK: reporting

    /// A report: kept with a copy of what it's about, then looked at by the AI. On a server that hasn't the new
    /// tables yet, it's sent the old way (a line of words to the owner).
    func report(_ t: ReportTarget, reason: String) async {
        guard !me.isEmpty else { return }
        let id = UUID().uuidString.lowercased()
        let row: JSON = ["id": id, "reporter": me, "reported": t.user, "reason": reason + " · " + t.what, "kind": t.kind, "target": t.target,
                         "category": Self.categories[reason] ?? "other", "snapshot": ["text": t.text, "media": t.media, "video": t.video] as JSON]
        if (try? await api.rest("/rest/v1/reports", method: "POST", body: [row])) != nil {
            _ = try? await api.call("/functions/v1/moderate", body: ["action": "report", "id": id] as JSON, timeout: 30)
        } else {
            await Profiles.shared.report(t.user, reason: reason + " · " + t.what)
        }
    }

    // MARK: what's happened to mine

    func load() async {
        guard !me.isEmpty else { return }
        removals = await rows("/rest/v1/removals?owner=eq.\(me)&lifted_at=is.null&select=*&order=created_at.desc&limit=30")
        let mine = await rows("/rest/v1/appeals?user_id=eq.\(me)&select=removal_id,kind,status")
        appealed = Set(mine.map { str($0["removal_id"]) }.filter { !$0.isEmpty })
        banAppealed = mine.contains { str($0["kind"]) == "ban" && str($0["status"]) == "open" }
        suspendedUntil = ISO.date(str(await rows("/rest/v1/profiles?user_id=eq.\(me)&select=suspended_until").first?["suspended_until"]))
        if let d = try? await api.rest("/rest/v1/rpc/is_moderator", method: "POST", body: [:] as JSON) {
            isModerator = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        }
        if isModerator { await loadQueue() }
    }

    /// Dispute one removal, or (with none given) the suspension or ban itself. False when it couldn't be sent.
    func dispute(_ removal: JSON?, text: String) async -> Bool {
        var row: JSON = ["user_id": me, "text": String(text.prefix(1000)), "kind": removal == nil ? "ban" : "removal"]
        if let removal { row["removal_id"] = str(removal["id"]) }
        guard (try? await api.rest("/rest/v1/appeals", method: "POST", body: [row])) != nil else { return false }
        if let removal { appealed.insert(str(removal["id"])) } else { banAppealed = true }
        return true
    }

    // MARK: reviewing (the owner)

    func loadQueue() async {
        guard let d = try? await api.rest("/rest/v1/rpc/mod_queue", method: "POST", body: [:] as JSON),
              let q = (try? JSONSerialization.jsonObject(with: d)) as? JSON else { return }
        reports = list(q["reports"]); appeals = list(q["appeals"])
    }

    /// keep, remove, or suspend (remove and suspend whoever posted it for so many days).
    func decide(_ report: JSON, _ act: String, days: Int = 0) async {
        _ = try? await api.rest("/rest/v1/rpc/mod_decide", method: "POST", body: ["rep": str(report["id"]), "act": act, "days": days] as JSON)
        await loadQueue()
    }

    /// restore (put it back, or lift the ban) or uphold.
    func settle(_ appeal: JSON, _ act: String) async {
        _ = try? await api.rest("/rest/v1/rpc/mod_appeal", method: "POST", body: ["ap": str(appeal["id"]), "act": act] as JSON)
        await loadQueue()
    }
}

// MARK: - told about a removal, a suspension; disputing it

/// At the top of the feed when something of yours has been removed or your account is suspended: what and why, with a
/// way to dispute it.
struct ModerationNotices: View {
    @State private var disputing: Dispute?
    @AppStorage("moderation.dismissed") private var dismissedJSON = "[]"
    private var mod: Moderation { Moderation.shared }
    private var dismissed: [String] { (try? JSONDecoder().decode([String].self, from: Data(dismissedJSON.utf8))) ?? [] }

    struct Dispute: Identifiable { let id = UUID(); let removal: JSON? }

    var body: some View {
        let shown = mod.removals.filter { !dismissed.contains(str($0["id"])) }
        VStack(spacing: 8) {
            if mod.suspended {
                card(mod.banned ? "Your account is banned from posting" : "Your account is suspended",
                     mod.banned ? "Several things you posted broke the rules. You can still read, but not post, comment or message."
                                : "Until \(mod.suspendedUntil?.formatted(date: .abbreviated, time: .shortened) ?? "later") you can read, but not post, comment or message.",
                     dispute: mod.banAppealed ? nil : { disputing = Dispute(removal: nil) }, waiting: mod.banAppealed, ok: nil)
            }
            ForEach(shown.indices, id: \.self) { i in
                let r = shown[i], id = str(r["id"]), sent = mod.appealed.contains(id)
                card("Your \(Self.noun(str(r["kind"]))) was removed", str(r["why"]).isEmpty ? "It broke the rules." : str(r["why"]),
                     dispute: sent ? nil : { disputing = Dispute(removal: r) }, waiting: sent,
                     ok: { dismissedJSON = String(data: (try? JSONEncoder().encode(dismissed + [id])) ?? Data("[]".utf8), encoding: .utf8) ?? "[]" })
            }
        }
        .padding(.horizontal, 12).padding(.top, mod.suspended || !shown.isEmpty ? 10 : 0)
        .sheet(item: $disputing) { d in DisputeSheet(removal: d.removal) }
    }

    static func noun(_ kind: String) -> String { ["post": "post", "story": "story", "comment": "comment"][kind] ?? "post" }

    private func card(_ title: String, _ why: String, dispute: (() -> Void)?, waiting: Bool, ok: (() -> Void)?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.shield.fill").font(.subheadline.weight(.heavy)).foregroundStyle(Theme.warn)
            Text(why).font(.footnote).foregroundStyle(.primary.opacity(0.85))
            HStack(spacing: 10) {
                if let dispute {
                    Button("Dispute this", action: dispute).font(.footnote.weight(.bold)).buttonStyle(.borderedProminent).controlSize(.small)
                } else if waiting {
                    Text("Your dispute is with a person to look at.").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
                if let ok { Button("OK", action: ok).font(.footnote.weight(.bold)).buttonStyle(.bordered).controlSize(.small) }
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Saying why a removal (or a suspension) was wrong. It goes to a person, never back to the AI.
struct DisputeSheet: View {
    let removal: JSON?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What did we get wrong?", text: $text, axis: .vertical).lineLimit(4...10)
                } footer: {
                    Text(removal == nil ? "A person will read this and decide whether to lift it."
                                        : "A person will look at what was removed and read this. If they agree, it goes back up.")
                }
                if failed { Text("Couldn't send that. Try again in a moment.").font(.footnote).foregroundStyle(Theme.warn) }
            }
            .navigationTitle("Dispute").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Sending…" : "Send") {
                        busy = true
                        Task {
                            if await Moderation.shared.dispute(removal, text: text) { dismiss() } else { failed = true }
                            busy = false
                        }
                    }
                    .fontWeight(.bold).disabled(busy || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

// MARK: - the reviewer's screen

/// What's waiting for a person: reports the AI couldn't settle, and disputes. Made to be decided without looking where
/// that can be helped: each has the AI's plain description first, a picture stays blurred until it's held, and
/// anything reported as involving a child shows no picture at all.
struct ModerationQueueView: View {
    private var mod: Moderation { Moderation.shared }

    var body: some View {
        List {
            if mod.waiting == 0 {
                Text("Nothing waiting. Reports the AI can't settle, and disputes, come here.").foregroundStyle(.secondary)
            }
            if !mod.reports.isEmpty {
                Section("Reports") { ForEach(mod.reports.indices, id: \.self) { i in ReportRow(report: mod.reports[i]) } }
            }
            if !mod.appeals.isEmpty {
                Section("Disputes") { ForEach(mod.appeals.indices, id: \.self) { i in AppealRow(appeal: mod.appeals[i]) } }
            }
        }
        .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
        .refreshable { await mod.loadQueue() }
        .task { await mod.loadQueue() }
    }
}

/// A picture that stays blurred until it's pressed and held, and blurs again on letting go.
private struct HeldPicture: View {
    let src: String
    @State private var looking = false

    var body: some View {
        Color(.tertiarySystemFill).frame(width: 120, height: 160)
            .overlay { FeedPhoto(src: src, fill: true).blur(radius: looking ? 0 : 28) }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay { if !looking { Text("Hold to look").font(.caption.weight(.bold)).foregroundStyle(.white).shadow(radius: 3) } }
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 60, perform: {}, onPressingChanged: { looking = $0 })
            .accessibilityLabel("The picture, hidden until held")
    }
}

private struct ReportRow: View {
    let report: JSON
    @State private var busy = false
    private var mod: Moderation { Moderation.shared }

    var body: some View {
        let snap = dict(report["snapshot"]), verdict = dict(report["verdict"]), child = str(report["category"]) == "child"
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ModerationNotices.noun(str(report["kind"])).capitalized + (str(report["kind"]).isEmpty ? "" : "")).font(.subheadline.weight(.heavy))
                Text(str(report["category"]).isEmpty ? "reported" : str(report["category"])).font(.caption.weight(.bold)).foregroundStyle(child ? Theme.warn : .secondary)
                Spacer()
                Text(Feed.ago(str(report["created_at"]))).font(.caption).foregroundStyle(.secondary)
            }
            Text(Feed.shared.name(str(report["reported"]))).font(.footnote).foregroundStyle(.secondary)
            if !str(verdict["seen"]).isEmpty { Label(str(verdict["seen"]), systemImage: "eye").font(.footnote) }
            if !str(verdict["why"]).isEmpty { Text("The AI: " + str(verdict["why"])).font(.footnote).foregroundStyle(.secondary) }
            if !str(snap["text"]).isEmpty { Text("“" + str(snap["text"]) + "”").font(.footnote).italic() }
            if child {
                Text("Hidden from everyone already. Its picture isn't shown here. If this is real, it must be reported to the authorities, not only removed: get advice before doing anything else with it.")
                    .font(.footnote).foregroundStyle(Theme.warn)
            } else if !str(snap["media"]).isEmpty {
                HeldPicture(src: str(snap["media"]))
                if snap["video"] as? Bool == true { Text("A video: this is its first frame only.").font(.caption).foregroundStyle(.secondary) }
            }
            Text(str(report["reason"])).font(.caption2).foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Keep") { act("keep") }.tint(Theme.walk)
                Button("Remove") { act("remove") }.tint(Theme.warn)
                Button("Remove + 7 days") { act("suspend", 7) }.tint(.red)
            }
            .font(.footnote.weight(.bold)).buttonStyle(.bordered).controlSize(.small).disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func act(_ what: String, _ days: Int = 0) {
        busy = true
        Task { await mod.decide(report, what, days: days); busy = false }
    }
}

private struct AppealRow: View {
    let appeal: JSON
    @State private var busy = false
    private var mod: Moderation { Moderation.shared }

    var body: some View {
        let ban = str(appeal["kind"]) == "ban", removal = dict(appeal["removal"]), rep = dict(appeal["report"]), snap = dict(rep["snapshot"])
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ban ? "Suspension or ban" : "Removed \(ModerationNotices.noun(str(removal["kind"])))").font(.subheadline.weight(.heavy))
                Spacer()
                Text(Feed.ago(str(appeal["created_at"]))).font(.caption).foregroundStyle(.secondary)
            }
            Text("\(Feed.shared.name(str(appeal["user_id"]))) · \(Int(num(appeal["strikes"]) ?? 0)) removed in all").font(.footnote).foregroundStyle(.secondary)
            Text("They say: “" + str(appeal["text"]) + "”").font(.footnote)
            if !ban {
                if !str(removal["why"]).isEmpty { Text("Removed because: " + str(removal["why"])).font(.footnote).foregroundStyle(.secondary) }
                if !str(snap["text"]).isEmpty { Text("“" + str(snap["text"]) + "”").font(.footnote).italic() }
                if str(removal["category"]) == "child" {
                    Text("Reported as involving a child. Its picture isn't shown here.").font(.footnote).foregroundStyle(Theme.warn)
                } else if !str(snap["media"]).isEmpty { HeldPicture(src: str(snap["media"])) }
            }
            HStack(spacing: 8) {
                Button(ban ? "Lift it" : "Put it back") { act("restore") }.tint(Theme.walk)
                Button(ban ? "Keep it" : "Leave it removed") { act("uphold") }.tint(Theme.warn)
            }
            .font(.footnote.weight(.bold)).buttonStyle(.bordered).controlSize(.small).disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func act(_ what: String) {
        busy = true
        Task { await mod.settle(appeal, what); busy = false }
    }
}
