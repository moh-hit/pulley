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
            contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulley"
        window.minSize = NSSize(width: 1200, height: 720)
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
    @State private var showSettings: Bool = false

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
            SidebarView(filter: $filter, showSettings: $showSettings)
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } content: {
            PRListPane(
                prs: filtered,
                selectedPRID: $selectedPRID,
                query: $query
            )
            .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 420)
        } detail: {
            if let pr = selectedPR {
                PRDetailPane(pr: pr)
            } else {
                EmptyDetail()
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(onClose: { showSettings = false })
                .environmentObject(store)
                .frame(width: 560, height: 640)
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var filter: SidebarFilter
    @Binding var showSettings: Bool
    @State private var nowTick: Date = Date()

    private var orgs: [String] {
        Array(Set(store.prs.map { $0.org })).sorted()
    }

    var body: some View {
        VStack(spacing: 0) {
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

            footer
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            nowTick = Date()
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
            HStack(spacing: 10) {
                Button {
                    store.sync()
                } label: {
                    Group {
                        if store.syncing {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                                .frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .disabled(store.syncing)
                .help("Sync now (⌘R)")
                .keyboardShortcut("r", modifiers: .command)

                Text(syncLabel)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
                .keyboardShortcut(",", modifiers: .command)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    private var syncLabel: String {
        guard let last = store.lastSync else { return "never synced" }
        _ = nowTick
        let s = Int(Date().timeIntervalSince(last))
        if s < 60      { return "synced now" }
        if s < 3600    { return "synced \(s / 60)m ago" }
        if s < 86400   { return "synced \(s / 3600)h ago" }
        return "synced \(s / 86400)d ago"
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
    @State private var groupMode: ListGroupMode = .none

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Filter…", text: $query)
                    .textFieldStyle(.plain)

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
                            .font(.system(size: 11, weight: .medium))
                        Text(groupMode.label)
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.06))
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Group PRs")
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
                    if groupMode == .none {
                        ForEach(prs) { pr in
                            WindowPRRow(pr: pr)
                                .tag(pr.id)
                        }
                    } else {
                        ForEach(groupedPRs(), id: \.key) { group in
                            Section {
                                ForEach(group.prs) { pr in
                                    WindowPRRow(pr: pr)
                                        .tag(pr.id)
                                }
                            } header: {
                                groupHeader(group)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private struct PRGroup {
        let key: String
        let label: String
        let prs: [PR]
    }

    @ViewBuilder
    private func groupHeader(_ group: PRGroup) -> some View {
        HStack(spacing: 8) {
            Image(systemName: groupMode.icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 12)
            Text(group.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)
            Spacer()
            Text("\(group.prs.count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.06))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.14))
                .frame(height: 0.5)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
        .listRowInsets(EdgeInsets())
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
        case .none:   return "list.bullet"
        case .status: return "circle.hexagongrid.fill"
        case .repo:   return "folder.fill"
        case .org:    return "building.2.fill"
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
            VStack(spacing: 0) {
                Rectangle()
                    .fill(statusColorForDetail(pr.status))
                    .frame(height: 3)
                VStack(alignment: .leading, spacing: 20) {
                    header
                    statusBar
                    actionBar

                    card {
                        VStack(alignment: .leading, spacing: 14) {
                            sectionLabel("Description")
                            bodySection
                        }
                    }

                    if !pr.checks.isEmpty {
                        card {
                            VStack(alignment: .leading, spacing: 14) {
                                sectionLabel("Checks")
                                checksSection
                            }
                        }
                    }
                }
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear(perform: loadBody)
        .onChange(of: pr.id) { _ in loadBody() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(pr.title)
                .font(.system(size: 26, weight: .semibold))
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("\(pr.org)/\(pr.repo)")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("#\(pr.number)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                if !pr.branch.isEmpty {
                    BranchPill(branch: pr.branch)
                }
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            StatusBadge(text: pr.status.label, color: statusColorForDetail(pr.status), filled: true)
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
            Spacer()
            Text("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: "Open in \(Config.preferredIDE.displayName)",
                systemImage: Config.preferredIDE.fallbackSymbol,
                nsImage: Config.preferredIDE.icon,
                style: .primary
            ) {
                PRActions.checkoutAndOpen(pr: pr)
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

            Spacer()
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.5)
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
            )
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
            MarkdownView(text: descriptionText)
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(pr.checks) { c in
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(checkColor(c.rolled).opacity(0.15))
                            .frame(width: 28, height: 28)
                        Image(systemName: checkGlyph(c.rolled))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(checkColor(c.rolled))
                    }
                    Text(c.name)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text(c.conclusion ?? c.status)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                    if let url = c.url {
                        Button {
                            PRActions.openInBrowser(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.035))
                )
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

// MARK: - Markdown rendering

private struct MarkdownView: View {
    let text: String

    private static let bodyFont   = Font.system(size: 15, design: .serif)
    private static let quoteFont  = Font.system(size: 15, design: .serif).italic()
    private static let listFont   = Font.system(size: 14)
    private static let codeFont   = Font.system(size: 13, design: .monospaced)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
            VStack(alignment: .leading, spacing: 6) {
                Text(inline(s))
                    .font(headingFont(level))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if level <= 2 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.12))
                        .frame(height: 1)
                }
            }
            .padding(.top, level == 1 ? 10 : (level == 2 ? 6 : 2))

        case .paragraph(let s):
            Text(inline(s))
                .font(Self.bodyFont)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .bullet(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(Color.secondary.opacity(0.7))
                            .frame(width: 5, height: 5)
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(idx + 1).")
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
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
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: item.0 ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
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
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.05))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color.primary.opacity(0.1))
                            .frame(height: 0.5)
                    }
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(s)
                        .font(Self.codeFont)
                        .textSelection(.enabled)
                        .padding(14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
            )

        case .quote(let lines):
            HStack(spacing: 12) {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.6))
                    .frame(width: 3)
                Text(inline(lines.joined(separator: "\n")))
                    .font(Self.quoteFont)
                    .foregroundColor(.secondary)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)

        case .rule:
            Rectangle()
                .fill(Color.primary.opacity(0.12))
                .frame(height: 1)
                .padding(.vertical, 4)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        let size: CGFloat
        switch level {
        case 1: size = 24
        case 2: size = 20
        case 3: size = 17
        case 4: size = 15
        default: size = 14
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

        // Strip HTML comments
        out = replaceRegex(out, #"<!--[\s\S]*?-->"#, with: "", caseInsensitive: false)

        // <br>, <br/>, <br /> → newline
        out = replaceRegex(out, #"<br\s*/?>"#, with: "\n", caseInsensitive: true)

        // <hr>, <hr/> → markdown rule
        out = replaceRegex(out, #"<hr\s*/?>"#, with: "\n\n---\n\n", caseInsensitive: true)

        // <strong>x</strong> / <b>x</b> → **x**
        out = replaceRegex(out, #"<(strong|b)>([\s\S]*?)</\1>"#, with: "**$2**", caseInsensitive: true)

        // <em>x</em> / <i>x</i> → *x*
        out = replaceRegex(out, #"<(em|i)>([\s\S]*?)</\1>"#, with: "*$2*", caseInsensitive: true)

        // <code>x</code> → `x`
        out = replaceRegex(out, #"<code>([\s\S]*?)</code>"#, with: "`$1`", caseInsensitive: true)

        // <kbd>x</kbd> → `x`
        out = replaceRegex(out, #"<kbd>([\s\S]*?)</kbd>"#, with: "`$1`", caseInsensitive: true)

        // <a href="url">text</a> → [text](url)
        out = replaceRegex(
            out,
            #"<a\s+[^>]*href=["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#,
            with: "[$2]($1)",
            caseInsensitive: true
        )

        // <summary>x</summary> → **x**
        out = replaceRegex(out, #"<summary>([\s\S]*?)</summary>"#, with: "**$1**", caseInsensitive: true)

        // Drop <details> / </details> tags but keep inner content
        out = replaceRegex(out, #"</?details(\s[^>]*)?>"#, with: "", caseInsensitive: true)

        // <img src="url" alt="x" /> → ![x](url) (best effort)
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

        // Strip common structural tags entirely (keep inner text)
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
        "construction": "🚧", "construction_worker": "👷",
        "wrench": "🔧", "hammer": "🔨", "hammer_and_wrench": "🛠",
        "recycle": "♻️", "art": "🎨", "zap": "⚡", "boom": "💥",
        "lock": "🔒", "unlock": "🔓", "key": "🔑",
        "pencil": "✏️", "pencil2": "✏️", "books": "📚", "book": "📖",
        "package": "📦", "rotating_light": "🚨", "ambulance": "🚑",
        "truck": "🚚", "ship": "🚢", "airplane": "✈️",
        "rewind": "⏪", "fast_forward": "⏩",
        "twisted_rightwards_arrows": "🔀", "loop": "🔁",
        "heavy_plus_sign": "➕", "heavy_minus_sign": "➖",
        "arrow_up": "⬆️", "arrow_down": "⬇️", "arrow_right": "➡️", "arrow_left": "⬅️",
        "tag": "🏷", "label": "🏷",
        "star": "⭐", "stars": "🌟", "dizzy": "💫", "100": "💯",
        "poop": "💩", "see_no_evil": "🙈",
        "checkered_flag": "🏁", "triangular_flag_on_post": "🚩",
        "wave": "👋", "ok_hand": "👌", "thumbsup": "👍", "+1": "👍",
        "thumbsdown": "👎", "-1": "👎", "clap": "👏", "muscle": "💪",
        "pray": "🙏", "point_right": "👉", "point_left": "👈",
        "point_up": "👆", "point_down": "👇",
        "eyes": "👀", "raising_hand": "🙋",
        "smile": "😄", "grinning": "😀", "sweat_smile": "😅",
        "joy": "😂", "rofl": "🤣", "sob": "😭", "cry": "😢",
        "angry": "😠", "rage": "😡", "tired_face": "😫",
        "thinking": "🤔", "thinking_face": "🤔",
        "clown_face": "🤡", "ghost": "👻", "alien": "👽", "robot": "🤖",
        "computer": "💻", "keyboard": "⌨️", "iphone": "📱",
        "calendar": "📅", "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉", "bar_chart": "📊",
        "clipboard": "📋", "scroll": "📜", "page_facing_up": "📄",
        "file_folder": "📁", "open_file_folder": "📂",
        "paperclip": "📎", "pushpin": "📌", "round_pushpin": "📍",
        "shield": "🛡", "crossed_swords": "⚔️",
        "gem": "💎", "crystal_ball": "🔮",
        "microscope": "🔬", "telescope": "🔭",
        "test_tube": "🧪", "dna": "🧬",
        "balloon": "🎈", "gift": "🎁", "ribbon": "🎀",
        "heart": "❤️", "broken_heart": "💔", "yellow_heart": "💛",
        "green_heart": "💚", "blue_heart": "💙", "purple_heart": "💜",
        "black_heart": "🖤", "white_heart": "🤍",
        "sparkling_heart": "💖", "two_hearts": "💕",
        "no_entry": "⛔", "no_entry_sign": "🚫",
        "question": "❓", "grey_question": "❔",
        "exclamation": "❗", "grey_exclamation": "❕",
        "bangbang": "‼️", "interrobang": "⁉️",
        "speech_balloon": "💬", "thought_balloon": "💭",
        "globe_with_meridians": "🌐", "earth_americas": "🌎",
        "earth_africa": "🌍", "earth_asia": "🌏",
        "sun_with_face": "🌞", "full_moon": "🌕", "new_moon": "🌑",
        "cloud": "☁️", "snowflake": "❄️",
        "tools": "🛠", "gear": "⚙️", "nut_and_bolt": "🔩",
        "link": "🔗", "mag": "🔍", "mag_right": "🔎",
        "bookmark": "🔖", "bookmark_tabs": "📑",
        "bell": "🔔", "no_bell": "🔕",
        "alarm_clock": "⏰", "hourglass": "⌛", "hourglass_flowing_sand": "⏳",
        "watch": "⌚", "stopwatch": "⏱",
        "rainbow": "🌈", "umbrella": "☂️", "coffee": "☕",
        "checkbox": "☑️", "ballot_box_with_check": "☑️",
        "calling": "📲", "envelope": "✉️", "incoming_envelope": "📨",
        "inbox_tray": "📥", "outbox_tray": "📤",
        "trophy": "🏆", "medal_sports": "🏅", "medal_military": "🎖",
        "first_place_medal": "🥇", "second_place_medal": "🥈", "third_place_medal": "🥉",
        "no_good": "🙅", "ok_woman": "🙆", "tipping_hand_woman": "💁",
        "raised_hands": "🙌", "person_facepalming": "🤦",
        "shrug": "🤷", "person_shrugging": "🤷",
        "metal": "🤘", "vulcan_salute": "🖖", "v": "✌️",
        "saluting_face": "🫡", "salute": "🫡",
        "ledger": "📒", "notebook": "📓", "notebook_with_decorative_cover": "📔",
        "card_file_box": "🗃", "card_box": "🗃",
        "card_index": "📇", "card_index_dividers": "🗂",
        "lipstick": "💄", "ring": "💍", "high_heel": "👠",
        "shirt": "👕", "necktie": "👔", "dress": "👗",
        "rose": "🌹", "cherry_blossom": "🌸", "tulip": "🌷",
        "leaves": "🍃", "herb": "🌿", "four_leaf_clover": "🍀",
        "money_with_wings": "💸", "moneybag": "💰", "dollar": "💵",
        "credit_card": "💳", "receipt": "🧾",
        "office": "🏢", "house": "🏠", "school": "🏫",
        "hospital": "🏥", "bank": "🏦",
        "key2": "🗝", "old_key": "🗝",
        "newspaper": "📰", "satellite": "📡",
        "abacus": "🧮", "chains": "⛓",
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
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
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

private struct StatusBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(filled ? .white : color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(
                    filled ? Color.clear : color.opacity(0.35),
                    lineWidth: 0.5
                )
            )
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
                .textSelection(.enabled)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
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
