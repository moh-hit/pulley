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
    /// Which PRs are listed (authored, review requests, …). The popover's
    /// tabs switch it through `switchScope(_:)`.
    @Published private(set) var scope: Scope
    /// Last list fetched for each scope this session, so switching tabs shows
    /// something immediately while the fresh fetch runs.
    private var prsByScope: [Scope: [PR]] = [:]
    /// Open PRs per scope for the popover's tab counts, refreshed on sync.
    @Published private(set) var scopeCounts: [Scope: Int] = [:]
    /// PRs you nudged reviewers on, so Up next doesn't suggest it again
    /// straight away.
    @Published private(set) var nudgedAt: [String: Date] = [:]
    private let nudgedKey = "store.nudged.v1"
    /// First name (or login) for the main window's greeting. Fetched once.
    @Published var viewerName: String? = nil
    /// Set to ask the main window to open Settings on a section (from the
    /// popover, menus or shortcuts); the window clears it once shown.
    @Published var settingsRequest: SettingsSection? = nil
    /// Contribution graph for Home. Refreshed at most hourly, cached on disk.
    @Published var contributions: ContributionCalendar? = nil
    private var contributionsFetchedAt: Date? = nil
    private let contributionsCacheKey = "store.contributions.v1"

    /// True only for debug launches explicitly started with
    /// `PULLEY_MOCK_DATA=1`. Mock mode never reads or writes user data.
    let isMockData: Bool

    private var timer: Timer?
    // v2: added PR.mergeableState — v1 cached blobs fail to decode and are dropped.
    // PR.merge (v1.9) is optional, so v2 blobs still decode; it fills in on sync.
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

    /// When the user asked Copilot to review each PR from Pulley. Lives here
    /// rather than in the detail pane so it survives switching PRs; used to
    /// tell "still reviewing" from "never going to answer" (GitHub accepts
    /// the request even when Copilot isn't available to the user).
    var copilotRequestedAt: [String: Date] = [:]
    private let draftOverrideTTL: TimeInterval = 30

    /// Same idea for auto-merge / merge-queue changes made from Pulley: the
    /// search index lags the mutation, so for the TTL window the result the
    /// mutation returned beats what the fetch says.
    enum MergeOverride {
        case queueEntry(MergeInfo.QueueEntry?)
        case autoMerge(MergeInfo.AutoMerge?)
    }
    private var mergeOverrides: [String: (change: MergeOverride, at: Date)] = [:]

    init() {
        isMockData = MockData.isEnabled
        scope = Config.scope
        if isMockData {
            prs = MockData.prs(for: scope)
            lastSync = Date().addingTimeInterval(-60)
            viewerName = "Mohit"
            notifications = MockData.inbox
            refreshScopeCounts()
            contributions = MockData.contributions
            lastError = MockData.initialError
        } else {
            loadCache()
            startTimer()
        }
    }

    /// Restore the last sync's PR list so the popover shows something
    /// immediately on launch — the next `sync()` overwrites it.
    private func loadCache() {
        if let data = UserDefaults.standard.data(forKey: contributionsCacheKey),
           let cached = try? JSONDecoder().decode(ContributionCalendar.self, from: data) {
            contributions = cached
        }
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
        if let data = UserDefaults.standard.data(forKey: nudgedKey),
           let cached = try? JSONDecoder().decode([String: Date].self, from: data) {
            let cutoff = Date().addingTimeInterval(-7 * 86_400)
            self.nudgedAt = cached.filter { $0.value > cutoff }
        }
    }

    private func saveCache() {
        guard !isMockData else { return }
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
        guard !isMockData else { return }
        timer?.invalidate()
        // Auto-sync on the interval set in Settings (30 min by default); manual
        // sync is always available. Settings calls this again on change.
        let interval = TimeInterval(max(5, Config.syncIntervalMinutes) * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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
        if isMockData {
            syncMockData()
            return
        }
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
        let scope  = self.scope

        Task {
            do {
                // Fetch PRs and the inbox in parallel — inbox is best-effort:
                // a 403 (PAT without the `notifications` scope) shouldn't
                // tank the whole sync.
                async let prsTask    = client.fetchPRs(scope: scope)
                async let inboxTask  = client.fetchNotifications()
                async let countsTask = client.fetchScopeCounts(
                    excludeDrafts: Config.hideDraftsInMenuBar, mutedRepos: Config.mutedRepos
                )
                let fetched = try await prsTask.filter { !Config.isMuted(org: $0.org, repo: $0.repo) }
                // The user switched tabs mid-fetch: this list is for the old
                // scope, so drop it and fetch the current one.
                guard scope == self.scope else {
                    self.syncing = false
                    self.sync()
                    return
                }
                let inbox   = ((try? await inboxTask).map(self.filterReadThreads) ?? self.notifications)
                    .filter { !Config.isMuted(org: $0.org, repo: $0.repo) }
                let merged  = self.applyLocalOverrides(to: fetched)
                if let counts = try? await countsTask { self.scopeCounts = counts }
                self.prs = merged
                self.prsByScope[scope] = merged
                self.notifications = inbox
                self.saveCache()
                self.lastSync = Date()
                self.syncing = false
                if self.viewerName == nil {
                    self.viewerName = try? await client.fetchViewerFirstName()
                }
                await self.refreshContributions(client: client)
                NotificationsManager.shared.requestAuthorizationIfNeeded()
                // Merge-flow changes the user just made themselves shouldn't
                // come back as "removed from queue" style notifications.
                NotificationsManager.shared.reconcile(
                    merged, scope: scope, localMergeChanges: Set(self.mergeOverrides.keys)
                )

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
                self.syncing = false
                guard scope == self.scope else {
                    self.sync()
                    return
                }
                self.lastError = error.localizedDescription
            }
        }
    }

    /// Best-effort: a failure leaves whatever is cached.
    private func refreshContributions(client: GitHubClient) async {
        if let last = contributionsFetchedAt, Date().timeIntervalSince(last) < 3600 { return }
        if let fresh = try? await client.fetchContributions() {
            contributions = fresh
            contributionsFetchedAt = Date()
            if let data = try? JSONEncoder().encode(fresh) {
                UserDefaults.standard.set(data, forKey: contributionsCacheKey)
            }
        }
    }

    /// Give preview interactions realistic loading feedback while keeping the
    /// session entirely local and deterministic.
    private func syncMockData() {
        syncing = true
        lastError = nil
        let scope = self.scope
        Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            self.syncing = false
            guard scope == self.scope else {
                self.sync()
                return
            }
            self.prs = MockData.prs(for: scope).filter { !Config.isMuted(org: $0.org, repo: $0.repo) }
            self.prsByScope[scope] = self.prs
            self.lastSync = Date()
            self.refreshScopeCounts()
        }
    }

    /// Recount every tab after a setting that changes what's listed (hidden
    /// drafts, muted repos). Mock mode counts the fixtures; otherwise it's
    /// one small GitHub request, best-effort.
    func refreshScopeCounts() {
        if isMockData {
            var counts: [Scope: Int] = [:]
            for scope in Scope.allCases {
                counts[scope] = MockData.prs(for: scope).filter {
                    !Config.isMuted(org: $0.org, repo: $0.repo)
                        && !(Config.hideDraftsInMenuBar && $0.isDraft)
                }.count
            }
            scopeCounts = counts
            return
        }
        guard Config.hasToken, let client = Config.makeClient() else { return }
        Task {
            if let counts = try? await client.fetchScopeCounts(
                excludeDrafts: Config.hideDraftsInMenuBar, mutedRepos: Config.mutedRepos
            ) {
                self.scopeCounts = counts
            }
        }
    }

    // MARK: Muted repos

    /// Hide a repo everywhere, right away. Its PRs and inbox threads drop out
    /// locally; the counts refetch.
    func mute(org: String, repo: String) {
        Config.mutedRepos.insert("\(org)/\(repo)".lowercased())
        dropMuted()
    }

    /// Unmuting needs a fetch to bring the repo's PRs back.
    func unmute(_ key: String) {
        Config.mutedRepos.remove(key.lowercased())
        sync()
        refreshScopeCounts()
    }

    private func dropMuted() {
        let keep: (PR) -> Bool = { !Config.isMuted(org: $0.org, repo: $0.repo) }
        prs = prs.filter(keep)
        prsByScope = prsByScope.mapValues { $0.filter(keep) }
        notifications = notifications.filter { !Config.isMuted(org: $0.org, repo: $0.repo) }
        saveCache()
        refreshScopeCounts()
    }

    // MARK: Popover actions

    /// Comment on the PR @mentioning reviewers who haven't responded. A
    /// re-request doesn't notify people who are still pending; a mention does.
    func nudge(_ pr: PR) async throws {
        let mentions = (pr.pendingReviewers ?? []).map(\.mention)
        guard !mentions.isEmpty else { return }
        if !isMockData {
            guard let client = Config.makeClient() else { throw GitHubError(message: "Token not set") }
            let body = "\(mentions.joined(separator: " ")) friendly nudge: could you take a look at this when you get a chance? Thanks!"
            try await client.postComment(org: pr.org, repo: pr.repo, number: pr.number, body: body)
        } else {
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        // Let the button show "Nudged" before the suggestion moves on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            self.nudgedAt[pr.id] = Date()
            if !self.isMockData, let data = try? JSONEncoder().encode(self.nudgedAt) {
                UserDefaults.standard.set(data, forKey: self.nudgedKey)
            }
        }
    }

    /// Approve without a comment, pinned to the head commit you saw. On the
    /// Review requests tab the PR leaves the list (it's no longer waiting
    /// on you); a sync reconciles the rest.
    func approve(_ pr: PR) async throws {
        if !isMockData {
            guard let client = Config.makeClient() else { throw GitHubError(message: "Token not set") }
            try await client.submitReview(
                org: pr.org, repo: pr.repo, number: pr.number,
                event: .approve, body: nil, commitID: pr.headSha
            )
        } else {
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        // Let the button show "Approved" before the PR leaves the list.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            if self.scope == .reviewRequested {
                self.prs.removeAll { $0.id == pr.id }
                self.scopeCounts[.reviewRequested] = max(0, (self.scopeCounts[.reviewRequested] ?? 1) - 1)
                self.saveCache()
            }
            if !self.isMockData { self.sync() }
        }
    }

    /// Show another set of PRs. The list for that scope from earlier in the
    /// session (if any) appears straight away; a sync replaces it. A sync
    /// already in flight for the old scope notices and re-runs for this one.
    func switchScope(_ newScope: Scope) {
        guard newScope != scope else { return }
        prsByScope[scope] = prs
        scope = newScope
        prs = (prsByScope[newScope] ?? []).filter { !Config.isMuted(org: $0.org, repo: $0.repo) }
        if !isMockData {
            Config.scope = newScope
            saveCache()
        }
        sync()
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
        guard !isMockData else { return }
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
    private func applyLocalOverrides(to fetched: [PR]) -> [PR] {
        let cutoff = Date().addingTimeInterval(-draftOverrideTTL)
        draftOverrides = draftOverrides.filter { $0.value.at > cutoff }
        mergeOverrides = mergeOverrides.filter { $0.value.at > cutoff }
        guard !draftOverrides.isEmpty || !mergeOverrides.isEmpty else { return fetched }
        return fetched.map { pr in
            var pr = pr
            if let override = draftOverrides[pr.id], override.isDraft != pr.isDraft {
                pr = pr.with(isDraft: override.isDraft)
            }
            if let override = mergeOverrides[pr.id] {
                pr.merge = Self.applying(override.change, to: pr.merge)
            }
            return pr
        }
    }

    private static func applying(_ change: MergeOverride, to info: MergeInfo?) -> MergeInfo? {
        guard var info else { return nil }
        switch change {
        case .queueEntry(let entry): info.queueEntry = entry
        case .autoMerge(let auto):   info.autoMerge = auto
        }
        return info
    }

    /// Apply an auto-merge / queue change locally right after its mutation
    /// returns, so the merge control flips immediately; the follow-up sync
    /// reconciles everything else.
    func setLocalMerge(prID: String, _ change: MergeOverride) {
        mergeOverrides[prID] = (change, Date())
        guard let idx = prs.firstIndex(where: { $0.id == prID }) else { return }
        prs[idx].merge = Self.applying(change, to: prs[idx].merge)
        saveCache()
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

    /// The PRs the menu-bar surfaces (popover, count, peek menu) show:
    /// everything, or everything but drafts when Settings hides them.
    var menuBarPRs: [PR] {
        Config.hideDraftsInMenuBar ? prs.filter { !$0.isDraft } : prs
    }

    /// Count of PRs that need attention (anything not yet approved).
    var openCount: Int {
        menuBarPRs.filter { $0.status != .approved }.count
    }

    /// True if anything in the current scope deserves a red badge — i.e. a
    /// reviewer asked for changes, or CI is failing.
    var needsAttention: Bool {
        menuBarPRs.contains { $0.status == .changes || $0.checkStatus == .failure }
    }
}
