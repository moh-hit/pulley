import AppKit
import SwiftUI
import Combine

/// Lazy-allocated main window. The app normally runs as a menu-bar
/// `.accessory`; while this window is showing we flip the activation policy
/// to `.regular` so it behaves like a real app — dock icon, app menu,
/// keyboard focus, Cmd-Tab. On close we drop back to `.accessory`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let store: Store
    private var cancellables: Set<AnyCancellable> = []
    private weak var syncItem: NSToolbarItem?

    init(store: Store) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulley"
        window.minSize = NSSize(width: 900, height: 560)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainWindowView().environmentObject(store)
        )

        // Native toolbar carries sync + settings; the in-content HeaderBar
        // owns filters, search, group picker, and the sync-time readout.
        let toolbar = NSToolbar(identifier: "PulleyMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        store.$syncing
            .receive(on: RunLoop.main)
            .sink { [weak self] syncing in
                self?.updateSyncItem(syncing: syncing)
            }
            .store(in: &cancellables)

        store.$lastSync
            .receive(on: RunLoop.main)
            .sink { [weak self] last in
                self?.syncItem?.toolTip = relativeSyncLabel(last)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop back to menu-bar-only on close. Defer one runloop tick so
        // AppKit finishes the close transition before we hide the dock icon.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .pulleySync, .pulleySettings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .pulleySync, .pulleySettings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case .pulleySync:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Sync"
            item.paletteLabel = "Sync"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Sync")
            item.target = self
            item.action = #selector(toolbarSync)
            item.toolTip = relativeSyncLabel(store.lastSync)
            item.isBordered = true
            syncItem = item
            return item
        case .pulleySettings:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Settings"
            item.paletteLabel = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.target = self
            item.action = #selector(toolbarOpenSettings)
            item.toolTip = "Settings"
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    @objc private func toolbarSync() {
        store.sync()
    }

    @objc private func toolbarOpenSettings() {
        NotificationCenter.default.post(name: .pulleyMainOpenSettings, object: nil)
    }

    private func updateSyncItem(syncing: Bool) {
        guard let item = syncItem else { return }
        item.isEnabled = !syncing
        let name = syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: syncing ? "Syncing" : "Sync")
    }
}

extension NSToolbarItem.Identifier {
    static let pulleySync     = NSToolbarItem.Identifier("PulleySync")
    static let pulleySettings = NSToolbarItem.Identifier("PulleySettings")
}

extension Notification.Name {
    /// Sent by the main window's toolbar gear so `MainWindowView` can present
    /// its settings sheet. Distinct from `.pulleyOpenSettings` (popover-only).
    static let pulleyMainOpenSettings = Notification.Name("PulleyMainOpenSettings")
}

/// Sidebar filter modes — distinct from `Scope` because `Scope` is a global
/// user setting; sidebar selection is window-local and only filters what the
/// store already loaded.
enum SidebarFilter: Hashable, Identifiable {
    case all
    case status(PRStatus)
    case org(String)

    var id: String {
        switch self {
        case .all:             return "all"
        case .status(let s):   return "status:\(s.rawValue)"
        case .org(let o):      return "org:\(o)"
        }
    }

    var label: String {
        switch self {
        case .all:               return "All"
        case .status(.changes):  return "Changes requested"
        case .status(.approved): return "Approved"
        case .status(.review):   return "In review"
        case .status(.open):     return "Open"
        case .org(let o):        return o
        }
    }

    var systemImage: String {
        switch self {
        case .all:              return "tray.full"
        case .status(.changes): return "exclamationmark.circle"
        case .status(.approved): return "checkmark.seal"
        case .status(.review):  return "eye"
        case .status(.open):    return "circle.dashed"
        case .org:              return "building.2"
        }
    }
}

/// Two top-level surfaces in the main window: a PR list (default) and the
/// notifications inbox. Selecting either is a one-click switch in HeaderBar.
enum MainViewMode: Hashable {
    case prs
    case inbox
}

struct MainWindowView: View {
    @EnvironmentObject var store: Store
    @State private var filter: SidebarFilter = .all
    @State private var selectedPRID: String? = nil
    @State private var query: String = ""
    @State private var showSettings: Bool = false
    @State private var groupMode: ListGroupMode = .none
    @State private var viewMode: MainViewMode = .prs

    private var filtered: [PR] {
        let base: [PR]
        switch filter {
        case .all:                base = store.prs
        case .status(let s):      base = store.prs.filter { $0.status == s }
        case .org(let o):         base = store.prs.filter { $0.org == o }
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            ($0.title + " " + $0.repo + " " + $0.branch).lowercased().contains(q)
        }
    }

    private var selectedPR: PR? {
        guard let id = selectedPRID else { return nil }
        return store.prs.first { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar(
                filter: $filter,
                query: $query,
                groupMode: $groupMode,
                viewMode: $viewMode,
                prs: store.prs,
                filteredCount: filtered.count,
                inboxCount: store.unreadInboxCount,
                lastSync: store.lastSync,
                syncing: store.syncing
            )

            Group {
                switch viewMode {
                case .prs:
                    HSplitView {
                        PRListPane(
                            prs: filtered,
                            selectedPRID: $selectedPRID,
                            groupMode: $groupMode,
                            filter: filter
                        )
                        .frame(minWidth: 340, idealWidth: 440, maxWidth: 520)

                        Group {
                            if let pr = selectedPR {
                                PRDetailPane(pr: pr)
                            } else {
                                EmptyDetail()
                            }
                        }
                        .frame(minWidth: 480, idealWidth: 760)
                    }
                case .inbox:
                    InboxPane(
                        threads: store.notifications,
                        query: query,
                        onOpen: { thread in
                            if let url = thread.url {
                                PRActions.openInBrowser(url)
                            }
                            store.markNotificationRead(thread.id)
                        },
                        onMarkRead: { id in
                            store.markNotificationRead(id)
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .environmentObject(store)
                .frame(width: 560, height: 640)
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleyMainOpenSettings)) { _ in
            showSettings = true
        }
    }
}

// MARK: - Header bar

/// Single-row tab-bar header: status tabs left, search + count + group right.
/// Optional second row for org tabs when more than one org is configured.
private struct HeaderBar: View {
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

private func relativeSyncLabel(_ lastSync: Date?, now: Date = Date()) -> String {
    guard let last = lastSync else { return "never synced" }
    let s = Int(now.timeIntervalSince(last))
    if s < 60     { return "synced now" }
    if s < 3600   { return "synced \(s / 60)m ago" }
    if s < 86400  { return "synced \(s / 3600)h ago" }
    return "synced \(s / 86400)d ago"
}

// MARK: - List pane

private struct PRListPane: View {
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

private enum ListGroupMode: String, CaseIterable, Identifiable {
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

                Text(relativeWindowTime(pr.updatedAt))
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
                Text(stateLabel)
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

    private var stateLabel: String {
        if check.status != "completed" {
            return check.status.replacingOccurrences(of: "_", with: " ")
        }
        return check.conclusion ?? "completed"
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

// MARK: - Helpers

private func statusColor(_ s: PRStatus) -> Color {
    switch s {
    case .changes:  return .red
    case .approved: return .green
    case .review:   return .orange
    case .open:     return .blue
    }
}

private func checkColor(_ s: CheckStatus) -> Color {
    switch s {
    case .success: return .green
    case .failure: return .red
    case .pending: return .orange
    case .neutral, .none: return .secondary
    }
}

private func checkGlyph(_ s: CheckStatus) -> String {
    switch s {
    case .success: return "checkmark.circle.fill"
    case .failure: return "xmark.octagon.fill"
    case .pending: return "clock.fill"
    case .neutral: return "minus.circle.fill"
    case .none:    return "circle"
    }
}

private func mergeableColor(_ s: MergeableState) -> Color {
    switch s {
    case .dirty, .blocked: return .red
    case .behind:          return .orange
    case .unstable:        return .yellow
    default:               return .secondary
    }
}

private func mergeableGlyph(_ s: MergeableState) -> String {
    switch s {
    case .dirty:    return "exclamationmark.triangle.fill"
    case .behind:   return "arrow.down.circle.fill"
    case .blocked:  return "lock.fill"
    case .unstable: return "exclamationmark.circle.fill"
    default:        return "circle"
    }
}

private func relativeWindowTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60      { return "now" }
    if s < 3600    { return "\(s / 60)m" }
    if s < 86400   { return "\(s / 3600)h" }
    let d = s / 86400
    if d < 30      { return "\(d)d" }
    if d < 365     { return "\(d / 30)mo" }
    return "\(d / 365)y"
}

private func colorForRepo(_ repo: String) -> Color {
    var h: UInt64 = 5381
    for byte in repo.utf8 { h = (h &* 33) &+ UInt64(byte) }
    let hue = Double(h % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}

// MARK: - Detail pane

private struct PRDetailPane: View {
    let pr: PR
    @EnvironmentObject var store: Store

    @State private var descriptionText: String = ""
    @State private var loading = false
    @State private var loadError: String? = nil

    // Review / draft state. `reviewMode == nil` keeps the textarea collapsed;
    // setting it to `.requestChanges` or `.comment` expands it. `.approve`
    // is never stored here — Approve fires immediately on click.
    @State private var reviewMode: ReviewEvent? = nil
    @State private var reviewBody: String = ""
    @State private var inflightAction: InflightAction? = nil
    @State private var actionError: String? = nil

    private enum InflightAction: Equatable { case draft, review }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                statusRow
                if pr.mergeableState == .dirty {
                    ConflictBanner()
                }
                actionRow

                divider

                section("Review") {
                    reviewSection
                }

                divider

                section("Description") {
                    bodySection
                }

                if !pr.checks.isEmpty {
                    divider
                    section("Checks · \(pr.checks.count)") {
                        checksSection
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear(perform: loadBody)
        .onChange(of: pr.id) { _ in
            loadBody()
            // Reset per-PR transient state so the textarea / error from one
            // PR doesn't leak into the next selection.
            reviewMode = nil
            reviewBody = ""
            actionError = nil
            inflightAction = nil
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(.secondary.opacity(0.75))
            content()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(pr.title)
                .font(.system(size: 20, weight: .semibold))
                .textSelection(.enabled)
                .lineSpacing(1)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("\(pr.org)/\(pr.repo)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("#\(pr.number)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .fixedSize()
                if !pr.branch.isEmpty {
                    BranchPill(branch: pr.branch)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                StatusBadge(text: pr.status.label, color: statusColor(pr.status), filled: true)
                if pr.isDraft {
                    StatusBadge(text: "draft", color: .secondary, filled: false)
                }
                if pr.checkStatus != .none {
                    StatusBadge(
                        text: "CI · \(pr.checkStatus.label)",
                        color: checkColor(pr.checkStatus),
                        filled: false
                    )
                }
                if pr.mergeableState.isActionable {
                    StatusBadge(
                        text: pr.mergeableState.label,
                        color: mergeableColor(pr.mergeableState),
                        filled: false
                    )
                }
                Spacer(minLength: 0)
            }
            Text("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(1)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: "Open in \(Config.preferredIDE.displayName)",
                systemImage: Config.preferredIDE.fallbackSymbol,
                nsImage: Config.preferredIDE.icon,
                style: .primary
            ) {
                MainActor.assumeIsolated {
                    PRActions.checkoutAndOpen(pr: pr)
                }
            }
            .help("Create a worktree and open in \(Config.preferredIDE.displayName)")

            DetailActionButton(
                title: "Open on GitHub",
                systemImage: "arrow.up.right.square",
                style: .secondary
            ) {
                PRActions.openInBrowser(pr.url)
            }
            .help("Open PR in browser")

            if !pr.branch.isEmpty {
                DetailActionButton(
                    title: "Copy branch",
                    systemImage: "doc.on.doc",
                    style: .secondary
                ) {
                    PRActions.copyToPasteboard(pr.branch)
                }
                .help("Copy branch name")
            }

            if let nodeID = pr.nodeID {
                DetailActionButton(
                    title: pr.isDraft ? "Mark ready for review" : "Convert to draft",
                    systemImage: pr.isDraft ? "checkmark.circle" : "pencil.and.outline",
                    style: .secondary
                ) {
                    toggleDraft(nodeID: nodeID)
                }
                .help(pr.isDraft
                      ? "Move this PR out of draft state"
                      : "Convert this PR back to draft")
                .disabled(inflightAction == .draft)
            }

            if inflightAction == .draft {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            Spacer()
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                DetailActionButton(
                    title: "Approve",
                    systemImage: "checkmark.seal.fill",
                    style: .primary
                ) {
                    submitReview(event: .approve, body: nil)
                }
                .disabled(inflightAction != nil)

                DetailActionButton(
                    title: "Request changes",
                    systemImage: "exclamationmark.bubble",
                    style: .secondary
                ) {
                    if reviewMode == .requestChanges {
                        reviewMode = nil
                    } else {
                        reviewMode = .requestChanges
                        actionError = nil
                    }
                }
                .disabled(inflightAction != nil)

                DetailActionButton(
                    title: "Comment",
                    systemImage: "text.bubble",
                    style: .secondary
                ) {
                    if reviewMode == .comment {
                        reviewMode = nil
                    } else {
                        reviewMode = .comment
                        actionError = nil
                    }
                }
                .disabled(inflightAction != nil)

                if inflightAction == .review {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.leading, 2)
                }

                Spacer()
            }

            if let mode = reviewMode {
                reviewComposer(mode: mode)
            }

            if let err = actionError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func reviewComposer(mode: ReviewEvent) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $reviewBody)
                .font(.system(size: 13))
                .frame(minHeight: 88, maxHeight: 200)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.primary.opacity(0.15), lineWidth: 0.7)
                )
                .overlay(alignment: .topLeading) {
                    if reviewBody.isEmpty {
                        Text(mode == .requestChanges
                             ? "What needs to change?"
                             : "Leave a comment…")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary.opacity(0.55))
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                    }
                }

            HStack(spacing: 8) {
                DetailActionButton(
                    title: "Send review",
                    systemImage: "paperplane.fill",
                    style: .primary
                ) {
                    submitReview(event: mode, body: reviewBody)
                }
                .disabled(reviewBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || inflightAction != nil)

                DetailActionButton(
                    title: "Cancel",
                    systemImage: "xmark",
                    style: .secondary
                ) {
                    reviewMode = nil
                    reviewBody = ""
                }
                .disabled(inflightAction != nil)

                Spacer()
            }
        }
    }

    private func toggleDraft(nodeID: String) {
        let token = Config.token
        guard !token.isEmpty else {
            actionError = "Token not configured."
            return
        }
        inflightAction = .draft
        actionError = nil
        let client = GitHubClient(token: token, orgs: Config.orgs)
        let targetDraft = !pr.isDraft
        Task {
            do {
                try await client.setDraft(nodeID: nodeID, draft: targetDraft)
                await MainActor.run {
                    self.inflightAction = nil
                    self.store.sync()
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.inflightAction = nil
                }
            }
        }
    }

    private func submitReview(event: ReviewEvent, body: String?) {
        let token = Config.token
        guard !token.isEmpty else {
            actionError = "Token not configured."
            return
        }
        inflightAction = .review
        actionError = nil
        let client = GitHubClient(token: token, orgs: Config.orgs)
        let org = pr.org, repo = pr.repo, number = pr.number
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await client.submitReview(
                    org: org, repo: repo, number: number,
                    event: event, body: trimmed
                )
                await MainActor.run {
                    self.reviewMode = nil
                    self.reviewBody = ""
                    self.inflightAction = nil
                    self.store.sync()
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.inflightAction = nil
                }
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading description…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else if let err = loadError {
            Text(err).foregroundColor(.red).font(.system(size: 12))
        } else if descriptionText.isEmpty {
            Text("No description.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .italic()
        } else {
            MarkdownView(text: descriptionText)
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pr.checks) { c in
                HStack(spacing: 11) {
                    Image(systemName: checkGlyph(c.rolled))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(checkColor(c.rolled))
                        .frame(width: 16)
                    Text(c.name)
                        .font(.system(size: 13))
                    Spacer()
                    Text(c.conclusion ?? c.status)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    if let url = c.url {
                        Button {
                            PRActions.openInBrowser(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary.opacity(0.65))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    private func loadBody() {
        loading = true
        loadError = nil
        descriptionText = ""
        let token = Config.token
        guard !token.isEmpty else {
            loadError = "Token not configured."
            loading = false
            return
        }
        let client = GitHubClient(token: token, orgs: Config.orgs)
        let org = pr.org, repo = pr.repo, number = pr.number
        Task {
            do {
                let b = try await client.fetchPRBody(org: org, repo: repo, number: number)
                await MainActor.run {
                    self.descriptionText = b
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }
}

/// Prominent red banner shown above the action row when GitHub reports the
/// PR's `mergeable_state == dirty`. The status row already carries a small
/// "conflicts" badge; this just makes the state un-missable on the surface
/// where the user is about to act on the PR.
private struct ConflictBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Merge conflicts with the base branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Rebase or merge the base branch locally before this PR can be merged.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 0.7)
        )
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary.opacity(0.35))
            Text("Select a PR")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Click or use ↑ ↓ to preview.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}

// MARK: - Inbox

/// Notifications inbox pane. Reuses the same row chrome as the PR list so
/// the two surfaces feel like one app. Rows are flat (no detail pane); a
/// click opens the thread in the browser and silently marks it read.
private struct InboxPane: View {
    let threads: [InboxThread]
    let query: String
    let onOpen: (InboxThread) -> Void
    let onMarkRead: (String) -> Void

    private var filtered: [InboxThread] {
        guard !query.isEmpty else { return threads }
        let q = query.lowercased()
        return threads.filter {
            ($0.title + " " + $0.repo + " " + $0.org + " " + $0.reasonLabel)
                .lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Color(NSColor.textBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(.secondary.opacity(0.45))
            Text(threads.isEmpty ? "Inbox zero" : "Nothing matches")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text(threads.isEmpty
                 ? "No unread notifications. Sync to refresh."
                 : "Try a different search.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, t in
                    InboxRow(
                        thread: t,
                        onOpen:     { onOpen(t) },
                        onMarkRead: { onMarkRead(t.id) }
                    )
                    if idx < filtered.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 18)
                    }
                }
                Color.clear.frame(height: 4)
            }
        }
    }
}

private struct InboxRow: View {
    let thread: InboxThread
    let onOpen: () -> Void
    let onMarkRead: () -> Void
    @State private var hovered = false

    private var typeGlyph: String {
        switch thread.type {
        case "PullRequest": return "arrow.triangle.pull"
        case "Issue":       return "circle.dashed"
        case "Discussion":  return "bubble.left"
        case "Release":     return "tag"
        case "Commit":      return "scribble"
        default:            return "bell"
        }
    }

    private var typeTint: Color {
        switch thread.type {
        case "PullRequest": return .accentColor
        case "Issue":       return .green
        case "Discussion":  return .purple
        case "Release":     return .orange
        default:            return .secondary
        }
    }

    private var reasonTint: Color {
        switch thread.reason {
        case "mention", "team_mention": return .yellow
        case "review_requested":         return .orange
        case "author", "assign":         return .accentColor
        case "ci_activity":              return .secondary
        case "security_alert":           return .red
        default:                         return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Unread indicator bar — mirrors the PR row status bar.
            Rectangle()
                .fill(thread.unread ? typeTint : Color.clear)
                .frame(width: 3)
                .opacity(thread.unread ? 0.85 : 0)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: typeGlyph)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(typeTint)
                        .frame(width: 14)

                    Text(thread.title)
                        .font(.system(size: 14, weight: thread.unread ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .help(thread.title)

                    if hovered {
                        Button(action: onMarkRead) {
                            Image(systemName: "envelope.open")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.secondary)
                                .frame(width: 22, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Mark as read")
                    }

                    Text(relativeWindowTime(thread.updatedAt))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary.opacity(0.85))
                        .frame(width: 44, alignment: .trailing)
                        .help("Updated \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }

                HStack(spacing: 8) {
                    reasonChip
                    repoLabel
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onOpen() }
    }

    private var rowBackground: Color {
        hovered ? Color.primary.opacity(0.04) : .clear
    }

    private var reasonChip: some View {
        Text(thread.reasonLabel.lowercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(reasonTint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(reasonTint.opacity(0.13)))
            .fixedSize()
    }

    private var repoLabel: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(colorForRepo(thread.repo))
                .frame(width: 6, height: 6)
            (Text(thread.org + "/").foregroundColor(.secondary.opacity(0.6))
             + Text(thread.repo).foregroundColor(.secondary))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(thread.org)/\(thread.repo)")
    }
}

// MARK: - Detail-pane chrome

private struct StatusBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(filled ? .white : color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(
                    filled ? Color.clear : color.opacity(0.35),
                    lineWidth: 0.5
                )
            )
            .fixedSize()
    }
}

private struct BranchPill: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 10))
            Text(branch)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .frame(maxWidth: 240, alignment: .leading)
        .help(branch)
    }
}

private struct DetailActionButton: View {
    enum Style { case primary, secondary }

    let title: String
    let systemImage: String
    let nsImage: NSImage?
    let style: Style
    let action: () -> Void

    @State private var hovering = false
    @State private var pressing = false

    init(
        title: String,
        systemImage: String,
        nsImage: NSImage? = nil,
        style: Style,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.nsImage = nsImage
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let img = nsImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, nsImage != nil ? 5 : 7)
            .foregroundColor(textColor)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(strokeColor, lineWidth: borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .scaleEffect(pressing ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.08), value: pressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            return hovering ? Color.accentColor.opacity(0.88) : Color.accentColor
        case .secondary:
            return hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03)
        }
    }

    private var strokeColor: Color {
        switch style {
        case .primary:   return Color.clear
        case .secondary: return Color.primary.opacity(hovering ? 0.22 : 0.15)
        }
    }

    private var borderWidth: CGFloat {
        style == .primary ? 0 : 0.7
    }

    private var textColor: Color {
        style == .primary ? .white : .primary
    }
}

// MARK: - Markdown rendering

private struct MarkdownView: View {
    let text: String

    private static let bodyFont   = Font.system(size: 14, design: .serif)
    private static let quoteFont  = Font.system(size: 14, design: .serif).italic()
    private static let listFont   = Font.system(size: 13)
    private static let codeFont   = Font.system(size: 12, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(parse(Emoji.substitute(HtmlPreprocess.apply(text))).enumerated()), id: \.offset) { _, block in
                render(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func render(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let s):
            VStack(alignment: .leading, spacing: 4) {
                Text(inline(s))
                    .font(headingFont(level))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 0.5)
                }
            }
            .padding(.top, level == 1 ? 8 : (level == 2 ? 4 : 2))

        case .paragraph(let s):
            Text(inline(s))
                .font(Self.bodyFont)
                .lineSpacing(4)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.secondary.opacity(0.65))
                            .frame(width: 4, height: 4)
                            .offset(y: -2)
                        Text(inline(item))
                            .font(Self.listFont)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .ordered(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)
                        Text(inline(item))
                            .font(Self.listFont)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .task(let items):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: item.0 ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundColor(item.0 ? .accentColor : .secondary.opacity(0.7))
                        Text(inline(item.1))
                            .font(Self.listFont)
                            .strikethrough(item.0, color: .secondary)
                            .foregroundColor(item.0 ? .secondary : .primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.leading, 4)

        case .code(let lang, let s):
            VStack(alignment: .leading, spacing: 0) {
                if !lang.isEmpty {
                    HStack {
                        Text(lang.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundColor(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(height: 0.5)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s)
                        .font(Self.codeFont)
                        .textSelection(.enabled)
                        .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )

        case .quote(let lines):
            HStack(spacing: 10) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.55))
                    .frame(width: 2.5)
                Text(inline(lines.joined(separator: "\n")))
                    .font(Self.quoteFont)
                    .foregroundColor(.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(height: 0.5)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let size: CGFloat
        switch level {
        case 1: size = 20
        case 2: size = 17
        case 3: size = 15
        case 4: size = 13
        default: size = 12
        }
        return .system(size: size, weight: level <= 2 ? .bold : .semibold)
    }

    private func inline(_ s: String) -> AttributedString {
        guard var attr = try? AttributedString(
            markdown: s,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        ) else { return AttributedString(s) }

        for run in attr.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].backgroundColor = Color.primary.opacity(0.1)
                attr[run.range].foregroundColor = Color(red: 0.82, green: 0.36, blue: 0.45)
            }
            if run.link != nil {
                attr[run.range].foregroundColor = Color.accentColor
                attr[run.range].underlineStyle = .single
            }
        }
        return attr
    }
}

// MARK: - HTML in PR bodies → markdown equivalents

private enum HtmlPreprocess {
    static func apply(_ s: String) -> String {
        var out = s
        out = replaceRegex(out, #"<!--[\s\S]*?-->"#, with: "", caseInsensitive: false)
        out = replaceRegex(out, #"<br\s*/?>"#, with: "\n", caseInsensitive: true)
        out = replaceRegex(out, #"<hr\s*/?>"#, with: "\n\n---\n\n", caseInsensitive: true)
        out = replaceRegex(out, #"<(strong|b)>([\s\S]*?)</\1>"#, with: "**$2**", caseInsensitive: true)
        out = replaceRegex(out, #"<(em|i)>([\s\S]*?)</\1>"#, with: "*$2*", caseInsensitive: true)
        out = replaceRegex(out, #"<code>([\s\S]*?)</code>"#, with: "`$1`", caseInsensitive: true)
        out = replaceRegex(out, #"<kbd>([\s\S]*?)</kbd>"#, with: "`$1`", caseInsensitive: true)
        out = replaceRegex(
            out,
            #"<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            with: "[$2]($1)",
            caseInsensitive: true
        )
        out = replaceRegex(out, #"<summary>([\s\S]*?)</summary>"#, with: "**$1**", caseInsensitive: true)
        out = replaceRegex(out, #"</?details(\s[^>]*)?>"#, with: "", caseInsensitive: true)
        out = replaceRegex(
            out,
            #"<img\s+[^>]*?alt=["']([^"']*)["'][^>]*?src=["']([^"']+)["'][^>]*?/?>"#,
            with: "![$1]($2)",
            caseInsensitive: true
        )
        out = replaceRegex(
            out,
            #"<img\s+[^>]*?src=["']([^"']+)["'][^>]*?/?>"#,
            with: "![]($1)",
            caseInsensitive: true
        )
        let strippable = ["div", "span", "p", "section", "article", "header", "footer",
                          "nav", "small", "sub", "sup", "mark", "u", "s", "strike",
                          "ul", "ol", "li", "table", "thead", "tbody", "tfoot",
                          "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
                          "blockquote", "pre"]
        for tag in strippable {
            out = replaceRegex(out, "</?\(tag)(\\s[^>]*)?>", with: "", caseInsensitive: true)
        }
        return out
    }

    private static func replaceRegex(
        _ s: String,
        _ pattern: String,
        with template: String,
        caseInsensitive: Bool
    ) -> String {
        var opts: NSRegularExpression.Options = []
        if caseInsensitive { opts.insert(.caseInsensitive) }
        guard let regex = try? NSRegularExpression(pattern: pattern, options: opts) else { return s }
        let ns = s as NSString
        return regex.stringByReplacingMatches(
            in: s,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: template
        )
    }
}

// MARK: - GitHub-style emoji shortcodes (:rocket: → 🚀)

private enum Emoji {
    static let map: [String: String] = [
        "tada": "🎉", "rocket": "🚀", "bug": "🐛", "sparkles": "✨",
        "memo": "📝", "white_check_mark": "✅", "heavy_check_mark": "✔️",
        "x": "❌", "warning": "⚠️", "fire": "🔥", "bulb": "💡",
        "construction": "🚧", "wrench": "🔧", "hammer": "🔨",
        "recycle": "♻️", "art": "🎨", "zap": "⚡", "boom": "💥",
        "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "pencil": "✏️", "books": "📚", "book": "📖",
        "package": "📦", "rotating_light": "🚨",
        "tag": "🏷", "star": "⭐", "100": "💯",
        "checkered_flag": "🏁", "triangular_flag_on_post": "🚩",
        "wave": "👋", "ok_hand": "👌", "thumbsup": "👍", "+1": "👍",
        "thumbsdown": "👎", "-1": "👎", "clap": "👏", "muscle": "💪",
        "pray": "🙏", "eyes": "👀",
        "smile": "😄", "joy": "😂", "sob": "😭",
        "thinking": "🤔", "robot": "🤖",
        "calendar": "📅", "chart_with_upwards_trend": "📈",
        "clipboard": "📋", "paperclip": "📎",
        "shield": "🛡", "gem": "💎",
        "heart": "❤️", "broken_heart": "💔",
        "no_entry": "⛔", "question": "❓", "exclamation": "❗",
        "speech_balloon": "💬", "globe_with_meridians": "🌐",
        "tools": "🛠", "gear": "⚙️", "link": "🔗", "mag": "🔍",
        "bookmark": "🔖", "bell": "🔔", "alarm_clock": "⏰",
        "hourglass": "⌛", "hourglass_flowing_sand": "⏳",
        "rainbow": "🌈", "coffee": "☕",
        "envelope": "✉️", "inbox_tray": "📥",
        "trophy": "🏆", "first_place_medal": "🥇",
        "shrug": "🤷", "metal": "🤘", "v": "✌️", "saluting_face": "🫡",
    ]

    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #":([a-z0-9_+\-]+):"#, options: [.caseInsensitive])
    }()

    static func substitute(_ s: String) -> String {
        guard let regex = regex else { return s }
        let ns = s as NSString
        let matches = regex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = 0
        for m in matches {
            let full = m.range
            let name = ns.substring(with: m.range(at: 1)).lowercased()
            out += ns.substring(with: NSRange(location: last, length: full.location - last))
            out += map[name] ?? ns.substring(with: full)
            last = full.location + full.length
        }
        out += ns.substring(with: NSRange(location: last, length: ns.length - last))
        return out
    }
}

private enum MDBlock {
    case heading(Int, String)
    case paragraph(String)
    case bullet([String])
    case ordered([String])
    case task([(Bool, String)])
    case code(String, String)
    case quote([String])
    case rule
}

private func parse(_ source: String) -> [MDBlock] {
    var blocks: [MDBlock] = []
    let lines = source.components(separatedBy: "\n")
    var i = 0

    var paraBuf: [String] = []
    var bulletBuf: [String] = []
    var orderedBuf: [String] = []
    var taskBuf: [(Bool, String)] = []
    var quoteBuf: [String] = []

    func flushPara()    { if !paraBuf.isEmpty    { blocks.append(.paragraph(paraBuf.joined(separator: " "))); paraBuf.removeAll() } }
    func flushBullets() { if !bulletBuf.isEmpty  { blocks.append(.bullet(bulletBuf));   bulletBuf.removeAll() } }
    func flushOrdered() { if !orderedBuf.isEmpty { blocks.append(.ordered(orderedBuf)); orderedBuf.removeAll() } }
    func flushTasks()   { if !taskBuf.isEmpty    { blocks.append(.task(taskBuf));       taskBuf.removeAll() } }
    func flushQuote()   { if !quoteBuf.isEmpty   { blocks.append(.quote(quoteBuf));     quoteBuf.removeAll() } }
    func flushAll()     { flushPara(); flushBullets(); flushOrdered(); flushTasks(); flushQuote() }

    while i < lines.count {
        let raw = lines[i]
        let line = raw.trimmingCharacters(in: .whitespaces)

        if line.hasPrefix("```") {
            flushAll()
            let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            var code: [String] = []
            i += 1
            while i < lines.count,
                  !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                code.append(lines[i]); i += 1
            }
            blocks.append(.code(lang, code.joined(separator: "\n")))
            i += 1
            continue
        }

        if line == "---" || line == "***" || line == "___" {
            flushAll(); blocks.append(.rule); i += 1; continue
        }

        let hashes = line.prefix(while: { $0 == "#" }).count
        if hashes >= 1, hashes <= 6,
           line.count > hashes, line[line.index(line.startIndex, offsetBy: hashes)] == " " {
            flushAll()
            let text = String(line.dropFirst(hashes + 1)).trimmingCharacters(in: .whitespaces)
            blocks.append(.heading(hashes, text))
            i += 1; continue
        }

        if let r = line.range(of: #"^[-*+]\s+\[[ xX]\]\s+"#, options: .regularExpression) {
            flushPara(); flushBullets(); flushOrdered(); flushQuote()
            let prefix = String(line[..<r.upperBound]).lowercased()
            let checked = prefix.contains("[x]")
            let item = String(line[r.upperBound...])
            taskBuf.append((checked, item))
            i += 1; continue
        }

        if let r = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
            flushPara(); flushOrdered(); flushTasks(); flushQuote()
            bulletBuf.append(String(line[r.upperBound...]))
            i += 1; continue
        }

        if let r = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            flushPara(); flushBullets(); flushTasks(); flushQuote()
            orderedBuf.append(String(line[r.upperBound...]))
            i += 1; continue
        }

        if line.hasPrefix(">") {
            flushPara(); flushBullets(); flushOrdered(); flushTasks()
            let stripped = line.hasPrefix("> ")
                ? String(line.dropFirst(2))
                : String(line.dropFirst())
            quoteBuf.append(stripped)
            i += 1; continue
        }

        if line.isEmpty {
            flushAll()
            i += 1; continue
        }

        flushBullets(); flushOrdered(); flushTasks(); flushQuote()
        paraBuf.append(line)
        i += 1
    }
    flushAll()
    return blocks
}
