import SwiftUI
import AppKit

// PR sections, ordered by user urgency:
// 1. Changes requested — must fix to unblock
// 2. Approved — can merge now
// 3. In review — waiting on others
// 4. Open — not started / drafts
private let statusOrder: [PRStatus] = [.changes, .approved, .review, .open]

// MARK: - Section

private struct Section: Identifiable {
    let id: String
    let title: String
    let accent: Color
    let prs: [PR]
}

// MARK: - Root view

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var query: String = ""
    @State private var scope: Scope = Config.scope
    @State private var groupBy: GroupBy = Config.groupBy
    @State private var showSettings: Bool = false
    @State private var collapsed: Set<String> = []
    @State private var selectedPRID: String? = nil
    @State private var expandedPRs: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var filteredPRs: [PR] {
        guard !query.isEmpty else { return store.prs }
        let q = query.lowercased()
        return store.prs.filter {
            ($0.title + " " + $0.repo + " " + $0.branch + " " + ($0.assignee ?? "")).lowercased().contains(q)
        }
    }

    private var sections: [Section] {
        switch groupBy {
        case .status:
            let grouped = Dictionary(grouping: filteredPRs, by: { $0.status })
            return statusOrder.compactMap { status in
                let list = (grouped[status] ?? []).sorted { $0.updatedAt > $1.updatedAt }
                guard !list.isEmpty else { return nil }
                return Section(
                    id: "status:\(status.rawValue)",
                    title: statusLabel(status),
                    accent: statusColor(status),
                    prs: list
                )
            }
        case .repo:
            // Key by "org/repo" so identical repo names across orgs don't collapse.
            let grouped = Dictionary(grouping: filteredPRs, by: { "\($0.org)/\($0.repo)" })
            return grouped.keys.sorted().compactMap { key in
                let list = (grouped[key] ?? []).sorted { a, b in
                    let pa = statusOrder.firstIndex(of: a.status) ?? 99
                    let pb = statusOrder.firstIndex(of: b.status) ?? 99
                    if pa != pb { return pa < pb }
                    return a.updatedAt > b.updatedAt
                }
                guard !list.isEmpty, let first = list.first else { return nil }
                // Show plain repo name when only one org configured.
                let title = Config.orgs.count > 1 ? key : first.repo
                return Section(
                    id: "repo:\(key)",
                    title: title,
                    accent: colorForRepo(first.repo),
                    prs: list
                )
            }
        case .org:
            let grouped = Dictionary(grouping: filteredPRs, by: { $0.org })
            return grouped.keys.sorted().compactMap { org in
                let list = (grouped[org] ?? []).sorted { a, b in
                    let pa = statusOrder.firstIndex(of: a.status) ?? 99
                    let pb = statusOrder.firstIndex(of: b.status) ?? 99
                    if pa != pb { return pa < pb }
                    return a.updatedAt > b.updatedAt
                }
                guard !list.isEmpty else { return nil }
                return Section(
                    id: "org:\(org)",
                    title: org,
                    accent: colorForRepo(org),
                    prs: list
                )
            }
        }
    }

    var body: some View {
        Group {
            if showSettings {
                // Render in place of the main UI rather than as a SwiftUI sheet.
                // Sheets inside NSPopover strand their modal session when the
                // popover dismisses, freezing input on reopen — swapping content
                // sidesteps that interaction entirely.
                SettingsView(onClose: {
                    showSettings = false
                    scope = Config.scope        // pick up scope change if user edited it
                })
                .environmentObject(store)
            } else {
                VStack(spacing: 0) {
                    HeaderView(showSettings: $showSettings)
                    Divider()
                    FilterRow(
                        query: $query,
                        scope: $scope,
                        groupBy: $groupBy,
                        searchFocused: $searchFocused,
                        onScopeChange:   { Config.scope   = scope;   store.sync() },
                        onGroupByChange: { Config.groupBy = groupBy }
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    Divider()
                    ListBody(
                        sections: sections,
                        groupBy: groupBy,
                        collapsed: $collapsed,
                        hasAnyPRs: !store.prs.isEmpty,
                        selectedPRID: $selectedPRID,
                        expandedPRs: $expandedPRs
                    )
                }
            }
        }
        .frame(width: 460, height: 520)
        .onAppear {
            scope   = Config.scope
            groupBy = Config.groupBy
            // Use hasToken (UserDefaults) so checking "is the app configured?"
            // doesn't trigger a Keychain prompt before the user does anything.
            if !Config.hasToken || Config.orgs.isEmpty {
                showSettings = true
            }
        }
        // Keyboard navigation — driven by NSEvent monitor in AppDelegate.
        .onReceive(NotificationCenter.default.publisher(for: .pulleyMoveSelection)) { note in
            let delta = (note.userInfo?["delta"] as? Int) ?? 1
            moveSelection(by: delta)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyOpenSelectedInBrowser)) { _ in
            if let pr = selectedPR { PRActions.openInBrowser(pr.url) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyCheckoutSelected)) { _ in
            if let pr = selectedPR { PRActions.checkoutAndOpen(pr: pr) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyCopySelectedBranch)) { _ in
            if let pr = selectedPR, !pr.branch.isEmpty {
                PRActions.copyToPasteboard(pr.branch)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyToggleSelectedExpand)) { _ in
            guard let id = selectedPRID,
                  let pr = orderedPRs.first(where: { $0.id == id }),
                  !pr.checks.isEmpty
            else { return }
            if expandedPRs.contains(id) { expandedPRs.remove(id) }
            else                         { expandedPRs.insert(id) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyFocusSearch)) { _ in
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyOpenSettings)) { _ in
            showSettings = true
        }
    }

    /// Flatten visible PR list in display order so keyboard motion is intuitive.
    private var orderedPRs: [PR] {
        sections.flatMap { $0.prs }
    }

    private var selectedPR: PR? {
        guard let id = selectedPRID else { return nil }
        return orderedPRs.first { $0.id == id }
    }

    private func moveSelection(by delta: Int) {
        let list = orderedPRs
        guard !list.isEmpty else { return }
        if let id = selectedPRID, let i = list.firstIndex(where: { $0.id == id }) {
            let next = max(0, min(list.count - 1, i + delta))
            selectedPRID = list[next].id
        } else {
            selectedPRID = list[delta >= 0 ? 0 : list.count - 1].id
        }
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject var store: Store
    @Binding var showSettings: Bool

    private var totalOpen: Int {
        store.prs.filter { $0.status != .approved }.count
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("PULLEY")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundColor(.accentColor)

            if !store.prs.isEmpty {
                Text("·").foregroundColor(.secondary)
                Text("\(totalOpen) open")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            Spacer()

            if let err = store.lastError {
                Text(truncate(err, 28))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.red)
                    .help(err)
            } else if let t = store.lastSync {
                (Text("✓ ").foregroundColor(.green)
                 + Text(t.formatted(.dateTime.hour().minute())).foregroundColor(.secondary))
                    .font(.system(size: 10, design: .monospaced))
            }

            Button(action: { store.sync() }) {
                if store.syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.syncing)
            .help("Sync now")

            Button(action: {
                NotificationCenter.default.post(name: .pulleyOpenMainWindow, object: nil)
            }) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open window (⌘O)")

            Button(action: { showSettings = true }) {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("Settings")

            Button(action: { NSApp.terminate(nil) }) {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Pulley")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        s.count <= n ? s : String(s.prefix(n)) + "…"
    }
}

// MARK: - Filter row

private struct FilterRow: View {
    @Binding var query: String
    @Binding var scope: Scope
    @Binding var groupBy: GroupBy
    var searchFocused: FocusState<Bool>.Binding
    let onScopeChange: () -> Void
    let onGroupByChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search…", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .focused(searchFocused)

            Picker("", selection: $groupBy) {
                Text("Status").tag(GroupBy.status)
                Text("Repo").tag(GroupBy.repo)
                if Config.orgs.count > 1 {
                    Text("Org").tag(GroupBy.org)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: Config.orgs.count > 1 ? 150 : 110)
            .help("Group PRs")
            .onChange(of: groupBy) { _ in onGroupByChange() }

            Picker("", selection: $scope) {
                ForEach(Scope.allCases) { s in
                    Text(s.label).tag(s)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            .controlSize(.small)
            .onChange(of: scope) { _ in onScopeChange() }
        }
    }
}

// MARK: - List body

private struct ListBody: View {
    let sections: [Section]
    let groupBy: GroupBy
    @Binding var collapsed: Set<String>
    let hasAnyPRs: Bool
    @Binding var selectedPRID: String?
    @Binding var expandedPRs: Set<String>

    var body: some View {
        if !hasAnyPRs {
            EmptyState(message: "No PRs yet — try a different scope or sync.")
        } else if sections.isEmpty {
            EmptyState(message: "No PRs match your search.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(sections) { section in
                            SectionView(
                                section: section,
                                showRepoChip: groupBy == .status,
                                showStatus:   groupBy == .repo,
                                isCollapsed:  collapsed.contains(section.id),
                                onToggle:     { toggle(section.id) },
                                selectedPRID: $selectedPRID,
                                expandedPRs:  $expandedPRs
                            )
                        }
                        Color.clear.frame(height: 4)
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .onChange(of: selectedPRID) { id in
                    guard let id else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if collapsed.contains(id) { collapsed.remove(id) }
        else                      { collapsed.insert(id) }
    }
}

private struct EmptyState: View {
    let message: String
    var body: some View {
        Text(message)
            .font(.system(size: 11, design: .monospaced))
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
    }
}

// MARK: - Section

private struct SectionView: View {
    let section: Section
    let showRepoChip: Bool
    let showStatus: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    @Binding var selectedPRID: String?
    @Binding var expandedPRs: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(section.accent)
                        .frame(width: 7, height: 7)
                    Text(section.title)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .tracking(0.4)
                        .foregroundColor(.primary)
                    Text("\(section.prs.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    Spacer()
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(section.prs.enumerated()), id: \.element.id) { idx, pr in
                        PRRow(
                            pr: pr,
                            showRepo: showRepoChip,
                            showStatus: showStatus,
                            isSelected: selectedPRID == pr.id,
                            isExpanded: Binding(
                                get: { expandedPRs.contains(pr.id) },
                                set: { on in
                                    if on { expandedPRs.insert(pr.id) }
                                    else  { expandedPRs.remove(pr.id) }
                                }
                            ),
                            onSelect: { selectedPRID = pr.id }
                        )
                        .id(pr.id)
                        if idx < section.prs.count - 1 {
                            Divider().padding(.leading, 11)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - PR row

private struct PRRow: View {
    let pr: PR
    let showRepo: Bool
    let showStatus: Bool
    let isSelected: Bool
    @Binding var isExpanded: Bool
    let onSelect: () -> Void
    @State private var hovered = false
    @State private var copied = false
    @State private var checkingOut = false

    private var hasChecks: Bool { !pr.checks.isEmpty }

    /// Show row actions only when user is engaging with this row.
    /// Cuts visual noise on the long list while keeping ops one hover away.
    private var actionsVisible: Bool { hovered || isSelected || checkingOut }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Line 1: title + actions. Actions always occupy space so the
            // title doesn't re-truncate on hover.
            HStack(spacing: 8) {
                Text(pr.title)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundColor(.primary)
                    .help(pr.title)

                Spacer(minLength: 8)

                HStack(spacing: 0) {
                    ActionIcon(
                        icon: "arrow.up.right.square",
                        help: "Open PR in browser"
                    ) {
                        PRActions.openInBrowser(pr.url)
                    }

                    if checkingOut {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.6)
                            .frame(width: 22, height: 20)
                            .help("Setting up worktree…")
                    } else {
                        ActionIcon(
                            icon: "chevron.left.forwardslash.chevron.right",
                            help: "Checkout & open in \(Config.preferredIDE.displayName)"
                        ) {
                            checkingOut = true
                            PRActions.checkoutAndOpen(pr: pr) { checkingOut = false }
                        }
                    }
                }
                .opacity(actionsVisible ? 1 : 0)
                .allowsHitTesting(actionsVisible)
            }

            // Line 2: meta
            HStack(spacing: 8) {
                if hasChecks {
                    CheckStatusDot(
                        status: pr.checkStatus,
                        count: pr.checks.count,
                        expanded: isExpanded
                    ) {
                        withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
                    }
                }

                if pr.mergeableState.isActionable {
                    MergeableChip(state: pr.mergeableState)
                }

                if showRepo {
                    RepoChip(
                        repo: pr.repo,
                        orgPrefix: Config.orgs.count > 1 ? pr.org : nil
                    )
                }
                if showStatus {
                    StatusInline(status: pr.status)
                }

                if !pr.branch.isEmpty {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 9))
                        Text(pr.branch)
                            .font(.system(size: 10, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(pr.branch)
                        InlineCopyButton(text: pr.branch, copied: $copied)
                            .opacity(actionsVisible ? 1 : 0)
                            .allowsHitTesting(actionsVisible)
                    }
                    .foregroundColor(.secondary)
                }

                if pr.isDraft {
                    MutedChip(text: "draft")
                        .help("Draft PR")
                }

                Spacer(minLength: 8)

                Text(relativeTime(pr.updatedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .help("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                Text("#\(pr.number)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.55))
                    .help("PR #\(pr.number)")
            }

            if isExpanded && hasChecks {
                ChecksList(checks: pr.checks)
                    .padding(.top, 4)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.accentColor, lineWidth: isSelected ? 1.2 : 0)
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            onSelect()
            PRActions.openInBrowser(pr.url)
        }
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.10) }
        if hovered    { return Color.primary.opacity(0.04) }
        return Color.clear
    }
}

// MARK: - CI checks

private struct CheckStatusDot: View {
    let status: CheckStatus
    let count: Int
    let expanded: Bool
    let onTap: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 3) {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
                Text("\(count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color.opacity(0.85))
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(hovered ? 0.18 : 0.12))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.3), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("CI \(status.label) — click for detail")
    }

    private var glyph: String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .neutral: return "minus.circle.fill"
        case .none:    return "circle"
        }
    }

    private var color: Color {
        switch status {
        case .success: return .green
        case .failure: return .red
        case .pending: return .orange
        case .neutral: return .secondary
        case .none:    return .secondary
        }
    }
}

private struct ChecksList: View {
    let checks: [CheckRun]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(checks) { check in
                CheckRow(check: check)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

private struct CheckRow: View {
    let check: CheckRun
    @State private var hovered = false

    var body: some View {
        Button {
            if let url = check.url { PRActions.openInBrowser(url) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(color)
                    .frame(width: 12)
                Text(check.name)
                    .font(.system(size: 11))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(stateLabel)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(color.opacity(0.9))
                if check.url != nil {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary.opacity(hovered ? 1 : 0.4))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(hovered ? Color.primary.opacity(0.05) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .disabled(check.url == nil)
        .help(check.url == nil ? check.name : "\(check.name) — open")
    }

    private var glyph: String {
        switch check.rolled {
        case .success: return "checkmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        case .pending: return "clock.fill"
        case .neutral: return "minus.circle.fill"
        case .none:    return "circle"
        }
    }

    private var color: Color {
        switch check.rolled {
        case .success: return .green
        case .failure: return .red
        case .pending: return .orange
        case .neutral: return .secondary
        case .none:    return .secondary
        }
    }

    /// Compact label aligned with GitHub's wording.
    private var stateLabel: String {
        if check.status != "completed" { return check.status.replacingOccurrences(of: "_", with: " ") }
        return check.conclusion ?? "completed"
    }
}

// Tiny inline copy affordance — sized to sit next to the monospaced branch text.
private struct InlineCopyButton: View {
    let text: String
    @Binding var copied: Bool
    @State private var hovered = false

    var body: some View {
        Button {
            PRActions.copyToPasteboard(text)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 9, weight: .medium))
                .foregroundColor(copied ? .green : .secondary.opacity(hovered ? 1 : 0.65))
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(copied ? "Copied" : "Copy branch")
    }
}

// Small icon button used for the per-PR action row.
private struct ActionIcon: View {
    let icon: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 22, height: 20)
                .foregroundColor(
                    tint ?? (hovered ? .primary : .secondary.opacity(isEnabled ? 0.75 : 0.35))
                )
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered && isEnabled ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

// MARK: - Chips

private struct RepoChip: View {
    let repo: String
    /// When non-nil, rendered as a dim "<org>/" prefix so repos sharing a name
    /// across orgs stay distinguishable.
    let orgPrefix: String?

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForRepo(repo))
                .frame(width: 6, height: 6)
            Group {
                if let orgPrefix {
                    (Text(orgPrefix + "/").foregroundColor(.primary.opacity(0.45))
                     + Text(repo).foregroundColor(.primary.opacity(0.75)))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                } else {
                    Text(repo)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.primary.opacity(0.75))
                }
            }
            .lineLimit(1)
            .truncationMode(.middle)
        }
        .padding(.leading, 5)
        .padding(.trailing, 7)
        .padding(.vertical, 2)
        .background(
            Capsule()
                .fill(colorForRepo(repo).opacity(0.12))
        )
        .overlay(
            Capsule()
                .stroke(colorForRepo(repo).opacity(0.25), lineWidth: 0.5)
        )
        .fixedSize()
        .help(orgPrefix.map { "Repo: \($0)/\(repo)" } ?? "Repo: \(repo)")
    }
}

private struct StatusInline: View {
    let status: PRStatus

    var body: some View {
        Text(statusLabel(status).lowercased())
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(statusColor(status))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(statusColor(status).opacity(0.13)))
            .fixedSize()
            .help(statusLabel(status))
    }
}

private struct MergeableChip: View {
    let state: MergeableState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: glyph)
                .font(.system(size: 9, weight: .semibold))
            Text(state.label)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.13)))
        .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
        .fixedSize()
        .help(helpText)
    }

    private var glyph: String {
        switch state {
        case .dirty:    return "exclamationmark.triangle.fill"
        case .behind:   return "arrow.down.circle.fill"
        case .blocked:  return "lock.fill"
        case .unstable: return "exclamationmark.circle.fill"
        default:        return "circle"
        }
    }

    private var color: Color {
        switch state {
        case .dirty, .blocked: return .red
        case .behind:          return .orange
        case .unstable:        return .yellow
        default:               return .secondary
        }
    }

    private var helpText: String {
        switch state {
        case .dirty:    return "Merge conflicts — rebase or merge base"
        case .behind:   return "Branch is behind base — update from base"
        case .blocked:  return "Blocked by branch protection (required reviews / checks)"
        case .unstable: return "Mergeable but a required check is failing or pending"
        default:        return state.label
        }
    }
}

private struct MutedChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()
    }
}

// MARK: - Helpers

private func statusLabel(_ s: PRStatus) -> String {
    switch s {
    case .changes:  return "Changes requested"
    case .approved: return "Approved"
    case .review:   return "In review"
    case .open:     return "Open"
    }
}

private func statusColor(_ s: PRStatus) -> Color {
    switch s {
    case .changes:  return .red
    case .approved: return .green
    case .review:   return .orange
    case .open:     return .blue
    }
}

/// Stable per-repo color derived from a djb2 hash of the repo name.
private func colorForRepo(_ repo: String) -> Color {
    var h: UInt64 = 5381
    for byte in repo.utf8 { h = (h &* 33) &+ UInt64(byte) }
    let hue = Double(h % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}

private func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60      { return "now" }
    if s < 3600    { return "\(s / 60)m" }
    if s < 86400   { return "\(s / 3600)h" }
    let d = s / 86400
    if d < 30      { return "\(d)d" }
    if d < 365     { return "\(d / 30)mo" }
    return "\(d / 365)y"
}
