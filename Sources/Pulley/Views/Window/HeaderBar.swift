import SwiftUI
import AppKit

// MARK: - Panel header

/// Top of the content panel for list sections: serif title with a count on
/// the left, search and (for PRs) the grouping menu on the right. Section
/// switching lives in the sidebar.
struct PanelHeader: View {
    let title: String
    let subtitle: String
    @Binding var query: String
    var searchPrompt: String = "Search"
    var groupMode: Binding<ListGroupMode>? = nil

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(Theme.display(22))
                .lineLimit(1)
            Text(subtitle)
                .font(Theme.ui(12))
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer(minLength: 12)
            searchField
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            if let groupMode {
                GroupPicker(groupMode: groupMode)
                    .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: 1)
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Icon("magnifyingglass", size: 11)
                .foregroundColor(.secondary)
            TextField(searchPrompt, text: $query)
                .textFieldStyle(.plain)
                .font(Theme.ui(12))
                .focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Icon("xmark.circle.fill", size: 11)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Theme.chrome.opacity(0.7))
        )
        .frame(minWidth: 160, idealWidth: 240, maxWidth: 280)
        .background(
            // ⌘F focuses search from anywhere in the window.
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .accessibilityHidden(true)
        )
    }
}

private struct GroupPicker: View {
    @Binding var groupMode: ListGroupMode

    var body: some View {
        Menu {
            ForEach(ListGroupMode.allCases) { mode in
                Button {
                    groupMode = mode
                } label: {
                    Label(mode.label, systemImage: groupMode == mode ? "checkmark" : mode.icon)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Icon(groupMode.icon, size: 10)
                Text(groupMode == .none ? "Group" : "By \(groupMode.label.lowercased())")
                    .font(Theme.ui(12))
                Icon("chevron.down", size: 8)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.chrome.opacity(0.7))
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group pull requests")
    }
}

func relativeSyncLabel(_ lastSync: Date?, now: Date = Date()) -> String {
    guard let last = lastSync else { return "never synced" }
    let s = Int(now.timeIntervalSince(last))
    if s < 60     { return "synced now" }
    if s < 3600   { return "synced \(s / 60)m ago" }
    if s < 86400  { return "synced \(s / 3600)h ago" }
    return "synced \(s / 86400)d ago"
}
