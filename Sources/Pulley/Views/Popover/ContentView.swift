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

    private var hasMultipleOrganizations: Bool {
        Set(store.prs.map(\.org)).count > 1
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
                    accent: status == .changes ? .red : Color.secondary.opacity(0.65),
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
                let title = hasMultipleOrganizations ? key : first.repo
                return Section(
                    id: "repo:\(key)",
                    title: title,
                    accent: Color.secondary.opacity(0.65),
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
                    accent: Color.secondary.opacity(0.65),
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
                    if let error = store.lastError {
                        SyncErrorBanner(message: error) { store.sync() }
                    }
                    Divider()
                    FilterRow(
                        query: $query,
                        scope: $scope,
                        groupBy: $groupBy,
                        hasMultipleOrganizations: hasMultipleOrganizations,
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
                        hasMultipleOrganizations: hasMultipleOrganizations,
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
            if !store.isMockData && (!Config.hasToken || Config.orgs.isEmpty) {
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
                  orderedPRs.contains(where: { $0.id == id })
            else { return }
            if expandedPRs.contains(id) { expandedPRs.remove(id) }
            else                         { expandedPRs = [id] }
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

    var body: some View {
        HStack(spacing: 8) {
            Text("PULLEY")
                .font(Theme.mono(11, .semibold))
                .tracking(1)
                .foregroundColor(.primary)

            if !store.prs.isEmpty {
                Text("·").foregroundColor(.secondary)
                Text("\(store.prs.count) PR\(store.prs.count == 1 ? "" : "s")")
                    .font(Theme.mono(10))
                    .foregroundColor(.secondary)
            }

            if store.isMockData {
                Text("PREVIEW")
                    .font(Theme.mono(8, .semibold))
                    .tracking(0.5)
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer()

            if store.syncing {
                Text("Syncing…")
                    .font(Theme.mono(10))
                    .foregroundColor(.secondary)
            } else if let t = store.lastSync {
                HStack(spacing: 4) {
                    Icon("checkmark", size: 9)
                    Text(t.formatted(.dateTime.hour().minute()))
                }
                .font(Theme.mono(10))
                .foregroundColor(.secondary)
            }

            Button(action: { store.sync() }) {
                if store.syncing {
                    ProgressView().controlSize(.small)
                } else {
                    Icon("arrow.clockwise", size: 13)
                }
            }
            .buttonStyle(.borderless)
            .disabled(store.syncing)
            .help("Sync now")

            Menu {
                Button {
                    NotificationCenter.default.post(name: .pulleyOpenMainWindow, object: nil)
                } label: {
                    Label("Open main window", systemImage: "macwindow")
                }

                Button { showSettings = true } label: {
                    Label("Settings…", systemImage: "gearshape")
                }

                Divider()

                Button { NSApp.terminate(nil) } label: {
                    Label("Quit Pulley", systemImage: "power")
                }
            } label: {
                Icon("ellipsis.circle", size: 14)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More options")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct SyncErrorBanner: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Icon("exclamationmark.triangle.fill", size: 10)
                .foregroundColor(.red)
            Text("Couldn't refresh pull requests")
                .font(Theme.ui(11, .medium))
                .foregroundColor(.primary)
            Spacer(minLength: 8)
            Button("Retry", action: retry)
                .buttonStyle(.borderless)
                .font(Theme.ui(11, .semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.07))
        .help(message)
    }
}

// MARK: - Filter row

private struct FilterRow: View {
    @Binding var query: String
    @Binding var scope: Scope
    @Binding var groupBy: GroupBy
    let hasMultipleOrganizations: Bool
    var searchFocused: FocusState<Bool>.Binding
    let onScopeChange: () -> Void
    let onGroupByChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Icon("magnifyingglass", size: 10)
                    .foregroundColor(.secondary.opacity(0.75))
                TextField("Find pull requests", text: $query)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12))
                    .focused(searchFocused)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Icon("xmark.circle.fill", size: 10)
                            .foregroundColor(.secondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
            )

            Menu {
                SwiftUI.Section("Group by") {
                    ForEach(availableGroups) { option in
                        Button {
                            groupBy = option
                            onGroupByChange()
                        } label: {
                            Label(option.menuLabel, systemImage: groupBy == option ? "checkmark" : option.icon)
                        }
                    }
                }

                SwiftUI.Section("Pull requests") {
                    ForEach(Scope.allCases) { option in
                        Button {
                            scope = option
                            onScopeChange()
                        } label: {
                            Label(option.label, systemImage: scope == option ? "checkmark" : "person.crop.circle")
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Icon(groupBy.icon, size: 10)
                    Text(groupBy.menuLabel)
                        .font(Theme.ui(11, .medium))
                    Icon("chevron.down", size: 8)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("View and scope options")
        }
    }

    private var availableGroups: [GroupBy] {
        hasMultipleOrganizations ? [.status, .repo, .org] : [.status, .repo]
    }
}

// MARK: - List body

private struct ListBody: View {
    let sections: [Section]
    let groupBy: GroupBy
    let hasMultipleOrganizations: Bool
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
                                showRepoChip: groupBy != .repo,
                                showStatus:   groupBy != .status,
                                showOrgPrefix: hasMultipleOrganizations,
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
                    .frame(maxWidth: .infinity, alignment: .leading)
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
            .font(Theme.mono(11))
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
    let showOrgPrefix: Bool
    let isCollapsed: Bool
    let onToggle: () -> Void
    @Binding var selectedPRID: String?
    @Binding var expandedPRs: Set<String>

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(section.accent.opacity(0.85))
                        .frame(width: 7, height: 7)
                    Text(section.title)
                        .font(Theme.mono(11, .medium))
                        .tracking(0.4)
                        .foregroundColor(.primary)
                    Text("\(section.prs.count)")
                        .font(Theme.mono(10))
                        .foregroundColor(.secondary)
                    Spacer()
                    Icon(isCollapsed ? "chevron.right" : "chevron.down", size: 9)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !isCollapsed {
                VStack(spacing: 0) {
                    ForEach(Array(section.prs.enumerated()), id: \.element.id) { idx, pr in
                        PRRow(
                            pr: pr,
                            showRepo: showRepoChip,
                            showStatus: showStatus,
                            showOrgPrefix: showOrgPrefix,
                            isSelected: selectedPRID == pr.id,
                            isExpanded: Binding(
                                get: { expandedPRs.contains(pr.id) },
                                set: { on in
                                    if on {
                                        expandedPRs = [pr.id]
                                        selectedPRID = pr.id
                                    } else {
                                        expandedPRs.remove(pr.id)
                                    }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - PR row

private struct PRRow: View {
    let pr: PR
    let showRepo: Bool
    let showStatus: Bool
    let showOrgPrefix: Bool
    let isSelected: Bool
    @Binding var isExpanded: Bool
    let onSelect: () -> Void
    @State private var hovered = false
    @State private var copiedLink = false
    @State private var copiedBranch = false
    @State private var checkingOut = false

    private var hasChecks: Bool { !pr.checks.isEmpty }
    private var quickActionsVisible: Bool {
        hovered || isSelected || copiedLink || copiedBranch
    }
    private var disclosureVisible: Bool { hovered || isSelected || isExpanded }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // The collapsed row is deliberately for scanning: title, age,
            // grouping context, and exceptional conditions only.
            HStack(spacing: 6) {
                Button {
                    onSelect()
                    withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
                } label: {
                    Text(pr.title)
                        .font(Theme.ui(13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .help(pr.title)
                }
                .buttonStyle(.plain)

                HStack(spacing: 1) {
                    QuickCopyButton(
                        icon: copiedLink ? "checkmark" : "link",
                        copied: copiedLink,
                        help: copiedLink ? "PR link copied" : "Copy PR link"
                    ) {
                        onSelect()
                        PRActions.copyToPasteboard(pr.url.absoluteString)
                        copiedLink = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedLink = false }
                    }

                    if !pr.branch.isEmpty {
                        QuickCopyButton(
                            icon: copiedBranch ? "checkmark" : "doc.on.doc",
                            copied: copiedBranch,
                            help: copiedBranch ? "Branch copied" : "Copy branch"
                        ) {
                            onSelect()
                            PRActions.copyToPasteboard(pr.branch)
                            copiedBranch = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copiedBranch = false }
                        }
                    }
                }
                .opacity(quickActionsVisible ? 1 : 0)
                .allowsHitTesting(quickActionsVisible)
                .animation(.easeOut(duration: 0.1), value: quickActionsVisible)

                Text(relativeTime(pr.updatedAt))
                    .font(Theme.mono(10))
                    .foregroundColor(.secondary)
                    .help("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")

                Button {
                    onSelect()
                    withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
                } label: {
                    Icon(isExpanded ? "chevron.up" : "chevron.down", size: 8)
                        .foregroundColor(.secondary.opacity(0.7))
                        .frame(width: 16, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Collapse PR" : "Show PR actions")
                .opacity(disclosureVisible ? 1 : 0)
                .allowsHitTesting(disclosureVisible)
                .animation(.easeOut(duration: 0.1), value: disclosureVisible)
            }

            // Conditions stay visible because they determine what needs
            // attention. Branch and actions move into the selected state.
            HStack(spacing: 8) {
                if hasChecks {
                    CheckStatusDot(
                        status: pr.checkStatus,
                        count: pr.checks.count,
                        expanded: isExpanded
                    ) {
                        onSelect()
                        withAnimation(.easeInOut(duration: 0.12)) { isExpanded.toggle() }
                    }
                }

                if pr.mergeableState.isActionable && pr.mergeableState != .unstable {
                    MergeableChip(state: pr.mergeableState)
                }
                MergeFlowChip(pr: pr)
                StackChip(pr: pr)

                if showRepo {
                    RepoChip(
                        repo: pr.repo,
                        orgPrefix: showOrgPrefix ? pr.org : nil
                    )
                }
                if showStatus {
                    StatusInline(status: pr.status)
                }

                if pr.isDraft {
                    MutedChip(text: "draft")
                        .help("Draft PR")
                }

                Spacer(minLength: 0)
            }

            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.65) : Color.clear,
                    lineWidth: 1
                )
                .padding(.horizontal, 4)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.55)

            HStack(spacing: 6) {
                if !pr.branch.isEmpty {
                    Icon("arrow.triangle.branch", size: 9)
                    Text(pr.branch)
                        .font(Theme.mono(10))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(pr.branch)
                }
                Spacer(minLength: 6)
                Text("#\(String(pr.number))")
                    .font(Theme.mono(9))
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .foregroundColor(.secondary)

            HStack(spacing: 5) {
                RowActionButton(title: "Open PR", icon: "arrow.up.right.square") {
                    PRActions.openInBrowser(pr.url)
                }

                if checkingOut {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small)
                        Text("Preparing…")
                    }
                    .font(Theme.ui(10, .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity)
                } else {
                    RowActionButton(
                        title: Config.preferredIDE.displayName,
                        icon: "chevron.left.forwardslash.chevron.right"
                    ) {
                        checkingOut = true
                        // Button actions run on the main thread, but Swift 5.10
                        // doesn't infer that for a helper property like this.
                        MainActor.assumeIsolated {
                            PRActions.checkoutAndOpen(pr: pr) { checkingOut = false }
                        }
                    }
                }
            }

            if hasChecks {
                ChecksList(checks: pr.checks)
            }
        }
        .padding(.top, 2)
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.07) }
        if hovered    { return Color.primary.opacity(0.04) }
        return Color.clear
    }
}

private struct QuickCopyButton: View {
    let icon: String
    let copied: Bool
    let help: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Icon(icon, size: 9)
                .foregroundColor(copied ? .green : .secondary.opacity(hovered ? 1 : 0.75))
                .frame(width: 20, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.09 : 0.045))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
    }
}

private struct RowActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(Theme.ui(10, .medium))
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(hovered ? 0.09 : 0.055))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
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
                Icon(glyph, size: 9)
                    .foregroundColor(color)
                Text("\(count)")
                    .font(Theme.mono(9))
                    .foregroundColor(color.opacity(0.85))
                Icon(expanded ? "chevron.up" : "chevron.down", size: 7)
                    .foregroundColor(.secondary.opacity(0.7))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(color.opacity(hovered ? 0.12 : 0.08))
            )
            .overlay(
                Capsule().stroke(color.opacity(0.18), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("CI \(status.label) — click for detail")
    }

    private var glyph: String { checkGlyph(status) }
    private var color: Color  { popoverCheckColor(status) }
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
                Icon(glyph, size: 9)
                    .foregroundColor(color)
                    .frame(width: 12)
                Text(check.name)
                    .font(Theme.ui(11))
                    .foregroundColor(.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Text(check.stateLabel)
                    .font(Theme.mono(9))
                    .foregroundColor(color.opacity(0.9))
                if check.url != nil {
                    Icon("arrow.up.right.square", size: 9)
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

    private var glyph: String { checkGlyph(check.rolled) }
    private var color: Color  { popoverCheckColor(check.rolled) }
}

// MARK: - Chips

private struct RepoChip: View {
    let repo: String
    /// When non-nil, rendered as a dim "<org>/" prefix so repos sharing a name
    /// across orgs stay distinguishable.
    let orgPrefix: String?

    var body: some View {
        HStack(spacing: 4) {
            Icon("folder", size: 8)
                .foregroundColor(.secondary.opacity(0.75))
            Group {
                if let orgPrefix {
                    (Text(orgPrefix + "/").foregroundColor(.primary.opacity(0.45))
                     + Text(repo).foregroundColor(.primary.opacity(0.75)))
                        .font(Theme.mono(10, .medium))
                } else {
                    Text(repo)
                        .font(Theme.mono(10, .medium))
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
                .fill(Color.primary.opacity(0.055))
        )
        .overlay(
            Capsule()
                .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
        )
        .fixedSize()
        .help(orgPrefix.map { "Repo: \($0)/\(repo)" } ?? "Repo: \(repo)")
    }
}

private struct StatusInline: View {
    let status: PRStatus

    var body: some View {
        Text(statusLabel(status).lowercased())
            .font(Theme.mono(10, .medium))
            .foregroundColor(status == .changes ? .red : .secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.055)))
            .fixedSize()
            .help(statusLabel(status))
    }
}

private struct MergeableChip: View {
    let state: MergeableState

    var body: some View {
        HStack(spacing: 3) {
            Icon(glyph, size: 9)
            Text(state.label)
                .font(Theme.mono(10, .medium))
                .lineLimit(1)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.09)))
        .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 0.5))
        .fixedSize()
        .help(helpText)
    }

    private var glyph: String { mergeableGlyph(state) }
    private var color: Color {
        // Only conflicts block the author outright; the rest are waiting states.
        state == .dirty ? .red : .secondary
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
            .font(Theme.mono(9, .medium))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            .fixedSize()
    }
}

// MARK: - Helpers

private extension GroupBy {
    var menuLabel: String {
        switch self {
        case .status: return "Status"
        case .repo:   return "Repository"
        case .org:    return "Organization"
        }
    }

    var icon: String {
        switch self {
        case .status: return "circle.grid.2x2"
        case .repo:   return "folder"
        case .org:    return "building.2"
        }
    }
}

/// The popover reserves color for conditions that need attention. Passing,
/// neutral, and absent checks remain distinguishable by glyph without adding
/// another persistent accent to every row.
private func popoverCheckColor(_ status: CheckStatus) -> Color {
    status == .failure ? .red : .secondary
}

private func statusLabel(_ s: PRStatus) -> String {
    switch s {
    case .changes:  return "Changes requested"
    case .approved: return "Approved"
    case .review:   return "In review"
    case .open:     return "Open"
    }
}
