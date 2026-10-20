import SwiftUI
import AppKit

/// Sidebar filter modes — distinct from `Scope` because `Scope` is a global
/// user setting; sidebar selection is window-local and only filters what the
/// store already loaded.
enum SidebarFilter: Hashable, Identifiable {
    case all
    case status(PRStatus)
    case org(String)
    /// Reached from Home's "CI failing" card; not a sidebar entry.
    case failingCI

    var id: String {
        switch self {
        case .all:             return "all"
        case .status(let s):   return "status:\(s.rawValue)"
        case .org(let o):      return "org:\(o)"
        case .failingCI:       return "failingCI"
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
        case .failingCI:         return "CI failing"
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
        case .failingCI:        return "xmark.octagon.fill"
        }
    }
}

struct MainWindowView: View {
    @EnvironmentObject var store: Store
    @State private var section: MainSection = .home
    @State private var selectedPRID: String? = nil
    @State private var query: String = ""
    @State private var showSettings: Bool = false
    /// Sidebar collapsed to the icon rail — the user's choice, remembered.
    @AppStorage("ui.sidebarCollapsed") private var userCollapsed = false
    @State private var groupMode: ListGroupMode = .none
    /// True while the detail pane is showing a full-pane file diff — we hide the
    /// PR list so the diff spans the whole panel.
    @State private var diffFullScreen: Bool = false

    private var filter: SidebarFilter? {
        if case .prs(let f) = section { return f }
        return nil
    }

    private var filtered: [PR] {
        let base: [PR]
        switch filter ?? .all {
        case .all:                base = store.prs
        case .status(let s):      base = store.prs.filter { $0.status == s }
        case .org(let o):         base = store.prs.filter { $0.org == o }
        case .failingCI:          base = store.prs.filter { $0.checkStatus == .failure }
        }
        guard !query.isEmpty else { return base }
        let q = query.lowercased()
        return base.filter {
            ($0.title + " " + $0.repo + " " + $0.branch).lowercased().contains(q)
        }
    }

    /// Only a PR the list is actually showing — a filter or search that hides
    /// the selected PR clears the detail pane rather than leaving it stale.
    private var selectedPR: PR? {
        guard let id = selectedPRID else { return nil }
        return filtered.first { $0.id == id }
    }

    /// Below this width the expanded sidebar (214) + list (340) + detail (480)
    /// + panel padding no longer fit, so the sidebar folds to its icon rail.
    private static let narrowWidth: CGFloat = 1060

    var body: some View {
        GeometryReader { geo in
            content(narrow: geo.size.width < Self.narrowWidth, height: geo.size.height)
        }
    }

    private func content(narrow: Bool, height: CGFloat) -> some View {
        VStack(spacing: 0) {
            topStrip(narrow: narrow)
            HStack(spacing: 0) {
            SidebarView(
                section: $section,
                onOpenSettings: { showSettings = true },
                collapsed: userCollapsed || narrow
            )
            VStack(spacing: 0) {
                if let error = store.lastError {
                    SyncErrorBanner(
                        problem: SyncProblem(raw: error),
                        onRetry: { store.sync() },
                        onOpenSettings: { showSettings = true }
                    )
                }
                panel
            }
                .background(Theme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
                .padding(.bottom, 10)
                .padding(.trailing, 10)
            }
        }
        .background(Theme.chrome)
        .background(KeyCommands { handle($0) })
        .ignoresSafeArea()
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .environmentObject(store)
                // Leave room for the title bar in short windows.
                .frame(width: 560, height: min(640, max(380, height - 70)))
        }
        .onChange(of: section) { _ in
            query = ""
            diffFullScreen = false
        }
        .onReceive(NotificationCenter.default.publisher(for: .pulleySelectPR)) { note in
            guard let id = note.object as? String else { return }
            open(section: filter == nil ? .prs(.all) : section, selecting: id)
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch section {
        case .home:
            HomePane(
                onOpen: { target, prID in open(section: target, selecting: prID) },
                onOpenSettings: { showSettings = true }
            )
        case .prs(let filter):
            VStack(spacing: 0) {
                if !(diffFullScreen && selectedPR != nil) {
                    PanelHeader(
                        title: filter.label,
                        subtitle: "\(filtered.count) pull request\(filtered.count == 1 ? "" : "s")",
                        query: $query,
                        searchPrompt: "Search pull requests",
                        groupMode: $groupMode
                    )
                }
                HSplitView {
                    if !(diffFullScreen && selectedPR != nil) {
                        PRListPane(
                            prs: filtered,
                            selectedPRID: $selectedPRID,
                            groupMode: $groupMode,
                            filter: filter
                        )
                        .frame(minWidth: 340, idealWidth: 420, maxWidth: 520)
                    }

                    Group {
                        if let pr = selectedPR {
                            // A fresh pane per PR: loads in `onChange(of: pr.id)`
                            // read a stale `pr`, fetching the previous PR's data.
                            PRDetailPane(pr: pr, fullScreenDiff: $diffFullScreen)
                                .id(pr.id)
                        } else {
                            EmptyDetail()
                        }
                    }
                    .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity)
                }
            }
        case .inbox:
            VStack(spacing: 0) {
                PanelHeader(
                    title: "Inbox",
                    subtitle: "\(store.unreadInboxCount) unread",
                    query: $query,
                    searchPrompt: "Search notifications"
                )
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

    /// The warm strip across the top: window buttons and the sidebar toggle
    /// share one line, and the content panel starts below it so nothing
    /// straddles the panel's edge.
    private func topStrip(narrow: Bool) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 72, height: 1)   // window buttons
            Button {
                withAnimation(.easeOut(duration: 0.18)) { userCollapsed.toggle() }
            } label: {
                Icon("sidebar.left", size: 15)
                    .foregroundColor(.secondary)
                    .frame(width: 30, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(narrow)
            .help(narrow
                  ? "Widen the window to show the sidebar"
                  : (userCollapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)"))
            .accessibilityLabel(userCollapsed || narrow ? "Show sidebar" : "Hide sidebar")
            Spacer(minLength: 0)
        }
        .frame(height: 32)
    }

    /// List keyboard commands. Only meaningful on a PR list.
    private func handle(_ command: KeyCommand) -> Bool {
        guard filter != nil else { return false }
        switch command {
        case .move(let delta):
            let ids = filtered.map(\.id)
            guard !ids.isEmpty else { return true }
            let current = selectedPRID.flatMap { ids.firstIndex(of: $0) }
            let next = current.map { min(max($0 + delta, 0), ids.count - 1) } ?? (delta > 0 ? 0 : ids.count - 1)
            selectedPRID = ids[next]
            return true
        case .openOnGitHub:
            guard let pr = selectedPR else { return false }
            PRActions.openInBrowser(pr.url)
            return true
        case .openInIDE:
            guard let pr = selectedPR else { return false }
            PRActions.checkoutAndOpen(pr: pr)
            return true
        case .copyBranch:
            guard let pr = selectedPR, !pr.branch.isEmpty else { return false }
            PRActions.copyToPasteboard(pr.branch)
            return true
        case .escape:
            if selectedPRID != nil, !(NSApp.keyWindow?.firstResponder is NSText) {
                selectedPRID = nil
                return true
            }
            NSApp.keyWindow?.makeFirstResponder(nil)
            return true
        }
    }

    /// Switch section, then select a PR there. The selection is applied after
    /// the section change so its query reset doesn't race it.
    private func open(section target: MainSection, selecting prID: String?) {
        section = target
        guard let prID else { return }
        DispatchQueue.main.async {
            query = ""
            selectedPRID = prID
        }
    }
}
