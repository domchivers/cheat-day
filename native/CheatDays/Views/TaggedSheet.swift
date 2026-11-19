import SwiftUI

/// Who's tagged in a post (19 Nov; the owner's Instagram screenshot): opened from the person in the photo's bottom
/// left corner. Each with their photo, username and name, and Follow; a tap on one opens their profile.
struct TaggedSheet: View {
    let ids: [String]
    var open: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("In this photo").font(.headline).padding(.top, 24).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 14) { ForEach(ids, id: \.self) { row($0) } }
                    .padding(.horizontal, 18).padding(.bottom, 20)
            }
        }
        .presentationDetents([.height(min(520, 100 + CGFloat(ids.count) * 74))])
        .presentationDragIndicator(.visible)
    }

    private func row(_ id: String) -> some View {
        let p = Profiles.shared.all[id]
        let handle = (p?.username.isEmpty == false ? p?.username : nil) ?? Feed.shared.name(id)
        let name = p?.name ?? ""
        return HStack(spacing: 14) {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { open(id) }
            } label: {
                HStack(spacing: 14) {
                    Avatar(id: id, size: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(handle).font(.headline).foregroundStyle(.primary).lineLimit(1)
                        if !name.isEmpty, name != handle { Text(name).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(handle), open their profile")
            if id != Profiles.shared.me { follow(id) }
        }
    }

    @ViewBuilder private func follow(_ id: String) -> some View {
        let st = Follows.shared.state(id)
        Button {
            Task { if st == .none { await Follows.shared.follow(id) } else { await Follows.shared.unfollow(id) } }
        } label: {
            Text(st == .following ? "Following" : st == .requested ? "Requested" : "Follow")
                .font(.subheadline.weight(.bold)).frame(width: 112, height: 36)
                .foregroundStyle(st == .none ? Theme.onAccent : Color.primary)
                .background(st == .none ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color(.tertiarySystemFill)), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The people tagged in a post, for the sheet.
struct TagBox: Identifiable { let id = UUID(); let ids: [String] }
