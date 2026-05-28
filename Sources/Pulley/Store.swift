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

    /// Recent optimistic draft toggles. Keyed by PR id; value is the new
    /// `isDraft` and when we applied it. `/search/issues` (and even the
    /// per-PR detail endpoint, for a few seconds) can lag the draft flag,
    /// so during the TTL window we prefer the override over whatever the
    /// fetch returned — otherwise the UI flips, syncs, then flips back.
    private var draftOverrides: [String: (isDraft: Bool, at: Date)] = [:]
    private let draftOverrideTTL: TimeInterval = 30

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
                let merged  = self.applyDraftOverrides(to: fetched)
                self.prs = merged
                self.notifications = inbox
                self.saveCache()
                self.lastSync = Date()
                self.syncing = false
                NotificationsManager.shared.requestAuthorizationIfNeeded()
                NotificationsManager.shared.reconcile(merged)

                // Off the main actor — git shells out and GitHub round-trips
                // are slow enough that we don't want the sweeper holding up
                // UI updates.
                let openKeys = Set(merged.map { "\($0.org)/\($0.repo)#\($0.branch)" })
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

    /// Overlay recent optimistic draft toggles on top of a freshly-fetched
    /// list. Expired entries are dropped on the way through; this is the
    /// only place we prune, which is fine because every sync runs through
    /// here.
    private func applyDraftOverrides(to fetched: [PR]) -> [PR] {
        let cutoff = Date().addingTimeInterval(-draftOverrideTTL)
        draftOverrides = draftOverrides.filter { $0.value.at > cutoff }
        guard !draftOverrides.isEmpty else { return fetched }
        return fetched.map { pr in
            guard let override = draftOverrides[pr.id],
                  override.isDraft != pr.isDraft else { return pr }
            return PR(
                id: pr.id,
                number: pr.number,
                title: pr.title,
                org: pr.org,
                repo: pr.repo,
                url: pr.url,
                branch: pr.branch,
                headSha: pr.headSha,
                assignee: pr.assignee,
                status: pr.status,
                isDraft: override.isDraft,
                updatedAt: pr.updatedAt,
                createdAt: pr.createdAt,
                checks: pr.checks,
                checkStatus: pr.checkStatus,
                mergeableState: pr.mergeableState,
                nodeID: pr.nodeID
            )
        }
    }

    /// Apply a draft/ready transition locally without waiting for the next
    /// `sync()`. `/search/issues` is eventually-consistent for draft flips
    /// (the search index can lag the underlying record by several seconds),
    /// so we patch the in-memory PR right after the GraphQL mutation returns
    /// — the badge and the action-row label flip immediately. The background
    /// sync still runs to reconcile every other field.
    func setLocalDraft(prID: String, isDraft: Bool) {
        draftOverrides[prID] = (isDraft, Date())
        guard let idx = prs.firstIndex(where: { $0.id == prID }) else { return }
        let old = prs[idx]
        prs[idx] = PR(
            id: old.id,
            number: old.number,
            title: old.title,
            org: old.org,
            repo: old.repo,
            url: old.url,
            branch: old.branch,
            headSha: old.headSha,
            assignee: old.assignee,
            status: old.status,
            isDraft: isDraft,
            updatedAt: old.updatedAt,
            createdAt: old.createdAt,
            checks: old.checks,
            checkStatus: old.checkStatus,
            mergeableState: old.mergeableState,
            nodeID: old.nodeID
        )
        saveCache()
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
