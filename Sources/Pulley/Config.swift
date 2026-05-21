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
