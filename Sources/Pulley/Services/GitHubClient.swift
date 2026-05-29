import Foundation

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum PRBranchState: Sendable {
    case open, closed, notFound
}

private struct GHUser: Decodable {
    let login: String
}

private struct GHIssue: Decodable {
    let number: Int
    let title: String
    let htmlUrl: URL
    let draft: Bool?
    let repositoryUrl: URL
    let assignee: GHUser?
    let assignees: [GHUser]?
    let createdAt: Date
    let updatedAt: Date
}

private struct GHSearchResponse: Decodable {
    let items: [GHIssue]
}

private struct GHPullDetail: Decodable {
    struct Head: Decodable {
        let ref: String
        let sha: String
    }
    let head: Head?
    let draft: Bool?
    /// GitHub: clean | unstable | behind | dirty | blocked | has_hooks | draft | unknown
    let mergeableState: String?
    /// GraphQL node ID; needed by `setDraft(...)` mutations.
    let nodeId: String?
}

private struct GHCheckRun: Decodable {
    let id: Int
    let name: String
    let status: String          // queued | in_progress | completed
    let conclusion: String?     // success | failure | neutral | ...
    let htmlUrl: URL?
}

private struct GHCheckRunsResponse: Decodable {
    let checkRuns: [GHCheckRun]
}

/// Combine per-run statuses into one summary status for the PR.
/// Failure beats pending beats success — same priority GitHub's UI uses.
func rollupChecks(_ checks: [CheckRun]) -> CheckStatus {
    guard !checks.isEmpty else { return .none }
    var sawPending = false
    var sawSuccess = false
    var sawNeutral = false
    for c in checks {
        switch c.rolled {
        case .failure: return .failure
        case .pending: sawPending = true
        case .success: sawSuccess = true
        case .neutral: sawNeutral = true
        case .none:    break
        }
    }
    if sawPending { return .pending }
    if sawSuccess { return .success }
    if sawNeutral { return .neutral }
    return .none
}

private extension JSONDecoder {
    static let gh: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

struct GitHubClient: Sendable {
    let token: String
    let orgs: [String]

    private func request(_ path: String) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://api.github.com\(path)")!)
        req.setValue("Bearer \(token)",                    forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json",        forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28",                         forHTTPHeaderField: "X-GitHub-Api-Version")
        return req
    }

    private func fetch<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request(path))
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubError(message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            switch http.statusCode {
            case 401: throw GitHubError(message: "401 Unauthorized — token invalid or expired")
            case 403: throw GitHubError(message: "403 Forbidden — token may lack repo / read:org scope, or rate limit hit")
            case 404: throw GitHubError(message: "404 Not Found — check org name in Settings")
            case 422: throw GitHubError(message: "422 — invalid search query (bad org name?)")
            default:  throw GitHubError(message: "HTTP \(http.statusCode): \(body.prefix(140))")
            }
        }
        return try JSONDecoder.gh.decode(T.self, from: data)
    }

    func currentUserLogin() async throws -> String {
        let u: GHUser = try await fetch("/user", as: GHUser.self)
        return u.login
    }

    /// Look up the most recent PR for a branch — used by the worktree sweeper
    /// to decide whether a stranded `<repo>--<slug>` directory can be reaped.
    /// `.notFound` means the branch never had a PR (or it was deleted).
    func fetchPRBranchState(org: String, repo: String, branch: String) async -> PRBranchState {
        guard !branch.isEmpty else { return .notFound }
        struct GHPRSummary: Decodable { let state: String }
        let encodedBranch = branch.addingPercentEncoding(
            withAllowedCharacters: .urlQueryAllowed
        ) ?? branch
        let path = "/repos/\(org)/\(repo)/pulls?head=\(org):\(encodedBranch)&state=all&per_page=1"
        guard let arr: [GHPRSummary] = try? await fetch(path, as: [GHPRSummary].self) else {
            return .notFound
        }
        guard let first = arr.first else { return .notFound }
        return first.state == "open" ? .open : .closed
    }

    /// Fetch the user's unread notification threads (`/notifications`).
    /// Maps each subject's `api.github.com/repos/.../pulls/N` URL into the
    /// browser-clickable `github.com/.../pull/N` form. Best-effort: failure
    /// (e.g. PAT without `notifications` scope) should be handled by the
    /// caller as "skip the inbox," not "fail the sync."
    func fetchNotifications() async throws -> [InboxThread] {
        struct Subject: Decodable {
            let title: String
            let url: URL?
            let type: String
        }
        struct Repo: Decodable { let fullName: String }
        struct GHNotif: Decodable {
            let id: String
            let unread: Bool
            let reason: String
            let updatedAt: Date
            let subject: Subject
            let repository: Repo
        }
        let arr: [GHNotif] = try await fetch(
            "/notifications?all=false&per_page=50",
            as: [GHNotif].self
        )
        return arr.map { n in
            let parts = n.repository.fullName
                .split(separator: "/", maxSplits: 1)
                .map(String.init)
            let org  = parts.first ?? ""
            let repo = parts.count > 1 ? parts[1] : ""
            return InboxThread(
                id: n.id,
                title: n.subject.title,
                type: n.subject.type,
                reason: n.reason,
                org: org,
                repo: repo,
                updatedAt: n.updatedAt,
                unread: n.unread,
                url: Self.htmlURL(forSubjectAPI: n.subject.url, org: org, repo: repo)
            )
        }
    }

    /// PATCH /notifications/threads/{id} — marks a single thread as read.
    func markNotificationRead(threadID: String) async throws {
        var req = request("/notifications/threads/\(threadID)")
        req.httpMethod = "PATCH"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError(message: "Mark read failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(body.prefix(140))")
        }
    }

    /// Convert a subject's API URL into the equivalent github.com web URL.
    /// `/repos/owner/repo/pulls/N` → `/owner/repo/pull/N`; issues stay
    /// `/issues/N`; everything else falls back to the repo home page.
    private static func htmlURL(forSubjectAPI api: URL?, org: String, repo: String) -> URL? {
        guard let api else {
            return URL(string: "https://github.com/\(org)/\(repo)")
        }
        var s = api.absoluteString
        s = s.replacingOccurrences(
            of: "https://api.github.com/repos/",
            with: "https://github.com/"
        )
        // /pulls/N → /pull/N (web). /issues/N stays the same.
        s = s.replacingOccurrences(of: "/pulls/", with: "/pull/")
        return URL(string: s) ?? URL(string: "https://github.com/\(org)/\(repo)")
    }

    /// Fetch the markdown body for a single PR. Used by the main-window detail
    /// pane on demand — kept off the list fetch so the popover stays fast.
    func fetchPRBody(org: String, repo: String, number: Int) async throws -> String {
        struct Body: Decodable { let body: String? }
        let b: Body = try await fetch("/repos/\(org)/\(repo)/pulls/\(number)", as: Body.self)
        return b.body ?? ""
    }

    /// Fetch the changed-files list for a PR (`/pulls/{n}/files`). Loaded on
    /// demand by the detail pane, like `fetchPRBody`. The endpoint caps
    /// `per_page` at 100; large PRs paginate, but v1 takes a single page and
    /// reports `capped == true` when it's full so the UI can note the cutoff.
    func fetchPRFiles(org: String, repo: String, number: Int) async throws -> (files: [PRFile], capped: Bool) {
        let files: [PRFile] = try await fetch(
            "/repos/\(org)/\(repo)/pulls/\(number)/files?per_page=100",
            as: [PRFile].self
        )
        return (files, files.count >= 100)
    }

    /// POST a pull-request review. `event = .approve` accepts an empty body;
    /// `.requestChanges` / `.comment` require one (GitHub returns 422
    /// otherwise — we let that bubble up rather than client-side validating,
    /// since the UI prevents it).
    func submitReview(
        org: String, repo: String, number: Int,
        event: ReviewEvent, body: String?
    ) async throws {
        var req = request("/repos/\(org)/\(repo)/pulls/\(number)/reviews")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["event": event.rawValue]
        if let body, !body.isEmpty { payload["body"] = body }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError(message: "Review failed (\((resp as? HTTPURLResponse)?.statusCode ?? -1)): \(bodyStr.prefix(200))")
        }
    }

    /// Flip a PR between draft and ready-for-review. GitHub only exposes this
    /// via GraphQL — `convertPullRequestToDraft` and
    /// `markPullRequestReadyForReview` both take the PR's node ID.
    func setDraft(nodeID: String, draft: Bool) async throws {
        let mutation = draft
            ? "mutation($id: ID!) { convertPullRequestToDraft(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
            : "mutation($id: ID!) { markPullRequestReadyForReview(input: {pullRequestId: $id}) { pullRequest { isDraft } } }"
        try await graphql(query: mutation, variables: ["id": nodeID])
    }

    /// Minimal GraphQL POST. GitHub returns 200 even on field-level errors,
    /// so we parse the `errors` array and throw if present.
    private func graphql(query: String, variables: [String: Any]) async throws {
        var req = URLRequest(url: URL(string: "https://api.github.com/graphql")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)",             forHTTPHeaderField: "Authorization")
        req.setValue("application/json",            forHTTPHeaderField: "Content-Type")
        req.setValue("2022-11-28",                  forHTTPHeaderField: "X-GitHub-Api-Version")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "variables": variables
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let bodyStr = String(data: data, encoding: .utf8) ?? ""
            throw GitHubError(message: "GraphQL HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1): \(bodyStr.prefix(200))")
        }
        struct GHGraphResp: Decodable {
            struct Err: Decodable { let message: String }
            let errors: [Err]?
        }
        if let parsed = try? JSONDecoder().decode(GHGraphResp.self, from: data),
           let errs = parsed.errors, !errs.isEmpty {
            throw GitHubError(message: errs.map(\.message).joined(separator: "; "))
        }
    }

    func fetchPRs(scope: Scope) async throws -> [PR] {
        guard !token.isEmpty, !orgs.isEmpty else {
            throw GitHubError(message: "Token or org not configured")
        }

        let me = try await currentUserLogin()

        // Fan out across configured orgs. Each org runs the full per-bucket
        // search + per-PR detail flow independently; results merged at the end.
        let allPRs: [PR] = try await withThrowingTaskGroup(of: [PR].self) { group in
            for org in orgs {
                group.addTask { try await self.fetchPRs(scope: scope, me: me, org: org) }
            }
            var out: [PR] = []
            for try await chunk in group { out.append(contentsOf: chunk) }
            return out
        }

        return allPRs.sorted { $0.updatedAt > $1.updatedAt }
    }

    private func fetchPRs(scope: Scope, me: String, org: String) async throws -> [PR] {
        let base = "is:pr is:open org:\(org) \(scope.rawValue):\(me)"

        let buckets: [(String, PRStatus)] = [
            ("review:approved",          .approved),
            ("review:changes_requested", .changes),
            ("review:required",          .review),
            ("review:none",              .open),
        ]

        // 1) Parallel search across review-state buckets.
        let tagged: [(GHIssue, PRStatus)] = try await withThrowingTaskGroup(
            of: [(GHIssue, PRStatus)].self
        ) { group in
            for (filter, status) in buckets {
                group.addTask {
                    let q = "\(base) \(filter)"
                    let encoded = q.addingPercentEncoding(
                        withAllowedCharacters: .urlQueryAllowed
                    ) ?? ""
                    let resp: GHSearchResponse = try await fetch(
                        "/search/issues?q=\(encoded)&per_page=100&sort=updated",
                        as: GHSearchResponse.self
                    )
                    return resp.items.map { ($0, status) }
                }
            }
            var out: [(GHIssue, PRStatus)] = []
            for try await chunk in group { out.append(contentsOf: chunk) }
            return out
        }

        // Dedupe by URL (defensive — a PR shouldn't appear in two buckets).
        var seen = Set<URL>()
        let unique = tagged.filter { item in
            let url = item.0.htmlUrl
            if seen.contains(url) { return false }
            seen.insert(url)
            return true
        }

        // 2) Parallel per-PR detail fetch (branch + authoritative draft flag).
        let prs: [PR] = try await withThrowingTaskGroup(of: PR.self) { group in
            for (issue, bucketStatus) in unique {
                group.addTask {
                    let repo = issue.repositoryUrl.lastPathComponent
                    var branch  = ""
                    var headSha = ""
                    var isDraft = issue.draft ?? false
                    var mergeable: MergeableState = .unknown
                    var nodeID: String? = nil
                    if let detail: GHPullDetail = try? await fetch(
                        "/repos/\(org)/\(repo)/pulls/\(issue.number)",
                        as: GHPullDetail.self
                    ) {
                        branch  = detail.head?.ref ?? ""
                        headSha = detail.head?.sha ?? ""
                        isDraft = detail.draft ?? isDraft
                        if let raw = detail.mergeableState {
                            mergeable = MergeableState(rawValue: raw) ?? .unknown
                        }
                        nodeID = detail.nodeId
                    }

                    // CI checks for the head commit. Best-effort: no checks
                    // (or repo not exposing them) leaves checkStatus = .none.
                    var checks: [CheckRun] = []
                    if !headSha.isEmpty,
                       let resp: GHCheckRunsResponse = try? await fetch(
                            "/repos/\(org)/\(repo)/commits/\(headSha)/check-runs?per_page=100",
                            as: GHCheckRunsResponse.self
                       ) {
                        checks = resp.checkRuns.map { c in
                            CheckRun(
                                id: "\(c.id)",
                                name: c.name,
                                status: c.status,
                                conclusion: c.conclusion,
                                url: c.htmlUrl
                            )
                        }
                    }
                    let checkStatus = rollupChecks(checks)

                    let finalStatus: PRStatus = isDraft ? .open : bucketStatus
                    return PR(
                        id: "\(org)/\(repo)#\(issue.number)",
                        number: issue.number,
                        title: issue.title,
                        org: org,
                        repo: repo,
                        url: issue.htmlUrl,
                        branch: branch,
                        headSha: headSha,
                        assignee: issue.assignee?.login ?? issue.assignees?.first?.login,
                        status: finalStatus,
                        isDraft: isDraft,
                        updatedAt: issue.updatedAt,
                        createdAt: issue.createdAt,
                        checks: checks,
                        checkStatus: checkStatus,
                        mergeableState: mergeable,
                        nodeID: nodeID
                    )
                }
            }
            var out: [PR] = []
            for try await pr in group { out.append(pr) }
            return out
        }

        return prs.sorted { $0.updatedAt > $1.updatedAt }
    }
}
