import AppKit
import SwiftUI

/// Lazy-allocated main window. The app stays a menu-bar `.accessory`; this
/// window is opened on demand from the popover (`⌘O` or the window button)
/// and offers depth that doesn't fit in the popover: detail pane, future
/// files / diff / comments / review-action tabs.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private let store: Store

    init(store: Store) {
        self.store = store

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulley"
        window.minSize = NSSize(width: 820, height: 520)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainWindowView().environmentObject(store)
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
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
        case .all:             return "All PRs"
        case .status(.changes): return "Changes requested"
        case .status(.approved): return "Approved"
        case .status(.review):  return "In review"
        case .status(.open):    return "Open"
        case .org(let o):       return o
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

struct MainWindowView: View {
    @EnvironmentObject var store: Store
    @State private var filter: SidebarFilter = .all
    @State private var selectedPRID: String? = nil
    @State private var query: String = ""

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
        NavigationSplitView {
            SidebarView(filter: $filter)
                .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 260)
        } content: {
            PRListPane(
                prs: filtered,
                selectedPRID: $selectedPRID,
                query: $query
            )
            .navigationSplitViewColumnWidth(min: 340, ideal: 400)
        } detail: {
            if let pr = selectedPR {
                PRDetailPane(pr: pr)
            } else {
                EmptyDetail()
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.sync()
                } label: {
                    if store.syncing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(store.syncing)
                .help("Sync now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var filter: SidebarFilter

    private var orgs: [String] {
        Array(Set(store.prs.map { $0.org })).sorted()
    }

    var body: some View {
        List(selection: $filter) {
            Section("Views") {
                row(.all, count: store.prs.count)
                row(.status(.changes), count: store.prs.filter { $0.status == .changes }.count)
                row(.status(.review), count: store.prs.filter { $0.status == .review }.count)
                row(.status(.approved), count: store.prs.filter { $0.status == .approved }.count)
                row(.status(.open), count: store.prs.filter { $0.status == .open }.count)
            }
            if orgs.count > 1 {
                Section("Orgs") {
                    ForEach(orgs, id: \.self) { org in
                        row(.org(org), count: store.prs.filter { $0.org == org }.count)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func row(_ f: SidebarFilter, count: Int) -> some View {
        Label {
            HStack {
                Text(f.label)
                Spacer()
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }
        } icon: {
            Image(systemName: f.systemImage)
        }
        .tag(f)
    }
}

// MARK: - List pane

private struct PRListPane: View {
    let prs: [PR]
    @Binding var selectedPRID: String?
    @Binding var query: String

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter…", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(Color.primary.opacity(0.04))

            Divider()

            if prs.isEmpty {
                Text("No PRs match.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selectedPRID) {
                    ForEach(prs) { pr in
                        WindowPRRow(pr: pr)
                            .tag(pr.id)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

private struct WindowPRRow: View {
    let pr: PR

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(pr.title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            HStack(spacing: 6) {
                Text("\(pr.org)/\(pr.repo)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("#\(pr.number)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.6))
                Spacer()
                Text(relativeWindowTime(pr.updatedAt))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Detail pane

private struct PRDetailPane: View {
    let pr: PR

    @State private var descriptionText: String = ""
    @State private var loading = false
    @State private var loadError: String? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metaRow
                Divider()
                bodySection
                if !pr.checks.isEmpty {
                    Divider()
                    checksSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    PRActions.openInBrowser(pr.url)
                } label: {
                    Label("Open", systemImage: "arrow.up.right.square")
                }
                .help("Open PR in browser")

                Button {
                    PRActions.checkoutAndOpen(pr: pr)
                } label: {
                    Label("Checkout", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .help("Checkout & open in \(Config.preferredIDE.displayName)")
            }
        }
        .onAppear(perform: loadBody)
        .onChange(of: pr.id) { _ in loadBody() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(pr.title)
                .font(.system(size: 18, weight: .semibold))
                .textSelection(.enabled)
            HStack(spacing: 6) {
                Text("\(pr.org)/\(pr.repo)")
                    .foregroundColor(.secondary)
                Text("#\(pr.number)")
                    .foregroundColor(.secondary.opacity(0.7))
                if !pr.branch.isEmpty {
                    Text("·").foregroundColor(.secondary)
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundColor(.secondary)
                    Text(pr.branch)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private var metaRow: some View {
        HStack(spacing: 10) {
            DetailChip(text: pr.status.label, color: statusColorForDetail(pr.status))
            if pr.isDraft { DetailChip(text: "draft", color: .secondary) }
            if pr.checkStatus != .none {
                DetailChip(
                    text: "CI \(pr.checkStatus.label)",
                    color: checkColor(pr.checkStatus)
                )
            }
            if pr.mergeableState.isActionable {
                DetailChip(
                    text: pr.mergeableState.label,
                    color: mergeableColor(pr.mergeableState)
                )
            }
            Spacer()
            Text("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if loading {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading description…")
                    .foregroundColor(.secondary)
            }
        } else if let err = loadError {
            Text(err).foregroundColor(.red).font(.system(size: 12))
        } else if descriptionText.isEmpty {
            Text("No description.")
                .foregroundColor(.secondary)
                .italic()
        } else {
            // Markdown rendering — SwiftUI's AttributedString init handles
            // basic GFM (headings, lists, links, code). Falls back to raw
            // text on parse failure.
            if let attr = try? AttributedString(
                markdown: descriptionText,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ) {
                Text(attr)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(descriptionText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
            }
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checks")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundColor(.secondary)
            ForEach(pr.checks) { c in
                HStack(spacing: 8) {
                    Image(systemName: checkGlyph(c.rolled))
                        .foregroundColor(checkColor(c.rolled))
                        .frame(width: 14)
                    Text(c.name).font(.system(size: 12))
                    Spacer()
                    Text(c.conclusion ?? c.status)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                    if let url = c.url {
                        Button {
                            PRActions.openInBrowser(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                        }
                        .buttonStyle(.borderless)
                    }
                }
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

private struct DetailChip: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.13)))
            .overlay(Capsule().stroke(color.opacity(0.3), lineWidth: 0.5))
    }
}

private struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 40))
                .foregroundColor(.secondary.opacity(0.4))
            Text("Select a PR to view details.")
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Helpers

private func statusColorForDetail(_ s: PRStatus) -> Color {
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

private func relativeWindowTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60      { return "now" }
    if s < 3600    { return "\(s / 60)m ago" }
    if s < 86400   { return "\(s / 3600)h ago" }
    let d = s / 86400
    if d < 30      { return "\(d)d ago" }
    if d < 365     { return "\(d / 30)mo ago" }
    return "\(d / 365)y ago"
}
