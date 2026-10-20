import SwiftUI
import AppKit

// MARK: - List pane

struct PRListPane: View {
    let prs: [PR]
    @Binding var selectedPRID: String?
    @Binding var groupMode: ListGroupMode
    let filter: SidebarFilter

    var body: some View {
        Group {
            if prs.isEmpty {
                emptyState
            } else {
                listBody
            }
        }
        .background(Theme.panel)
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon("tray", size: 32)
                .foregroundColor(.secondary.opacity(0.45))
            Text("Nothing here")
                .font(Theme.ui(14, .medium))
                .foregroundColor(.secondary)
            Text("Try a different filter or sync.")
                .font(Theme.ui(11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: List

    @ViewBuilder
    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if groupMode == .none {
                    ForEach(Array(prs.enumerated()), id: \.element.id) { idx, pr in
                        WindowPRRow(
                            pr: pr,
                            isSelected: selectedPRID == pr.id,
                            onSelect: { selectedPRID = pr.id }
                        )
                        if idx < prs.count - 1 {
                            Divider().opacity(0.35).padding(.leading, 18)
                        }
                    }
                } else {
                    ForEach(Array(groupedPRs().enumerated()), id: \.element.key) { gIdx, group in
                        Section {
                            ForEach(Array(group.prs.enumerated()), id: \.element.id) { idx, pr in
                                WindowPRRow(
                                    pr: pr,
                                    isSelected: selectedPRID == pr.id,
                                    onSelect: { selectedPRID = pr.id }
                                )
                                if idx < group.prs.count - 1 {
                                    Divider().opacity(0.35).padding(.leading, 18)
                                }
                            }
                        } header: {
                            groupHeader(group, isFirst: gIdx == 0)
                        }
                    }
                }
            }
        }
    }

    private struct PRGroup {
        let key: String
        let label: String
        let prs: [PR]
    }

    @ViewBuilder
    private func groupHeader(_ group: PRGroup, isFirst: Bool) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(groupAccent(group))
                .frame(width: 7, height: 7)
            Text(group.label)
                .font(Theme.mono(12, .semibold))
                .tracking(0.6)
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)
            Text("\(group.prs.count)")
                .font(Theme.mono(10, .medium))
                .foregroundColor(.secondary.opacity(0.8))
                .padding(.horizontal, 6)
                .padding(.vertical, 1.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.top, isFirst ? 10 : 20)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private func groupAccent(_ group: PRGroup) -> Color {
        // Neutral headers; only the changes-requested group is red.
        if groupMode == .status, group.prs.first?.status == .changes { return .red }
        return .secondary.opacity(0.6)
    }

    private func groupedPRs() -> [PRGroup] {
        var buckets: [(key: String, label: String, prs: [PR])] = []
        var seen: [String: Int] = [:]

        for pr in prs {
            let (key, label) = groupKey(for: pr)
            if let idx = seen[key] {
                buckets[idx].prs.append(pr)
            } else {
                seen[key] = buckets.count
                buckets.append((key, label, [pr]))
            }
        }
        buckets.sort { $0.key < $1.key }
        return buckets.map { PRGroup(key: $0.key, label: $0.label, prs: $0.prs) }
    }

    private func groupKey(for pr: PR) -> (String, String) {
        switch groupMode {
        case .none:
            return ("", "")
        case .status:
            return (String(format: "%d", pr.status.sortOrder), pr.status.label)
        case .repo:
            let label = "\(pr.org)/\(pr.repo)"
            return (label.lowercased(), label)
        case .org:
            return (pr.org.lowercased(), pr.org)
        }
    }
}

enum ListGroupMode: String, CaseIterable, Identifiable {
    case none, status, repo, org
    var id: String { rawValue }
    var label: String {
        switch self {
        case .none:   return "Flat"
        case .status: return "Status"
        case .repo:   return "Repo"
        case .org:    return "Org"
        }
    }
    var icon: String {
        switch self {
        case .none:   return "line.3.horizontal"
        case .status: return "circle.hexagongrid"
        case .repo:   return "folder"
        case .org:    return "building.2"
        }
    }
}

private extension PRStatus {
    var sortOrder: Int {
        switch self {
        case .changes:  return 0
        case .review:   return 1
        case .open:     return 2
        case .approved: return 3
        }
    }
}

// MARK: - Row

private struct WindowPRRow: View {
    let pr: PR
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovered = false
    @State private var copied = false
    @State private var checkingOut = false

    private var actionsVisible: Bool { hovered || isSelected || checkingOut }

    var body: some View {
        HStack(spacing: 0) {
            statusBar
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .clipped()
        .onHover { hovered = $0 }
        .onTapGesture { onSelect() }
    }

    private var statusBar: some View {
        // Only PRs waiting on changes get an edge — everything else is calm.
        Rectangle()
            .fill(pr.status == .changes ? Color.red : Color.clear)
            .frame(width: 3)
            .opacity(isSelected ? 1 : (statusEmphasized ? 0.85 : 0.6))
    }

    private var statusEmphasized: Bool {
        pr.status == .changes || pr.status == .approved
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(pr.title)
                    .font(Theme.ui(14, .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)
                    .help(pr.title)

                actionStrip
                    .opacity(actionsVisible ? 1 : 0)
                    .allowsHitTesting(actionsVisible)

                Text(relativeTime(pr.updatedAt))
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary.opacity(0.85))
                    .frame(width: 44, alignment: .trailing)
                    .help("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }

            // Scan line: where it lives and, at most, the one thing that
            // needs attention. Status is the left bar; everything else is
            // in the detail pane.
            HStack(spacing: 8) {
                repoLabel
                Text("#\(String(pr.number))")
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary.opacity(0.7))
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
                if let attention = RowAttention(pr: pr) {
                    attentionChip(attention)
                }
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    // MARK: chips

    private func attentionChip(_ a: RowAttention) -> some View {
        HStack(spacing: 4) {
            Icon(a.icon, size: 10)
            Text(a.label)
                .font(Theme.ui(11, .medium))
                .lineLimit(1)
        }
        .foregroundColor(a.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(a.tint.opacity(0.10)))
        .fixedSize()
        .help(a.help)
    }

    private var repoLabel: some View {
        HStack(spacing: 4) {
            (Text(pr.org + "/").foregroundColor(.secondary.opacity(0.6))
             + Text(pr.repo).foregroundColor(.secondary))
                .font(Theme.mono(11, .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(pr.org)/\(pr.repo)")
    }

    // MARK: action strip

    private var actionStrip: some View {
        HStack(spacing: 2) {
            RowIconButton(
                icon: "doc.on.doc",
                help: copied ? "Copied" : "Copy branch",
                tint: copied ? .green : nil,
                disabled: pr.branch.isEmpty
            ) {
                PRActions.copyToPasteboard(pr.branch)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
            }

            if checkingOut {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.65)
                    .frame(width: 22, height: 20)
                    .help("Setting up worktree…")
            } else {
                RowIconButton(
                    icon: ideGlyph,
                    help: "Open in \(Config.preferredIDE.displayName)"
                ) {
                    checkingOut = true
                    MainActor.assumeIsolated {
                        PRActions.checkoutAndOpen(pr: pr) { checkingOut = false }
                    }
                }
            }
        }
    }

    private var ideGlyph: String {
        // Use a generic editor glyph; the IDE-specific NSImage is too heavy
        // for a row affordance.
        "chevron.left.forwardslash.chevron.right"
    }

    // MARK: state

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.09) }
        if hovered    { return Color.primary.opacity(0.04) }
        return .clear
    }
}

// MARK: - Row icon button

private struct RowIconButton: View {
    let icon: String
    let help: String
    var tint: Color? = nil
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 11)
                .frame(width: 22, height: 20)
                .foregroundColor(foreground)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(hovered && !disabled ? Color.primary.opacity(0.1) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(disabled)
        .help(help)
    }

    private var foreground: Color {
        if disabled { return .secondary.opacity(0.4) }
        if let tint = tint { return tint }
        return hovered ? .primary : .secondary.opacity(0.8)
    }
}

/// The single most urgent condition on a PR, for its list row — or nil when
/// nothing needs attention. Ordered by what blocks the PR soonest.
struct RowAttention {
    let label: String
    let icon: String
    let tint: Color
    let help: String

    init?(pr: PR) {
        if pr.mergeableState == .dirty {
            self.init("Conflicts", "exclamationmark.triangle.fill", .red, "Merge conflicts with the base branch")
        } else if pr.checkStatus == .failure {
            let failed = pr.checks.filter { $0.rolled == .failure }.count
            self.init("CI failing", "xmark.octagon.fill", .red, "\(failed) of \(pr.checks.count) checks failing")
        } else if let entry = pr.merge?.queueEntry {
            self.init(entry.position <= 1 ? "Queued · next" : "Queued · #\(entry.position)", "list.number", mergePurple, "In the merge queue — \(entry.summary)")
        } else if pr.merge?.autoMerge != nil {
            self.init("Auto-merge", "clock.arrow.circlepath", mergePurple, "Merges once requirements pass")
        } else if pr.mergeableState == .blocked {
            self.init("Blocked", "lock.fill", .secondary, "Blocked by required reviews or branch protection")
        } else if pr.mergeableState == .behind {
            self.init("Behind base", "arrow.down.circle.fill", .secondary, "Base branch has moved ahead")
        } else if pr.checkStatus == .pending {
            self.init("CI running", "clock.fill", .secondary, "Checks still running")
        } else if pr.isDraft {
            self.init("Draft", "circle.dashed", .secondary, "Draft pull request")
        } else {
            return nil
        }
    }

    private init(_ label: String, _ icon: String, _ tint: Color, _ help: String) {
        self.label = label
        self.icon = icon
        self.tint = tint
        self.help = help
    }
}
