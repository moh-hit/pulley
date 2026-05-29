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
        .background(Color(NSColor.textBackgroundColor))
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary.opacity(0.45))
            Text("Nothing here")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Try a different filter or sync.")
                .font(.system(size: 11))
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
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundColor(.primary.opacity(0.9))
                .lineLimit(1)
            Text("\(group.prs.count)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
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
        .background(Color(NSColor.textBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 0.5)
        }
    }

    private func groupAccent(_ group: PRGroup) -> Color {
        switch groupMode {
        case .none:
            return .accentColor
        case .status:
            return group.prs.first.map { statusColor($0.status) } ?? .accentColor
        case .repo, .org:
            return colorForRepo(group.label)
        }
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
    @State private var checksExpanded = false

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
        Rectangle()
            .fill(statusColor(pr.status))
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
                    .font(.system(size: 14, weight: .medium))
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
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.85))
                    .frame(width: 44, alignment: .trailing)
                    .help("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
            }

            HStack(spacing: 8) {
                statusChip
                if !pr.checks.isEmpty {
                    checksChip
                }
                if pr.mergeableState.isActionable {
                    mergeChip
                }
                if pr.isDraft {
                    draftChip
                }

                repoLabel

                if !pr.branch.isEmpty {
                    branchInline
                }

                Spacer(minLength: 0)

                Text("#\(pr.number)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.55))
                    .lineLimit(1)
                    .fixedSize()
            }

            if checksExpanded && !pr.checks.isEmpty {
                ChecksInline(checks: pr.checks)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, 11)
    }

    // MARK: chips

    private var statusChip: some View {
        Text(pr.status.label.lowercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(statusColor(pr.status))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(statusColor(pr.status).opacity(0.13))
            )
            .fixedSize()
    }

    private var checksChip: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { checksExpanded.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: checkGlyph(pr.checkStatus))
                    .font(.system(size: 9, weight: .semibold))
                Text("\(pr.checks.count)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                Image(systemName: checksExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundColor(checkColor(pr.checkStatus).opacity(0.7))
            }
            .foregroundColor(checkColor(pr.checkStatus))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(checkColor(pr.checkStatus).opacity(0.12)))
            .overlay(
                Capsule().stroke(checkColor(pr.checkStatus).opacity(checksExpanded ? 0.4 : 0), lineWidth: 0.5)
            )
            .fixedSize()
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("CI: \(pr.checkStatus.label) — \(pr.checks.count) checks")
    }

    private var mergeChip: some View {
        let c = mergeableColor(pr.mergeableState)
        return HStack(spacing: 3) {
            Image(systemName: mergeableGlyph(pr.mergeableState))
                .font(.system(size: 9, weight: .semibold))
            Text(pr.mergeableState.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundColor(c)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.12)))
        .fixedSize()
    }

    private var draftChip: some View {
        Text("draft")
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()
    }

    private var repoLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForRepo(pr.repo))
                .frame(width: 6, height: 6)
            (Text(pr.org + "/").foregroundColor(.secondary.opacity(0.6))
             + Text(pr.repo).foregroundColor(.secondary))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 150, alignment: .leading)
        .help("\(pr.org)/\(pr.repo)")
    }

    private var branchInline: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
                .layoutPriority(1)
            Text(pr.branch)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(pr.branch)
        }
        .foregroundColor(.secondary.opacity(0.75))
        .frame(maxWidth: 110, alignment: .leading)
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

// MARK: - Inline checks list

private struct ChecksInline: View {
    let checks: [CheckRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(checks) { c in
                ChecksInlineRow(check: c)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct ChecksInlineRow: View {
    let check: CheckRun
    @State private var hovered = false

    var body: some View {
        Button {
            if let url = check.url { PRActions.openInBrowser(url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: checkGlyph(check.rolled))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(checkColor(check.rolled))
                    .frame(width: 12)
                Text(check.name)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 6)
                Text(check.stateLabel)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(checkColor(check.rolled).opacity(0.9))
                if check.url != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(hovered ? 0.9 : 0.35))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(hovered ? Color.primary.opacity(0.05) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(check.url == nil)
        .help(check.url == nil ? check.name : "\(check.name) — open")
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
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
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
