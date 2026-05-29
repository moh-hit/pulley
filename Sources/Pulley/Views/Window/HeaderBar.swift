import SwiftUI
import AppKit

// MARK: - Header bar

/// Single-row tab-bar header: status tabs left, search + count + group right.
/// Optional second row for org tabs when more than one org is configured.
struct HeaderBar: View {
    @Binding var filter: SidebarFilter
    @Binding var query: String
    @Binding var groupMode: ListGroupMode
    @Binding var viewMode: MainViewMode
    let prs: [PR]
    let filteredCount: Int
    let inboxCount: Int
    let lastSync: Date?
    let syncing: Bool
    @State private var nowTick: Date = Date()

    private var statusCounts: [PRStatus: Int] {
        Dictionary(grouping: prs, by: { $0.status }).mapValues(\.count)
    }

    private var orgs: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: prs, by: { $0.org })
        return grouped.keys.sorted().map { (name: $0, count: grouped[$0]?.count ?? 0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow
            if orgs.count > 1 && viewMode == .prs {
                orgRow
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            nowTick = Date()
        }
    }

    private var mainRow: some View {
        HStack(spacing: 10) {
            HStack(spacing: 3) {
                FilterTab(
                    label: "All",
                    count: prs.count,
                    dot: .accentColor,
                    isSelected: viewMode == .prs && filter == .all
                ) { viewMode = .prs; filter = .all }

                FilterTab(
                    label: "Changes",
                    count: statusCounts[.changes] ?? 0,
                    dot: .red,
                    isSelected: viewMode == .prs && filter == .status(.changes)
                ) { viewMode = .prs; filter = .status(.changes) }

                FilterTab(
                    label: "Review",
                    count: statusCounts[.review] ?? 0,
                    dot: .orange,
                    isSelected: viewMode == .prs && filter == .status(.review)
                ) { viewMode = .prs; filter = .status(.review) }

                FilterTab(
                    label: "Approved",
                    count: statusCounts[.approved] ?? 0,
                    dot: .green,
                    isSelected: viewMode == .prs && filter == .status(.approved)
                ) { viewMode = .prs; filter = .status(.approved) }

                FilterTab(
                    label: "Open",
                    count: statusCounts[.open] ?? 0,
                    dot: .blue,
                    isSelected: viewMode == .prs && filter == .status(.open)
                ) { viewMode = .prs; filter = .status(.open) }

                // Visual separator before the Inbox switch — it's a different
                // surface, not another PR filter.
                Rectangle()
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 0.5, height: 16)
                    .padding(.horizontal, 4)

                InboxTab(
                    count: inboxCount,
                    isSelected: viewMode == .inbox
                ) { viewMode = .inbox }
            }

            Spacer(minLength: 12)

            searchField
            syncStatus
            if viewMode == .prs {
                countLabel
                groupPicker
            } else {
                inboxCountLabel
            }
        }
    }

    private var inboxCountLabel: some View {
        HStack(spacing: 3) {
            Text("\(inboxCount)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text(inboxCount == 1 ? "unread" : "unread")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .fixedSize()
    }

    private var syncStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(syncing ? Color.orange : Color.green.opacity(0.85))
                .frame(width: 5, height: 5)
            Text(relativeSyncLabel(lastSync, now: nowTick))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .help(syncing ? "Syncing…" : (lastSync.map { "Last sync: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Never synced"))
    }

    private var orgRow: some View {
        HStack(spacing: 6) {
            Spacer(minLength: 0)
            ForEach(orgs, id: \.name) { o in
                OrgPill(
                    name: o.name,
                    count: o.count,
                    isSelected: filter == .org(o.name)
                ) { filter = .org(o.name) }
            }
        }
    }

    private var countLabel: some View {
        HStack(spacing: 3) {
            Text("\(filteredCount)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
            Text("PRs")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.6))
        }
        .fixedSize()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary.opacity(0.7))
            TextField("Filter", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .frame(minWidth: 140, idealWidth: 220, maxWidth: 260)
    }

    private var groupPicker: some View {
        Menu {
            ForEach(ListGroupMode.allCases) { m in
                Button {
                    groupMode = m
                } label: {
                    HStack {
                        Image(systemName: m.icon)
                        Text(m.label)
                        if groupMode == m {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: groupMode.icon)
                    .font(.system(size: 10, weight: .medium))
                Text(groupMode.label)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Group PRs")
    }
}

/// Uniform compact tab. Status-color dot + label + count. Active gets a
/// soft tint matching the dot; hover gives a faint neutral fill.
private struct FilterTab: View {
    let label: String
    let count: Int
    let dot: Color
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
                    .opacity(isSelected ? 1 : 0.75)
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(labelColor)
                    .fixedSize()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(countColor)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(stroke, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private var labelColor: Color {
        if isSelected { return .primary }
        if hovered    { return .primary.opacity(0.85) }
        return .secondary.opacity(0.85)
    }

    private var countColor: Color {
        isSelected ? .secondary.opacity(0.9) : .secondary.opacity(0.55)
    }

    private var background: Color {
        if isSelected { return dot.opacity(0.13) }
        if hovered    { return Color.primary.opacity(0.06) }
        return .clear
    }

    private var stroke: Color {
        isSelected ? dot.opacity(0.3) : .clear
    }
}

/// Mirrors FilterTab visually but with a bell icon and accent dot fixed to
/// the GitHub-purple-ish tint, so it reads as a sibling control rather than
/// a sixth status filter.
private struct InboxTab: View {
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    private var dot: Color { .purple }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "tray.fill")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? dot : .secondary.opacity(0.85))
                Text("Inbox")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary.opacity(0.85))
                    .fixedSize()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(dot.opacity(0.9)))
                        .fixedSize()
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? dot.opacity(0.14) : (hovered ? Color.primary.opacity(0.06) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isSelected ? dot.opacity(0.32) : .clear, lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.1), value: isSelected)
        .help("GitHub notifications")
    }
}

private struct OrgPill: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Circle()
                    .fill(colorForRepo(name))
                    .frame(width: 5, height: 5)
                Text(name.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.0)
                    .foregroundColor(isSelected ? .primary : .secondary.opacity(0.8))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.6))
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(pillBackground)
            )
            .overlay(
                Capsule().stroke(pillStroke, lineWidth: 0.5)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    private var pillBackground: Color {
        if isSelected { return colorForRepo(name).opacity(0.18) }
        if hovered    { return Color.primary.opacity(0.05) }
        return .clear
    }

    private var pillStroke: Color {
        isSelected
            ? colorForRepo(name).opacity(0.35)
            : Color.primary.opacity(0.1)
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
