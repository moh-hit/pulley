import Foundation
import SwiftUI
import Combine

@MainActor
final class Store: ObservableObject {
    @Published var prs: [PR] = []
    @Published var syncing: Bool = false
    @Published var lastError: String? = nil
    @Published var lastSync: Date? = nil

    private var timer: Timer?
    // v2: added PR.mergeableState — v1 cached blobs fail to decode and are dropped.
    private let cacheKey = "store.prs.cache.v2"

    init() {
        loadCache()
        startTimer()
    }

    /// Restore the last sync's PR list so the popover shows something
    /// immediately on launch — the next `sync()` overwrites it.
    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let cached = try? JSONDecoder().decode([PR].self, from: data)
        else { return }
        self.prs = cached
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(prs) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    deinit {
        timer?.invalidate()
    }

    func startTimer() {
        timer?.invalidate()
        // Auto-sync every 30 minutes (manual sync still available via the button)
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.sync() }
        }
    }

    /// Sync only if the last successful sync is older than `maxAge` seconds.
    /// Used on popover-open so frequent toggling doesn't hammer the API; the
    /// manual refresh button calls `sync()` directly to force a fetch.
    func syncIfStale(maxAge: TimeInterval) {
        if let last = lastSync, Date().timeIntervalSince(last) < maxAge { return }
        sync()
    }

    func sync() {
        guard !syncing else { return }
        guard Config.hasToken, !Config.orgs.isEmpty else {
            lastError = "Token or org not set"
            return
        }
        // Read the keychain exactly once per sync — this is the call that
        // triggers the macOS Keychain prompt after a rebuild.
        let token = Config.token
        guard !token.isEmpty else {
            lastError = "Token not set"
            return
        }
        syncing = true
        lastError = nil

        let client = GitHubClient(token: token, orgs: Config.orgs)
        let scope  = Config.scope

        Task {
            do {
                let fetched = try await client.fetchPRs(scope: scope)
                self.prs = fetched
                self.saveCache()
                self.lastSync = Date()
                self.syncing = false
                NotificationsManager.shared.requestAuthorizationIfNeeded()
                NotificationsManager.shared.reconcile(fetched)
            } catch {
                self.lastError = error.localizedDescription
                self.syncing = false
            }
        }
    }

    /// Count of PRs that need attention (anything not yet approved).
    var openCount: Int {
        prs.filter { $0.status != .approved }.count
    }

    /// True if anything in the current scope deserves a red badge — i.e. a
    /// reviewer asked for changes, or CI is failing.
    var needsAttention: Bool {
        prs.contains { $0.status == .changes || $0.checkStatus == .failure }
    }
}
