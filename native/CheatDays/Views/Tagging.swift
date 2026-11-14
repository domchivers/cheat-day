import SwiftUI

/// "@name" typed in a caption or a comment: who it could be while it's being typed, who it is once written, and the
/// text drawn with those names coloured and tappable. A friend is written as their username, or their name with no
/// spaces when they haven't one.
@MainActor enum Tagging {
    struct Match: Identifiable {
        let id: String
        let name: String
        let token: String
    }

    static func token(_ id: String, _ name: String) -> String {
        let u = Profiles.shared.all[id]?.username ?? ""
        return u.isEmpty ? name.filter { !$0.isWhitespace } : u
    }

    private static var known: [Match] {
        Friends.shared.people.map { Match(id: $0.id, name: $0.name, token: token($0.id, $0.name)) }
    }

    /// The friends the "@word" being typed could be: the last word of the text, with nothing after it yet.
    static func matches(_ text: String) -> [Match] {
        guard let last = text.last, !last.isWhitespace,
              let word = text.split(whereSeparator: { $0.isWhitespace }).last, word.hasPrefix("@") else { return [] }
        let q = word.dropFirst().lowercased()
        return Array(known.filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.token.lowercased().contains(q) }.prefix(8))
    }

    /// The text with the "@word" being typed finished as this friend.
    static func picked(_ m: Match, in text: String) -> String {
        guard let at = text.range(of: "@", options: .backwards) else { return text }
        return String(text[..<at.lowerBound]) + "@" + m.token + " "
    }

    /// Each "@word" in the text that is a friend, with where it is.
    private static func found(_ text: String) -> [(range: Range<String.Index>, id: String)] {
        guard text.contains("@"), let pattern = try? Regex("@[\\p{L}\\p{N}._]+") else { return [] }
        let people = known
        var out: [(range: Range<String.Index>, id: String)] = []
        for r in text.ranges(of: pattern) {
            // a full stop ending the sentence isn't part of the name
            var word = text[r].dropFirst().lowercased()
            var end = r.upperBound
            while word.hasSuffix(".") { word.removeLast(); end = text.index(before: end) }
            if let p = people.first(where: { $0.token.lowercased() == word }) { out.append((range: r.lowerBound..<end, id: p.id)) }
        }
        return out
    }

    /// The friends named in it, once each.
    static func people(in text: String) -> [String] {
        var seen: [String] = []
        for f in found(text) where !seen.contains(f.id) { seen.append(f.id) }
        return seen
    }

    /// The text with each friend's "@name" coloured and made a link (see `tagLinks`).
    static func styled(_ text: String) -> AttributedString {
        var out = AttributedString(text)
        for f in found(text) {
            guard let r = Range(f.range, in: out), let url = URL(string: "cheatdays-user://" + f.id) else { continue }
            out[r].link = url
            out[r].foregroundColor = Theme.accent
        }
        return out
    }
}

extension View {
    /// A friend's "@name" tapped in text drawn with `Tagging.styled`: told who.
    func tagLinks(_ open: @escaping (String) -> Void) -> some View {
        environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "cheatdays-user", let id = url.host, !id.isEmpty else { return .systemAction }
            open(id)
            return .handled
        })
    }
}

/// Under a caption or comment box: the friends the "@word" being typed could be, to tap.
struct TagSuggestions: View {
    @Binding var text: String

    var body: some View {
        let found = Tagging.matches(text)
        if !found.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(found) { m in
                        Button { text = Tagging.picked(m, in: text) } label: {
                            HStack(spacing: 6) {
                                Avatar(id: m.id, size: 24)
                                Text(m.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            .padding(.leading, 5).padding(.trailing, 12).frame(height: 34)
                            .background(Color(.tertiarySystemFill), in: Capsule())
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("tag-suggestion")
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }
}
