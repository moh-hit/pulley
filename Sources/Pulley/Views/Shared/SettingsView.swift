import SwiftUI
import AppKit

/// Settings as a dialog with its own left navigation. Everything except the
/// GitHub credentials applies the moment it changes; the token and
/// organizations are a draft with an explicit Save (and Test connection),
/// because a half-typed token shouldn't trigger a sync.
struct SettingsView: View {
    @EnvironmentObject var store: Store
    let onClose: () -> Void

    @State private var selection: SettingsSection

    init(initialSection: SettingsSection? = nil, onClose: @escaping () -> Void) {
        self.onClose = onClose
        // First run lands on GitHub, where the setup happens.
        _selection = State(initialValue: initialSection ?? (Config.hasToken ? .general : .github))
    }

    // MARK: GitHub draft

    // Intentionally NOT initialized from `Config.token` — reading the keychain
    // here would trigger the macOS prompt every time settings is opened. The
    // field starts empty; if a token is already saved (Config.hasToken), we
    // show a "saved" hint and only write a new value if the user types one.
    @State private var token: String = ""
    @State private var tokenCleared: Bool = false
    @State private var showTokenHelp: Bool = false
    @State private var tokenHelpKind: TokenHelpKind = .classic
    @State private var orgs: [String] = {
        let saved = Config.orgs
        return saved.isEmpty ? [""] : saved
    }()
    @State private var scope: Scope = Config.scope
    @State private var connection: ConnectionState = .idle
    @State private var savedFlash = false

    enum ConnectionState: Equatable {
        case idle, testing
        case connected(login: String, scopes: [String]?)
        case failed(SyncProblem)
    }

    /// One animation for the token-guide reveal so the ⓘ toggle and the card's
    /// own close button stay in lockstep.
    private static let tokenHelpAnim: Animation = .spring(response: 0.34, dampingFraction: 0.9)

    /// Which token type the guide is showing. The card displays one at a time
    /// (segmented switch) so the panel stays short.
    enum TokenHelpKind: String, CaseIterable, Identifiable {
        case classic = "Classic"
        case fineGrained = "Fine-grained"
        var id: String { rawValue }
    }

    // MARK: Live preferences

    @State private var launchAtLogin = Config.launchAtLogin
    @State private var startPage = Config.startPage
    @State private var syncInterval = Config.syncIntervalMinutes
    @State private var menuBarCount = Config.menuBarCount
    @State private var appearance = Config.appearance
    @State private var textSize = Config.textSize
    @State private var density = Config.listDensity
    @State private var showContributions = Config.showContributions
    @State private var collapseBots = Config.collapseBotComments
    @State private var copilotReview = Config.copilotReviewEnabled
    @State private var mergeMethod = Config.mergeMethod
    @State private var preferredIDE = Config.preferredIDE
    @State private var baseDir = Config.workspaceBaseDir
    @State private var hotkey = Config.hotkey
    @State private var notify: [NotificationKind: Bool] = Dictionary(
        uniqueKeysWithValues: NotificationKind.allCases.map { ($0, Config.notifies($0)) }
    )

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(Theme.hairline).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text(selection.title)
                        .font(Theme.display(26))
                        .padding(.bottom, 2)
                    sectionContent
                }
                .padding(.horizontal, 28)
                .padding(.top, 26)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Theme.panel)
        }
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Icon("xmark", size: 11)
                    .foregroundColor(.secondary)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.chrome))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close (Esc)")
            .accessibilityLabel("Close settings")
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: launchAtLogin) { Config.launchAtLogin = $0 }
        .onChange(of: startPage) { Config.startPage = $0 }
        .onChange(of: syncInterval) {
            Config.syncIntervalMinutes = $0
            store.startTimer()
        }
        .onChange(of: menuBarCount) {
            Config.menuBarCount = $0
            NotificationCenter.default.post(name: .pulleyPreferencesChanged, object: nil)
        }
        .onChange(of: appearance) {
            Config.appearance = $0
            $0.apply()
        }
        .onChange(of: textSize) {
            Config.textSize = $0
            Theme.scale = $0.scale
        }
        .onChange(of: density) { Config.listDensity = $0 }
        .onChange(of: showContributions) { Config.showContributions = $0 }
        .onChange(of: collapseBots) { Config.collapseBotComments = $0 }
        .onChange(of: copilotReview) { Config.copilotReviewEnabled = $0 }
        .onChange(of: mergeMethod) { Config.mergeMethod = $0 }
        .onChange(of: preferredIDE) { Config.preferredIDE = $0 }
        .onChange(of: baseDir) { Config.workspaceBaseDir = $0 }
        .onChange(of: hotkey) {
            Config.hotkey = $0
            NotificationCenter.default.post(name: .pulleyHotkeyChanged, object: nil)
        }
        .onChange(of: notify) { values in
            for (kind, on) in values { Config.setNotifies(kind, on) }
        }
    }

    // MARK: - Navigation

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Settings")
                .font(Theme.ui(11, .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 22)
                .padding(.bottom, 8)
            ForEach(SettingsSection.allCases) { section in
                SidebarItem(
                    title: section.title,
                    icon: section.icon,
                    countTint: nil,
                    isSelected: selection == section
                ) { selection = section }
                .overlay(alignment: .trailing) {
                    if section == .github && !Config.hasToken {
                        Circle().fill(Color.red).frame(width: 6, height: 6).padding(.trailing, 10)
                            .accessibilityLabel("Needs setup")
                    }
                }
            }
            Spacer(minLength: 12)
            Text("Pulley \(appVersion)")
                .font(Theme.mono(11))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 196)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.chrome)
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selection {
        case .general:       generalSection
        case .appearance:    appearanceSection
        case .github:        githubSection
        case .pullRequests:  pullRequestsSection
        case .notifications: notificationsSection
        case .shortcuts:     shortcutsSection
        case .about:         aboutSection
        }
    }

    // MARK: - General

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow("Launch at login", detail: "Start Pulley in the menu bar when you log in.") {
                    Toggle("", isOn: $launchAtLogin).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow("Start page", detail: "What the window shows when it opens.") {
                    picker($startPage, StartPage.allCases) { $0.label }
                }
            }
            SettingsGroup {
                SettingsRow("Sync every", detail: "Pulley also syncs when you open it after a while, and on ⌘R.") {
                    Picker("", selection: $syncInterval) {
                        ForEach([5, 10, 15, 30, 60], id: \.self) { m in
                            Text(m == 60 ? "Hour" : "\(m) minutes").tag(m)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsRow("Menu bar count", detail: "The number next to the Pulley icon.") {
                    picker($menuBarCount, MenuBarCount.allCases) { $0.label }
                }
            }
        }
    }

    // MARK: - Appearance

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow("Theme", detail: "Follow the system, or always use light or dark.") {
                    segmented($appearance, AppearanceMode.allCases) { $0.label }
                }
                SettingsRow("Text size", detail: "Scales text and icons across the window and menu bar.") {
                    segmented($textSize, TextSize.allCases) { $0.label }
                }
                SettingsRow("List density", detail: "Compact fits more pull requests on screen.") {
                    segmented($density, ListDensity.allCases) { $0.label }
                }
            }
            SettingsGroup {
                SettingsRow("Contribution graph", detail: "Show your GitHub activity on Home.") {
                    Toggle("", isOn: $showContributions).toggleStyle(.switch).labelsHidden()
                }
                SettingsRow("Collapse bot comments", detail: "Copilot, CodeRabbit and other bots start as one line in Files.") {
                    Toggle("", isOn: $collapseBots).toggleStyle(.switch).labelsHidden()
                }
            }
        }
    }

    // MARK: - GitHub

    private var githubSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Personal access token", detail: nil, info: true)
                    HStack(spacing: 6) {
                        SecureField(
                            Config.hasToken && !tokenCleared
                                ? "•••••••••• saved — leave blank to keep"
                                : "ghp_… or github_pat_…",
                            text: $token
                        )
                        .textFieldStyle(.roundedBorder)
                        .help("Paste a GitHub personal access token. The ⓘ next to the title has a setup guide.")
                        Button("Paste") {
                            if let s = NSPasteboard.general.string(forType: .string) {
                                token = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                tokenCleared = false
                            }
                        }
                        if !token.isEmpty {
                            Button("Clear") { token = "" }
                        } else if Config.hasToken && !tokenCleared {
                            Button("Remove") { tokenCleared = true }
                                .help("Delete the saved token from the Keychain on Save")
                        }
                    }
                    caption(tokenCleared
                            ? "The saved token will be removed when you save."
                            : "Classic or fine-grained. Stored only in your macOS Keychain.")
                    if showTokenHelp {
                        tokenHelpCard
                            .transition(.asymmetric(
                                insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)),
                                removal: .opacity
                            ))
                    }
                }
                .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Organizations", detail: "Pull requests are gathered across all of them.")
                    ForEach(orgs.indices, id: \.self) { i in
                        HStack(spacing: 6) {
                            TextField("github-org-name", text: $orgs[i])
                                .textFieldStyle(.roundedBorder)
                            Button {
                                orgs.remove(at: i)
                                if orgs.isEmpty { orgs = [""] }
                            } label: {
                                Icon("minus.circle", size: 13).foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .disabled(orgs.count == 1)
                            .help("Remove organization")
                            .accessibilityLabel("Remove organization")
                        }
                    }
                    Button {
                        orgs.append("")
                    } label: {
                        Label("Add organization", systemImage: "plus").font(Theme.ui(12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(.vertical, 12)

                SettingsRow("Show pull requests", detail: "Which of your PRs Pulley lists.") {
                    picker($scope, Scope.allCases) { $0.label }
                }
            }

            HStack(spacing: 10) {
                Button(action: testConnection) {
                    Label("Test connection", systemImage: "bolt.horizontal")
                }
                .disabled(!hasUsableToken || connection == .testing)
                connectionStatus
                Spacer()
                if savedFlash {
                    Text("Saved").font(Theme.ui(12)).foregroundColor(.secondary)
                }
                Button("Save changes", action: saveGitHub)
                    .buttonStyle(.borderedProminent)
                    .disabled(!githubDirty || !hasUsableToken || !hasAnyOrg)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .animation(Self.tokenHelpAnim, value: showTokenHelp)
    }

    @ViewBuilder
    private var connectionStatus: some View {
        switch connection {
        case .idle:
            EmptyView()
        case .testing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(Theme.ui(12)).foregroundColor(.secondary)
            }
        case .connected(let login, let scopes):
            VStack(alignment: .leading, spacing: 2) {
                Label("Connected as @\(login)", systemImage: "checkmark.circle.fill")
                    .font(Theme.ui(12, .medium))
                    .foregroundColor(.green)
                Text(scopeSummary(scopes))
                    .font(Theme.ui(11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let problem):
            Text(problem.message)
                .font(Theme.ui(12))
                .foregroundColor(.red)
                .fixedSize(horizontal: false, vertical: true)
                .help(problem.raw)
        }
    }

    private func scopeSummary(_ scopes: [String]?) -> String {
        guard let scopes else {
            return "Fine-grained token. The Inbox needs a classic token with the notifications scope."
        }
        let missing = ["repo", "read:org", "notifications"].filter { !scopes.contains($0) }
        if missing.isEmpty { return "Classic token with everything Pulley uses." }
        let note = missing == ["notifications"] ? " (the Inbox needs it)" : ""
        return "Classic token, missing \(missing.joined(separator: ", "))\(note)."
    }

    // MARK: - Pull requests

    private var pullRequestsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow("Default merge method", detail: "Listed first when you merge. Repos that don't allow it are skipped.") {
                    picker($mergeMethod, MergeMethod.allCases) { $0.label }
                }
                SettingsRow("Copilot code review", detail: "Show “Ask Copilot to review” on pull requests.") {
                    Toggle("", isOn: $copilotReview).toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsGroup {
                VStack(alignment: .leading, spacing: 10) {
                    rowTitle("Open in", detail: "Pulley checks the branch out as a worktree, then opens it here.")
                    let visibleIDEs = IDE.allCases.filter { $0.installedURL != nil || $0 == preferredIDE }
                    if visibleIDEs.isEmpty {
                        caption("No supported editor found. Install VS Code, Cursor or Zed.")
                    } else {
                        HStack(spacing: 8) {
                            ForEach(visibleIDEs) { ide in
                                IDETile(ide: ide, selected: preferredIDE == ide) { preferredIDE = ide }
                            }
                        }
                    }
                }
                .padding(.vertical, 12)

                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Workspace folder", detail: "Where your clones live: Pulley looks for <folder>/<repo>, and puts worktrees beside it.")
                    HStack(spacing: 6) {
                        TextField("~/code", text: $baseDir)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose…") {
                            if let url = chooseDirectory() { baseDir = shortenPath(url.path) }
                        }
                    }
                    if !workspaceExists {
                        Label("This folder doesn't exist, so Open in won't find your repositories.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(Theme.ui(12))
                            .foregroundColor(.orange)
                    }
                }
                .padding(.vertical, 12)
            }
        }
    }

    private var workspaceExists: Bool {
        var isDir: ObjCBool = false
        let path = (baseDir as NSString).expandingTildeInPath
        return baseDir != "./" && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                ForEach(NotificationKind.allCases) { kind in
                    SettingsRow(kind.title, detail: kind.detail) {
                        Toggle("", isOn: Binding(
                            get: { notify[kind] ?? true },
                            set: { notify[kind] = $0 }
                        ))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                }
            }
            HStack(spacing: 4) {
                caption("Banners and sounds are controlled by macOS.")
                Button("Open notification settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.link)
                .font(Theme.ui(11))
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                VStack(alignment: .leading, spacing: 8) {
                    rowTitle("Summon Pulley", detail: "Opens the menu-bar popover from any app. Click the field, then press a combination with at least one modifier.")
                    HStack(spacing: 6) {
                        HotkeyRecorder(hotkey: $hotkey)
                        Spacer()
                        Button("Default") { hotkey = .defaultHotkey }
                        Button("Clear") { hotkey = .none }.disabled(!hotkey.isSet)
                    }
                }
                .padding(.vertical, 12)
            }
            Text("IN THE WINDOW").eyebrow()
            SettingsGroup {
                ForEach(Self.windowKeys, id: \.0) { key, action in
                    HStack {
                        Text(action).font(Theme.ui(13))
                        Spacer()
                        Text(key)
                            .font(Theme.mono(12))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.panel))
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private static let windowKeys: [(String, String)] = [
        ("↑ ↓  or  k j", "Move through pull requests"),
        ("↩", "Open on GitHub"),
        ("⌘.  or  o", "Open in your editor"),
        ("c", "Copy the branch name"),
        ("Esc", "Clear the selection"),
        ("⌘F", "Search"),
        ("⌘R", "Sync now"),
        ("⌘1 – ⌘7", "Switch sidebar sections"),
        ("⌃⌘S", "Show or hide the sidebar"),
        ("⌘,", "Settings"),
    ]

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsGroup {
                SettingsRow("Version", detail: nil) {
                    Text(appVersion).font(Theme.mono(12)).foregroundColor(.secondary)
                }
                SettingsRow("What's new", detail: "Release notes for every version.") {
                    linkButton("Changelog", "https://github.com/moh-hit/pulley/blob/main/CHANGELOG.md")
                }
                SettingsRow("Source code", detail: "Pulley is open source under the MIT license.") {
                    linkButton("GitHub", "https://github.com/moh-hit/pulley")
                }
                SettingsRow("Report a problem", detail: "Bugs and ideas are welcome.") {
                    linkButton("Open an issue", "https://github.com/moh-hit/pulley/issues/new")
                }
            }
            caption("Fonts: Geist, Geist Mono and Instrument Serif (SIL Open Font License). Icons: Phosphor (MIT).")
        }
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    // MARK: - GitHub actions

    private var hasAnyOrg: Bool {
        orgs.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// A new token was typed, or one is saved and not marked for removal.
    private var hasUsableToken: Bool {
        if !token.isEmpty { return true }
        return Config.hasToken && !tokenCleared
    }

    private var cleanedOrgs: [String] {
        orgs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private var githubDirty: Bool {
        !token.isEmpty || tokenCleared || cleanedOrgs != Config.orgs || scope != Config.scope
    }

    private func testConnection() {
        // Only an explicit test reads the saved token (it may prompt for
        // Keychain access); a typed token is tested without saving it.
        if store.isMockData {
            // Previews never read the Keychain or call GitHub.
            connection = .connected(login: "mohit", scopes: ["repo", "read:org"])
            return
        }
        let candidate = token.isEmpty ? Config.token : token
        guard !candidate.isEmpty else { return }
        connection = .testing
        let client = GitHubClient(token: candidate, orgs: cleanedOrgs)
        Task {
            do {
                let info = try await client.tokenInfo()
                await MainActor.run { connection = .connected(login: info.login, scopes: info.scopes) }
            } catch {
                await MainActor.run { connection = .failed(SyncProblem(raw: error.localizedDescription)) }
            }
        }
    }

    private func saveGitHub() {
        // Touch the keychain only when there's actually something to write or
        // delete — otherwise leave it untouched (no prompt).
        if !token.isEmpty {
            Config.token = token
        } else if tokenCleared {
            Config.token = ""        // clears keychain + flips hasToken to false
        }
        Config.orgs = orgs
        Config.scope = scope
        token = ""
        tokenCleared = false
        orgs = Config.orgs.isEmpty ? [""] : Config.orgs
        store.sync()
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { savedFlash = false } }
    }

    // MARK: - Building blocks

    private func rowTitle(_ title: String, detail: String?, info: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(title).font(Theme.ui(13, .medium))
                if info {
                    Button {
                        withAnimation(Self.tokenHelpAnim) { showTokenHelp.toggle() }
                    } label: {
                        Icon(showTokenHelp ? "info.circle.fill" : "info.circle", size: 12)
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(showTokenHelp ? "Hide token setup guide" : "How do I create a token?")
                    .accessibilityLabel(showTokenHelp ? "Hide token setup guide" : "How do I create a token?")
                }
            }
            if let detail {
                Text(detail)
                    .font(Theme.ui(12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(Theme.ui(11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func picker<T: Hashable>(_ selection: Binding<T>, _ options: [T], label: @escaping (T) -> String) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
    }

    private func segmented<T: Hashable>(_ selection: Binding<T>, _ options: [T], label: @escaping (T) -> String) -> some View {
        Picker("", selection: selection) {
            ForEach(options, id: \.self) { Text(label($0)).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private func linkButton(_ title: String, _ url: String) -> some View {
        Button(title) {
            if let u = URL(string: url) { NSWorkspace.shared.open(u) }
        }
    }

    // MARK: - Token setup guide

    /// Pre-filled GitHub classic-token page: scopes are checked on arrival, so
    /// the user just names it and clicks Generate.
    private var classicTokenURL: URL {
        URL(string: "https://github.com/settings/tokens/new?description=Pulley&scopes=repo,read:org,notifications")!
    }

    /// Fine-grained tokens can't be pre-filled (GitHub has no query param for
    /// per-resource permissions), so we deep-link the page and list what to set.
    private var fineGrainedTokenURL: URL {
        URL(string: "https://github.com/settings/personal-access-tokens/new")!
    }

    private var tokenHelpCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Picker("", selection: $tokenHelpKind) {
                    ForEach(TokenHelpKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.small)
                .fixedSize()

                Spacer(minLength: 8)

                Button {
                    withAnimation(Self.tokenHelpAnim) { showTokenHelp = false }
                } label: {
                    Icon("xmark", size: 9)
                        .foregroundColor(.secondary)
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Hide guide")
                .accessibilityLabel("Hide guide")
            }

            Group {
                switch tokenHelpKind {
                case .classic:     classicHelp
                case .fineGrained: fineGrainedHelp
                }
            }
            .animation(.easeInOut(duration: 0.16), value: tokenHelpKind)

            Text("Then paste it above and Save — stored only in your macOS Keychain.")
                .font(Theme.ui(11))
                .foregroundColor(.secondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.2), lineWidth: 0.5)
        )
        .padding(.top, 4)
    }

    private var classicHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Full access, including the Inbox. Scopes to tick:")
                .font(Theme.ui(11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 5) {
                scopeChip("repo")
                scopeChip("read:org")
                scopeChip("notifications")
            }
            createTokenButton("Open GitHub — scopes pre-filled", url: classicTokenURL)
            Text("`notifications` is optional — it powers the Inbox tab.")
                .font(Theme.ui(11))
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fineGrainedHelp: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-repo access; no Inbox. Set these permissions:")
                .font(Theme.ui(11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("**Read & write** — Pull requests, Contents, Checks, Actions")
                Text("**Read** — Commit statuses")
            }
            .font(Theme.ui(11))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            createTokenButton("Open GitHub", url: fineGrainedTokenURL)
            Text("Under Repository access, pick the repos in your orgs. Metadata: Read is automatic.")
                .font(Theme.ui(11))
                .foregroundColor(.secondary.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func scopeChip(_ s: String) -> some View {
        Text(s)
            .font(Theme.mono(11, .semibold))
            .foregroundColor(.primary.opacity(0.85))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.08)))
    }

    private func createTokenButton(_ title: String, url: URL) -> some View {
        Button {
            PRActions.openInBrowser(url)
        } label: {
            HStack(spacing: 5) {
                Icon("arrow.up.forward.square", size: 10)
                Text(title)
                    .font(Theme.ui(11, .medium))
            }
        }
        .controlSize(.small)
        .help("Opens \(url.host ?? "GitHub") in your browser")
    }

    // MARK: - Directory picker

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Config.expandedBaseDir)

        // Suspend the popover's outside-click dismissal while the panel is up —
        // a click on another app's window during the modal would otherwise
        // close the popover and strand this sheet.
        NotificationCenter.default.post(name: .pulleyPauseDismissal, object: nil)
        defer { NotificationCenter.default.post(name: .pulleyResumeDismissal, object: nil) }

        // Make the panel actually appear on top — popover is the key window.
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel

        if panel.runModal() == .OK { return panel.url }
        return nil
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Hotkey recorder

/// Click-to-record field for a global hotkey. While recording, a local
/// NSEvent monitor captures the next key + modifier combo; Esc cancels.
/// We post `.pulleyKeyMonitorPause` so the popover's own key monitor doesn't
/// swallow the keystrokes before we see them.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any? = nil

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press combo…" : hotkey.display)
                .font(Theme.mono(12, recording ? .semibold : .regular))
                .foregroundColor(recording ? .accentColor : .primary)
                .frame(minWidth: 110, alignment: .center)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(recording
                              ? Color.accentColor.opacity(0.18)
                              : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(recording ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: recording ? 1.0 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(recording ? "Press a key combo, or Esc to cancel" : "Click to change")
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .pulleyKeyMonitorPause, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one modifier so we don't bind plain letters.
            guard !mods.isEmpty else { return nil }
            hotkey = Hotkey(modifiers: carbonModifiers(mods),
                            keyCode:   UInt32(event.keyCode))
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if recording {
            NotificationCenter.default.post(name: .pulleyKeyMonitorResume, object: nil)
        }
        recording = false
    }
}

// MARK: - IDE tile

/// Icon-led IDE picker tile. Uses the real `.app` icon when the IDE is
/// installed, falls back to a system glyph when it isn't.
private struct IDETile: View {
    let ide: IDE
    let selected: Bool
    let onTap: () -> Void

    private var installed: Bool { ide.installedURL != nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Group {
                    if let icon = ide.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: ide.fallbackSymbol)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                Text(ide.displayName)
                    .font(Theme.ui(11, selected ? .semibold : .regular))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        selected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: selected ? 1.2 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(installed ? 1.0 : 0.55)
        .help(installed ? ide.displayName : "\(ide.displayName) not installed")
    }
}

// MARK: - Settings building blocks

/// A rounded group of rows on the warm surface, separated by hairlines.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        _VariadicView.Tree(GroupLayout()) { content }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.chrome.opacity(0.6))
            )
    }

    private struct GroupLayout: _VariadicView_MultiViewRoot {
        func body(children: _VariadicView.Children) -> some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(children.enumerated()), id: \.offset) { index, child in
                    if index > 0 { Rectangle().fill(Theme.hairline).frame(height: 1) }
                    child
                }
            }
        }
    }
}

/// Title and one-line explanation on the left, the control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let control: Control

    init(_ title: String, detail: String?, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.ui(13, .medium))
                if let detail {
                    Text(detail)
                        .font(Theme.ui(12))
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.vertical, 12)
    }
}
