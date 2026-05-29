import SwiftUI
import AppKit

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
    /// True while the detail pane is showing a full-pane file diff — we hide the
    /// PR list so the diff spans the whole window.
    @State private var diffFullScreen: Bool = false

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
                        if !(diffFullScreen && selectedPR != nil) {
                            PRListPane(
                                prs: filtered,
                                selectedPRID: $selectedPRID,
                                groupMode: $groupMode,
                                filter: filter
                            )
                            .frame(minWidth: 340, idealWidth: 440, maxWidth: 520)
                        }

                        Group {
                            if let pr = selectedPR {
                                PRDetailPane(pr: pr, fullScreenDiff: $diffFullScreen)
                            } else {
                                EmptyDetail()
                            }
                        }
                        .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity)
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
