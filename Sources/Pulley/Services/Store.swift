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
    private let readThreadsKey   = "store.inbox.read.v1"

    /// Threads the user marked read, keyed by thread id with the `updatedAt`
    /// they had at read time. GitHub's `/notifications` feed is cached and
    /// eventually-consistent (and a PAT without `notifications` scope can't
    /// mark-read at all), so a thread we just read keeps coming back on the
    /// next fetch. We suppress any fetched thread that's in here UNLESS it has
    /// newer activity (`updatedAt` advanced past what we read) — that way a
    /// thread that gets a new comment correctly resurfaces.
    private var readThreads: [String: Date] = [:]

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
        if let data = UserDefaults.standard.data(forKey: readThreadsKey),
           let cached = try? JSONDecoder().decode([String: Date].self, from: data) {
            self.readThreads = cached
        }
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(prs) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
        if let data = try? JSONEncoder().encode(notifications) {
            UserDefaults.standard.set(data, forKey: inboxCacheKey)
        }
        if let data = try? JSONEncoder().encode(readThreads) {
            UserDefaults.standard.set(data, forKey: readThreadsKey)
        }
    }

    /// Drop threads the user already read, keeping any whose activity is newer
    /// than when they read it. Also prunes read-markers older than 30 days so
    /// the map doesn't grow without bound.
    private func filterReadThreads(_ inbox: [InboxThread]) -> [InboxThread] {
        var kept: [InboxThread] = []
        for thread in inbox {
            if let readAt = readThreads[thread.id] {
                if thread.updatedAt > readAt {
                    readThreads[thread.id] = nil   // new activity — surface again
                    kept.append(thread)
                }
                // otherwise: already read, suppress
            } else {
                kept.append(thread)
            }
        }
        let cutoff = Date().addingTimeInterval(-30 * 86_400)
        readThreads = readThreads.filter { $0.value > cutoff }
        return kept
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
                let inbox   = (try? await inboxTask).map(self.filterReadThreads) ?? self.notifications
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

    /// Optimistically drop the thread locally and remember it as read (keyed by
    /// its current `updatedAt`), so it stays gone even though GitHub's cached
    /// `/notifications` feed keeps returning it for a while. Then PATCH GitHub
    /// best-effort. `filterReadThreads` re-surfaces it only if it gets newer
    /// activity later.
    func markNotificationRead(_ id: String) {
        let readAt = notifications.first { $0.id == id }?.updatedAt ?? Date()
        readThreads[id] = readAt
        notifications.removeAll { $0.id == id }
        saveCache()
        guard let client = Config.makeClient() else { return }
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
            return pr.with(isDraft: override.isDraft)
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
        prs[idx] = prs[idx].with(isDraft: isDraft)
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
