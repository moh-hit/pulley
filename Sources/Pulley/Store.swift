import Foundation
import SwiftUI
import Combine

@MainActor
final class Store: ObservableObject {
    @Published var prs: [PR] = []
    @Published var notifications: [InboxThread] = []
    @Published var syncing: Bool = false
    @Published var lastError: String? = nil
    @Published var lastSync: Date? = nil

    private var timer: Timer?
    // v2: added PR.mergeableState — v1 cached blobs fail to decode and are dropped.
    private let cacheKey         = "store.prs.cache.v2"
    private let inboxCacheKey    = "store.inbox.cache.v1"

    init() {
        loadCache()
        startTimer()
    }

    /// Restore the last sync's PR list so the popover shows something
    /// immediately on launch — the next `sync()` overwrites it.
    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let cached = try? JSONDecoder().decode([PR].self, from: data) {
            self.prs = cached
        }
        if let data = UserDefaults.standard.data(forKey: inboxCacheKey),
           let cached = try? JSONDecoder().decode([InboxThread].self, from: data) {
            self.notifications = cached
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(prs) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: inboxCacheKey)
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
                // Fetch PRs and the inbox in parallel — inbox is best-effort:
                // a 403 (PAT without the `notifications` scope) shouldn't
                // tank the whole sync.
                async let prsTask    = client.fetchPRs(scope: scope)
                async let inboxTask  = client.fetchNotifications()
                let fetched = try await prsTask
                let inbox   = (try? await inboxTask) ?? self.notifications
                self.prs = fetched
                self.notifications = inbox
                self.saveCache()
                self.lastSync = Date()
                self.syncing = false
                NotificationsManager.shared.requestAuthorizationIfNeeded()
                NotificationsManager.shared.reconcile(fetched)

                // Off the main actor — git shells out and GitHub round-trips
                // are slow enough that we don't want the sweeper holding up
                // UI updates.
                let openKeys = Set(fetched.map { "\($0.org)/\($0.repo)#\($0.branch)" })
                Task.detached {
                    await PRActions.pruneStaleWorktrees(
                        openBranchKeys: openKeys, client: client
                    )
                }
            } catch {
                self.lastError = error.localizedDescription
                self.syncing = false
            }
        }
    }

    /// Optimistically drop the thread locally, then PATCH GitHub. If the API
    /// call fails the next sync will reseed it — we don't surface the error
    /// inline because the user already moved on.
    func markNotificationRead(_ id: String) {
        notifications.removeAll { $0.id == id }
        saveCache()
        let token = Config.token
        guard !token.isEmpty else { return }
        let client = GitHubClient(token: token, orgs: Config.orgs)
        Task.detached {
            try? await client.markNotificationRead(threadID: id)
        }
    }

    var unreadInboxCount: Int {
        notifications.filter(\.unread).count
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
