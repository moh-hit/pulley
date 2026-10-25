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
    @State private var groupBy: GroupBy = Config.groupBy
    @AppStorage(Config.hideDraftsInMenuBarKey) private var hideDrafts = false
    @State private var upNextIndex = 0
    @State private var showSettings: Bool = false
    @AppStorage(TextSize.key) private var textSizeRaw = TextSize.standard.rawValue
    @AppStorage(ListDensity.key) private var densityRaw = ListDensity.comfortable.rawValue
    @State private var collapsed: Set<String> = []
    @State private var selectedPRID: String? = nil
    @State private var expandedPRs: Set<String> = []
    @FocusState private var searchFocused: Bool

    /// Everything the popover lists, before search: drafts drop out when
    /// Settings hides them.
    private var visiblePRs: [PR] {
        hideDrafts ? store.prs.filter { !$0.isDraft } : store.prs
    }

    private var filteredPRs: [PR] {
        guard !query.isEmpty else { return visiblePRs }
        let q = query.lowercased()
        return visiblePRs.filter {
            ($0.title + " " + $0.repo + " " + $0.branch + " " + ($0.assignee ?? "")).lowercased().contains(q)
        }
    }

    private var hasMultipleOrganizations: Bool {
        Set(store.prs.map(\.org)).count > 1
    }

    /// Ranked on the whole tab, not the search results, so typing a query
    /// doesn't change what's suggested.
    private var upNextPicks: [UpNextPick] {
        UpNext.rank(visiblePRs, scope: store.scope, nudgedAt: store.nudgedAt)
    }

    /// The open tab counts what it actually lists; the others use the
    /// count-only search from the last sync (nil until there is one).
    private func tabCount(_ scope: Scope) -> Int? {
        if scope == store.scope { return store.syncing && visiblePRs.isEmpty ? nil : visiblePRs.count }
        return store.scopeCounts[scope]
    }

    private var emptyMessage: String? {
        if visiblePRs.isEmpty {
            if store.syncing { return "Loading…" }
            if !store.prs.isEmpty { return "Only drafts here, and Settings hides drafts in the menu bar." }
            switch store.scope {
            case .author:          return "You have no open pull requests."
            case .reviewRequested: return "No reviews are waiting on you."
            case .assignee:        return "Nothing is assigned to you."
            case .involves:        return "No open pull requests involve you."
            }
        }
        return sections.isEmpty ? "No PRs match your search." : nil
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
            if !store.isMockData && (!Config.hasToken || Config.orgs.isEmpty) {
                SetupPrompt()
            } else {
                VStack(spacing: 0) {
                    HeaderView(count: visiblePRs.count, showSettings: $showSettings)
                    if let error = store.lastError {
                        SyncErrorBanner(
                            problem: SyncProblem(raw: error),
                            onRetry: { store.sync() },
                            onOpenSettings: { showSettings = true }
                        )
                    }
                    ScopeTabs(selected: store.scope, count: tabCount, onSelect: selectScope)
                    FilterRow(
                        query: $query,
                        groupBy: $groupBy,
                        hasMultipleOrganizations: hasMultipleOrganizations,
                        searchFocused: $searchFocused,
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
                        emptyMessage: emptyMessage,
                        selectedPRID: $selectedPRID,
                        expandedPRs: $expandedPRs
                    )
                    Divider()
                    UpNextFooter(picks: upNextPicks, index: $upNextIndex)
                }
            }
        }
        .id("\(textSizeRaw)-\(densityRaw)")
        .frame(width: 460, height: 580)
        .onAppear {
            groupBy = Config.groupBy
            // Use hasToken (UserDefaults) so checking "is the app configured?"
            // doesn't trigger a Keychain prompt before the user does anything.
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
        .onReceive(NotificationCenter.default.publisher(for: .pulleySelectScope)) { note in
            guard let i = note.userInfo?["index"] as? Int, Scope.tabOrder.indices.contains(i) else { return }
            selectScope(Scope.tabOrder[i])
        }
        // A new list (sync, tab switch, drafts toggled) starts the
        // suggestions over from the top.
        .onChange(of: upNextPicks.map(\.id)) { _ in upNextIndex = 0 }
        // Settings opens in the main window; the gear and banners flip this.
        .onChange(of: showSettings) { show in
            guard show else { return }
            showSettings = false
            NotificationCenter.default.post(name: .pulleyOpenSettings, object: nil)
        }
    }

    private func selectScope(_ scope: Scope) {
        guard scope != store.scope else { return }
        selectedPRID = nil
        expandedPRs = []
        upNextIndex = 0
        store.switchScope(scope)
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
    let count: Int
    @Binding var showSettings: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("Pulley")
                .font(Theme.display(18))

            if count > 0 {
                Text("·").foregroundColor(.secondary)
                Text("\(count) PR\(count == 1 ? "" : "s")")
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary)
            }

            if store.isMockData {
                Text("PREVIEW")
                    .font(Theme.mono(11, .semibold))
                    .tracking(0.5)
                    .foregroundColor(.secondary.opacity(0.8))
            }

            Spacer()

            if store.syncing {
                Text("Syncing…")
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary)
            } else if let t = store.lastSync {
                HStack(spacing: 4) {
                    Icon("checkmark", size: 9)
                    Text(t.formatted(.dateTime.hour().minute()))
                }
                .font(Theme.mono(11))
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

// MARK: - Scope tabs

/// Which PRs the popover lists, as tabs above the search field. Underlined
/// like the detail pane's tabs; the full-width hairline under them doubles
/// as the divider below the header.
private struct ScopeTabs: View {
    let selected: Scope
    let count: (Scope) -> Int?
    let onSelect: (Scope) -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
            HStack(alignment: .bottom, spacing: 16) {
                ForEach(Array(Scope.tabOrder.enumerated()), id: \.element) { i, scope in
                    tab(scope, shortcut: i + 1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 2)
    }

    private func tab(_ scope: Scope, shortcut: Int) -> some View {
        let isSelected = scope == selected
        let n = count(scope)
        return Button { onSelect(scope) } label: {
            HStack(spacing: 5) {
                Text(scope.tabLabel)
                    .font(Theme.ui(12, isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? .primary : .secondary)
                if let n, n > 0 {
                    Text("\(n)")
                        .font(Theme.mono(10, .semibold))
                        .monospacedDigit()
                        .foregroundColor(isSelected ? .primary.opacity(0.85) : .secondary.opacity(0.8))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(isSelected ? 0.12 : 0.07)))
                }
            }
                .padding(.top, 4)
                .padding(.bottom, 8)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(isSelected ? Color.accentColor : Color.clear)
                        .frame(height: 2)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(scope.label)\(n.map { " · \($0) open" } ?? "") (⌘\(shortcut))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}

// MARK: - Filter row

private struct FilterRow: View {
    @Binding var query: String
    @Binding var groupBy: GroupBy
    let hasMultipleOrganizations: Bool
    var searchFocused: FocusState<Bool>.Binding
    let onGroupByChange: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Icon("magnifyingglass", size: 10)
                    .foregroundColor(.secondary.opacity(0.75))
                TextField("Search pull requests", text: $query)
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
                    .accessibilityLabel("Clear search")
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
            } label: {
                HStack(spacing: 5) {
                    Icon(groupBy.icon, size: 10)
                    Text(groupBy.menuLabel)
                        .font(Theme.ui(11, .medium))
                    Icon("chevron.down", size: 8)
                        .foregroundColor(.secondary)
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
            .help("Group pull requests")
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
    let emptyMessage: String?
    @Binding var selectedPRID: String?
    @Binding var expandedPRs: Set<String>

    var body: some View {
        if let emptyMessage {
            EmptyState(message: emptyMessage)
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
                .font(Theme.ui(12, .medium))
                .foregroundColor(.primary)
                    Text("\(section.prs.count)")
                        .font(Theme.mono(11))
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
    @EnvironmentObject var store: Store
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

                // The time and the disclosure chevron share one slot at the
                // trailing edge: time at rest, chevron on hover or while
                // expanded. Nothing is reserved, so both lines run full width.
                ZStack(alignment: .trailing) {
                    Text(relativeTime(pr.updatedAt))
                        .font(Theme.mono(11))
                        .foregroundColor(.secondary)
                        .help("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                        .opacity(disclosureVisible ? 0 : 1)

                    Button {
                        onSelect()
                        withAnimation(.easeOut(duration: 0.14)) { isExpanded.toggle() }
                    } label: {
                        Icon(isExpanded ? "chevron.up" : "chevron.down", size: 8)
                            .foregroundColor(.secondary)
                            .frame(width: 16, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Collapse PR" : "Show PR actions")
                    .accessibilityLabel(isExpanded ? "Collapse PR" : "Show PR actions")
                    .opacity(disclosureVisible ? 1 : 0)
                    .allowsHitTesting(disclosureVisible)
                }
                .animation(.easeOut(duration: 0.1), value: disclosureVisible)
            }

            // Same contract as the window list: where it lives, and at most
            // one chip for what needs attention. Branch, checks and actions
            // sit in the expanded row.
            HStack(spacing: 8) {
                if showRepo {
                    (Text(showOrgPrefix ? pr.org + "/" : "").foregroundColor(.secondary.opacity(0.75))
                     + Text(pr.repo).foregroundColor(.secondary))
                        .font(Theme.mono(11))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text("#\(String(pr.number))")
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary)
                    .fixedSize()
                if showStatus && pr.status == .changes {
                    Text(pr.status.label)
                        .font(Theme.ui(11, .medium))
                        .foregroundColor(.red)
                        .fixedSize()
                }
                if let size = pr.size {
                    SizeChip(size: size)
                }
                if let threads = pr.unresolvedThreads, threads > 0 {
                    HStack(spacing: 3) {
                        Icon("bubble.left", size: 9)
                        Text("\(threads)").font(Theme.mono(11))
                    }
                    .foregroundColor(.secondary)
                    .fixedSize()
                    .help("\(threads) unresolved review thread\(threads == 1 ? "" : "s")")
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(threads) unresolved review threads")
                }
                Spacer(minLength: 0)
                if let attention = RowAttention(pr: pr) {
                    AttentionChip(attention: attention)
                }
            }

            if isExpanded {
                expandedContent
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, Config.listDensity.rowPadding - 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .contextMenu {
            Button("Open on GitHub") { PRActions.openInBrowser(pr.url) }
            Button("Copy link") { PRActions.copyToPasteboard(pr.url.absoluteString) }
            if !pr.branch.isEmpty {
                Button("Copy branch") { PRActions.copyToPasteboard(pr.branch) }
            }
            Divider()
            Button("Mute \(pr.org)/\(pr.repo)") { store.mute(org: pr.org, repo: pr.repo) }
        }
    }

    /// Your PR, still waiting on reviewers: worth a nudge.
    private var canNudge: Bool {
        !pr.isTeammates && !(pr.pendingReviewers ?? []).isEmpty && (pr.status == .review || pr.status == .open)
    }

    /// A teammate's ready PR with nothing red or running.
    private var canApprove: Bool {
        pr.isTeammates && !pr.isDraft && pr.status != .approved
            && [.success, .neutral, .none].contains(pr.checkStatus) && pr.mergeableState != .dirty
    }

    /// Expanded: a few one-line facts (where it lives, who it's waiting on,
    /// open threads, CI), then actions at their natural width with the one
    /// that fits this PR first and in color.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 6) {
                if !pr.branch.isEmpty {
                    FactRow(icon: "arrow.triangle.branch") {
                        Text(pr.branch)
                            .font(Theme.mono(11))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(pr.branch)
                    }
                }
                if let pending = pr.pendingReviewers, !pending.isEmpty, !pr.isTeammates {
                    FactRow(icon: "hourglass") {
                        Text("Waiting on " + pending.map { r in
                            r.requestedAt.map { "\(r.mention) (\(relativeTime($0)))" } ?? r.mention
                        }.joined(separator: ", "))
                            .font(Theme.ui(11))
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let threads = pr.unresolvedThreads, threads > 0 {
                    FactRow(icon: "bubble.left") {
                        Text("\(threads) unresolved review thread\(threads == 1 ? "" : "s")")
                            .font(Theme.ui(11))
                    }
                }
                if hasChecks {
                    ChecksSummary(checks: pr.checks)
                }
            }

            HStack(spacing: 6) {
                if canNudge {
                    ConfirmActionButton(
                        title: "Nudge", confirmTitle: "Send nudge?", doneTitle: "Nudged", icon: "bell",
                        help: "Comment on the PR mentioning \(UpNext.reviewerList(pr.pendingReviewers ?? []))",
                        tint: .orange
                    ) { try await store.nudge(pr) }
                } else if canApprove {
                    ConfirmActionButton(
                        title: "Approve", confirmTitle: "Approve?", doneTitle: "Approved", icon: "checkmark",
                        help: "Approve without a comment" + (pr.size.map { " (\($0.label))" } ?? ""),
                        tint: .green
                    ) { try await store.approve(pr) }
                }

                RowActionButton(title: "Open PR", icon: "arrow.up.right.square") {
                    PRActions.openInBrowser(pr.url)
                }

                if checkingOut {
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.mini)
                        Text("Preparing…")
                    }
                    .font(Theme.ui(11, .medium))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 10)
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
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 2)
    }

    private var rowBackground: Color {
        if isSelected { return Theme.selection }
        if hovered    { return Color.primary.opacity(0.04) }
        return Color.clear
    }
}

/// "+362 −27" in GitHub's diff colors, on a quiet capsule.
private struct SizeChip: View {
    let size: PRSize

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(size.additions)").foregroundColor(.green)
            Text("−\(size.deletions)").foregroundColor(.red)
        }
        .font(Theme.mono(11, .medium))
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .fixedSize()
        .help("\(size.additions) added, \(size.deletions) removed across \(size.files) file\(size.files == 1 ? "" : "s")")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(size.additions) lines added, \(size.deletions) removed")
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
                .foregroundColor(copied ? .primary : .secondary.opacity(hovered ? 1 : 0.75))
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
        .accessibilityLabel(help)
    }
}

private struct RowActionButton: View {
    let title: String
    let icon: String
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Icon(icon, size: 10)
                Text(title).lineLimit(1)
            }
            .font(Theme.ui(11, .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
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

/// One line of the expanded row: a muted glyph and a short fact.
private struct FactRow<Content: View>: View {
    let icon: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 6) {
            Icon(icon, size: 9).frame(width: 12)
            content
            Spacer(minLength: 0)
        }
        .foregroundColor(.secondary)
    }
}

// MARK: - CI checks


/// CI as one line ("1 failing · 4 passed"), with only the checks that need
/// a look listed under it. Passing ones stay folded behind "Show all".
private struct ChecksSummary: View {
    let checks: [CheckRun]
    @State private var showAll = false

    private var needsLook: [CheckRun] {
        checks.filter { $0.rolled == .failure || $0.rolled == .pending }
    }

    private var summary: String {
        func n(_ s: CheckStatus) -> Int { checks.filter { $0.rolled == s }.count }
        let failing = n(.failure), running = n(.pending), passed = n(.success), skipped = n(.neutral)
        if failing + running + skipped == 0 {
            return passed == 1 ? "Check passed" : "All \(passed) checks passed"
        }
        var parts: [String] = []
        if failing > 0 { parts.append("\(failing) failing") }
        if running > 0 { parts.append("\(running) running") }
        if passed > 0  { parts.append("\(passed) passed") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        let rolled = rollupChecks(checks)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Icon(checkGlyph(rolled), size: 9)
                    .foregroundColor(popoverCheckColor(rolled))
                    .frame(width: 12)
                Text(summary)
                    .font(Theme.ui(11))
                    .foregroundColor(rolled == .failure ? .red : .secondary)
                Spacer(minLength: 6)
                if checks.count > needsLook.count {
                    Button(showAll ? "Hide passed" : "Show all \(checks.count)") {
                        withAnimation(.easeOut(duration: 0.12)) { showAll.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(Theme.ui(11))
                    .foregroundColor(.secondary)
                    // Match the check rows' inner padding so right edges align.
                    .padding(.trailing, 4)
                }
            }
            ForEach(showAll ? checks : needsLook) { check in
                CheckRow(check: check)
            }
            // Line the check glyphs up under the summary text.
            .padding(.leading, 14)
        }
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
                    .font(Theme.mono(11))
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

/// First run in the popover: one sentence and one button, which opens
/// Settings on the GitHub section in the main window.
private struct SetupPrompt: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Pulley")
                .font(Theme.display(30))
            Text("Connect GitHub to see the pull requests that need you.")
                .font(Theme.ui(13))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Connect GitHub") {
                NotificationCenter.default.post(name: .pulleyOpenSettings, object: SettingsSection.github)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
