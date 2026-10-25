import Foundation
import ServiceManagement
import Security

enum Config {
    private static let kcService = "app.skyhit.pulley"
    private static let kcAccount = "github-token"

    /// Older builds wrote the token under a different keychain service. Reading
    /// is best-effort so an upgraded user keeps their token; writes always go
    /// to the current service.
    private static let legacyKcServices = ["com.local.pulley"]

    private static let orgKey      = "github.org"   // legacy single-org key, kept for migration
    private static let orgsKey     = "github.orgs"
    private static let scopeKey    = "github.scope"
    private static let hasTokenKey = "github.hasToken"
    private static let groupByKey  = "ui.groupBy"
    private static let ideKey      = "ide.preferred"
    private static let baseDirKey  = "ide.baseDir"
    private static let hotkeyKey   = "ui.globalHotkey"
    private static let mergeMethodKey = "git.mergeMethod"
    private static let copilotReviewKey = "review.copilotEnabled"

    /// Whether a token has been saved. Read from UserDefaults — does NOT
    /// touch Keychain. Use this for any "is the app configured?" check at
    /// launch / popover-open so we don't trigger the Keychain prompt before
    /// the user actually needs to sync.
    static var hasToken: Bool {
        UserDefaults.standard.bool(forKey: hasTokenKey)
    }

    /// Reads the GitHub token from Keychain. **This call triggers the macOS
    /// Keychain access prompt** the first time after each rebuild (because
    /// ad-hoc signing produces a different signature). Only call this when
    /// actually about to use the token — e.g. inside `Store.sync()`.
    static var token: String {
        get {
            if let t = Keychain.read(service: kcService, account: kcAccount) { return t }
            // Migrate from a legacy service the first time we see one.
            for legacy in legacyKcServices {
                if let t = Keychain.read(service: legacy, account: kcAccount), !t.isEmpty {
                    Keychain.write(service: kcService, account: kcAccount, value: t)
                    return t
                }
            }
            return ""
        }
        set {
            Keychain.write(service: kcService, account: kcAccount, value: newValue)
            UserDefaults.standard.set(!newValue.isEmpty, forKey: hasTokenKey)
        }
    }

    /// One or more GitHub organizations to query. On first read, migrates the
    /// legacy single-`github.org` value into the new array so existing users
    /// don't lose their setting.
    static var orgs: [String] {
        get {
            if let arr = UserDefaults.standard.stringArray(forKey: orgsKey), !arr.isEmpty {
                return arr
            }
            let legacy = UserDefaults.standard.string(forKey: orgKey) ?? ""
            return legacy.isEmpty ? [] : [legacy]
        }
        set {
            var seen = Set<String>()
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .filter { seen.insert($0.lowercased()).inserted }   // case-insensitive dedupe
            UserDefaults.standard.set(cleaned, forKey: orgsKey)
            // Keep legacy key roughly in sync so a downgrade still works.
            UserDefaults.standard.set(cleaned.first ?? "", forKey: orgKey)
        }
    }

    static var scope: Scope {
        get {
            if let raw = UserDefaults.standard.string(forKey: scopeKey),
               let s = Scope(rawValue: raw) { return s }
            return .author
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: scopeKey) }
    }

    static var groupBy: GroupBy {
        get {
            if let raw = UserDefaults.standard.string(forKey: groupByKey),
               let g = GroupBy(rawValue: raw) { return g }
            return .status
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: groupByKey) }
    }

    static var preferredIDE: IDE {
        get {
            if let raw = UserDefaults.standard.string(forKey: ideKey),
               let i = IDE(rawValue: raw) { return i }
            return .vscode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ideKey) }
    }

    /// Preferred merge strategy, remembered as the default in the merge
    /// confirmation. Squash matches the most common repo convention.
    static var mergeMethod: MergeMethod {
        get {
            if let raw = UserDefaults.standard.string(forKey: mergeMethodKey),
               let m = MergeMethod(rawValue: raw) { return m }
            return .squash
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: mergeMethodKey) }
    }

    static var workspaceBaseDir: String {
        get { UserDefaults.standard.string(forKey: baseDirKey) ?? "./" }
        set { UserDefaults.standard.set(newValue, forKey: baseDirKey) }
    }

    /// Tilde-expanded absolute path of the workspace base directory.
    static var expandedBaseDir: String {
        (workspaceBaseDir as NSString).expandingTildeInPath
    }

    static var hotkey: Hotkey {
        get {
            if let data = UserDefaults.standard.data(forKey: hotkeyKey),
               let h = try? JSONDecoder().decode(Hotkey.self, from: data) {
                return h
            }
            return .defaultHotkey
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: hotkeyKey)
            }
        }
    }

    /// Build a `GitHubClient` from the saved credentials, or `nil` if no token
    /// is stored. **Reads the Keychain** (so it may trigger the access prompt)
    /// — call only when about to hit the API. Collapses the token-fetch +
    /// empty-guard + construct dance that every API call site otherwise repeats.
    static func makeClient() -> GitHubClient? {
        // Mock-data previews must never read the Keychain or call GitHub.
        guard !MockData.isEnabled else { return nil }
        let token = self.token
        guard !token.isEmpty else { return nil }
        return GitHubClient(token: token, orgs: orgs)
    }

    /// Show the "Ask Copilot to review" control in the detail pane. On by
    /// default; users without Copilot code review can hide it.
    static var copilotReviewEnabled: Bool {
        get { UserDefaults.standard.object(forKey: copilotReviewKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: copilotReviewKey) }
    }

    // MARK: - Preferences (applied live from Settings)

    private static func string<T: RawRepresentable>(_ key: String, default value: T) -> T where T.RawValue == String {
        UserDefaults.standard.string(forKey: key).flatMap(T.init(rawValue:)) ?? value
    }
    private static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }

    static var startPage: StartPage {
        get { string("ui.startPage", default: .home) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ui.startPage") }
    }

    /// Minutes between background syncs.
    static var syncIntervalMinutes: Int {
        get { (UserDefaults.standard.object(forKey: "sync.intervalMinutes") as? Int) ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "sync.intervalMinutes") }
    }

    static var menuBarCount: MenuBarCount {
        get { string("ui.menuBarCount", default: .open) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "ui.menuBarCount") }
    }

    static var appearance: AppearanceMode {
        get { string(AppearanceMode.key, default: .system) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: AppearanceMode.key) }
    }

    static var textSize: TextSize {
        get { string(TextSize.key, default: .standard) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: TextSize.key) }
    }

    static var listDensity: ListDensity {
        get { string(ListDensity.key, default: .comfortable) }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ListDensity.key) }
    }

    static var showContributions: Bool {
        get { bool("ui.showContributions", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "ui.showContributions") }
    }

    /// Leave draft PRs out of the menu-bar popover, count and peek menu.
    /// The main window still lists them.
    static let hideDraftsInMenuBarKey = "ui.menuBarHideDrafts"
    static var hideDraftsInMenuBar: Bool {
        get { bool(hideDraftsInMenuBarKey, default: false) }
        set { UserDefaults.standard.set(newValue, forKey: hideDraftsInMenuBarKey) }
    }

    /// Repos hidden everywhere (lists, counts, notifications, inbox), as
    /// lowercased "org/repo".
    static var mutedRepos: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "github.mutedRepos") ?? []) }
        set { UserDefaults.standard.set(newValue.map { $0.lowercased() }.sorted(), forKey: "github.mutedRepos") }
    }

    static func isMuted(org: String, repo: String) -> Bool {
        mutedRepos.contains("\(org)/\(repo)".lowercased())
    }

    static var collapseBotComments: Bool {
        get { bool("review.collapseBotComments", default: true) }
        set { UserDefaults.standard.set(newValue, forKey: "review.collapseBotComments") }
    }

    static func notifies(_ kind: NotificationKind) -> Bool { bool(kind.key, default: true) }
    static func setNotifies(_ kind: NotificationKind, _ on: Bool) { UserDefaults.standard.set(on, forKey: kind.key) }

    static var launchAtLogin: Bool {
        get {
            if #available(macOS 13.0, *) {
                return SMAppService.mainApp.status == .enabled
            }
            return false
        }
        set {
            if #available(macOS 13.0, *) {
                do {
                    if newValue { try SMAppService.mainApp.register() }
                    else        { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("Pulley: launch-at-login toggle failed: \(error)")
                }
            }
        }
    }
}

enum Keychain {
    static func read(service: String, account: String) -> String? {
        let query: [String: Any] = [
            kSecClass        as String: kSecClassGenericPassword,
            kSecAttrService  as String: service,
            kSecAttrAccount  as String: account,
            kSecReturnData   as String: true,
            kSecMatchLimit   as String: kSecMatchLimitOne,
        ]
        var ref: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &ref)
        guard status == errSecSuccess, let data = ref as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(service: String, account: String, value: String) {
        let baseQuery: [String: Any] = [
            kSecClass       as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(baseQuery as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        SecItemAdd(addQuery as CFDictionary, nil)
    }
}

// MARK: - Preference values

enum StartPage: String, CaseIterable, Identifiable {
    case home, all, changes
    var id: String { rawValue }
    var label: String {
        switch self {
        case .home:    return "Home"
        case .all:     return "All pull requests"
        case .changes: return "Changes requested"
        }
    }
}

enum MenuBarCount: String, CaseIterable, Identifiable {
    case open, attention, hidden
    var id: String { rawValue }
    var label: String {
        switch self {
        case .open:      return "Not yet approved"
        case .attention: return "Only what needs you"
        case .hidden:    return "Icon only"
        }
    }
}

enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark
    static let key = "ui.appearance"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum ListDensity: String, CaseIterable, Identifiable {
    case comfortable, compact
    static let key = "ui.listDensity"
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Vertical padding for list rows.
    var rowPadding: CGFloat { self == .compact ? 6 : 11 }
}

enum TextSize: String, CaseIterable, Identifiable {
    case small, standard, large
    static let key = "ui.textSize"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .small:    return "Small"
        case .standard: return "Default"
        case .large:    return "Large"
        }
    }
    /// Multiplier applied to every Theme font and Icon size.
    var scale: CGFloat {
        switch self {
        case .small:    return 0.92
        case .standard: return 1
        case .large:    return 1.12
        }
    }
}

enum NotificationKind: String, CaseIterable, Identifiable {
    case newPR, review, ci, conflicts, mergeFlow
    var id: String { rawValue }
    var key: String { "notify.\(rawValue)" }
    var title: String {
        switch self {
        case .newPR:     return "New pull requests"
        case .review:    return "Approvals and change requests"
        case .ci:        return "CI results"
        case .conflicts: return "Merge conflicts"
        case .mergeFlow: return "Merge queue and auto-merge"
        }
    }
    var detail: String {
        switch self {
        case .newPR:     return "A pull request appears in your scope."
        case .review:    return "A PR is approved, or changes are requested."
        case .ci:        return "Checks start failing, or turn green again."
        case .conflicts: return "A PR starts conflicting with its base branch."
        case .mergeFlow: return "A PR leaves the merge queue or loses auto-merge without merging."
        }
    }
}

/// Sections of the Settings dialog; other parts of the app can open it on one.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general, appearance, github, pullRequests, notifications, shortcuts, about
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general:       return "General"
        case .appearance:    return "Appearance"
        case .github:        return "GitHub"
        case .pullRequests:  return "Pull requests"
        case .notifications: return "Notifications"
        case .shortcuts:     return "Shortcuts"
        case .about:         return "About"
        }
    }
    var icon: String {
        switch self {
        case .general:       return "gearshape"
        case .appearance:    return "circle.hexagongrid"
        case .github:        return "lock.shield"
        case .pullRequests:  return "arrow.triangle.pull"
        case .notifications: return "bell"
        case .shortcuts:     return "command"
        case .about:         return "info.circle"
        }
    }
}
