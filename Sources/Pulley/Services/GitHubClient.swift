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

/// One `... on PullRequest` node from the GraphQL search query. Search nodes
/// that aren't PRs decode as empty objects, so every field is optional and
/// the mapper drops nodes without a `number`.
private struct GQLPRNode: Decodable {
    struct Repo: Decodable {
        let name: String
        let squashMergeAllowed: Bool?
        let mergeCommitAllowed: Bool?
        let rebaseMergeAllowed: Bool?
        let autoMergeAllowed: Bool?
        let viewerDefaultMergeMethod: String?
    }
    struct Actor: Decodable { let login: String }
    struct Assignees: Decodable { let nodes: [Actor] }
    /// Union of `CheckRun` and `StatusContext` from `statusCheckRollup`.
    struct ContextNode: Decodable {
        let typename: String
        // CheckRun fields
        let databaseId: Int?
        let name: String?
        let status: String?         // QUEUED | IN_PROGRESS | COMPLETED | …
        let conclusion: String?     // SUCCESS | FAILURE | NEUTRAL | …
        let detailsUrl: URL?
        // StatusContext fields (legacy commit statuses)
        let context: String?
        let state: String?          // ERROR | EXPECTED | FAILURE | PENDING | SUCCESS
        let targetUrl: URL?

        enum CodingKeys: String, CodingKey {
            case typename = "__typename"
            case databaseId, name, status, conclusion, detailsUrl
            case context, state, targetUrl
        }
    }
    struct Contexts: Decodable { let nodes: [ContextNode] }
    struct Rollup: Decodable { let contexts: Contexts }
    struct Commit: Decodable { let statusCheckRollup: Rollup? }
    struct CommitNode: Decodable { let commit: Commit }
    struct Commits: Decodable { let nodes: [CommitNode] }

    let id: String?
    let number: Int?
    let title: String?
    let url: URL?
    let isDraft: Bool?
    let headRefName: String?
    let headRefOid: String?
    /// BEHIND | BLOCKED | CLEAN | DIRTY | DRAFT | HAS_HOOKS | UNKNOWN | UNSTABLE
    let mergeStateStatus: String?
    let createdAt: Date?
    let updatedAt: Date?
    let repository: Repo?
    let assignees: Assignees?
    let commits: Commits?
    let reviewDecision: String?
    let isMergeQueueEnabled: Bool?
    let viewerCanEnableAutoMerge: Bool?
    let viewerCanDisableAutoMerge: Bool?
    let mergeQueueEntry: GQLQueueEntry?
    let autoMergeRequest: GQLAutoMerge?
    struct Stack: Decodable { let number: Int; let size: Int }
    struct StackPosition: Decodable { let position: Int }
    let stack: Stack?
    let stackEntry: StackPosition?
}

/// `MergeQueueEntry` subset — shared by the search query and the enqueue
/// mutation's payload.
private struct GQLQueueEntry: Decodable {
    let position: Int?
    let state: String?
    let estimatedTimeToMerge: Int?

    var model: MergeInfo.QueueEntry {
        MergeInfo.QueueEntry(
            position: position ?? 0,
            state: state ?? "QUEUED",
            estimatedSecondsToMerge: estimatedTimeToMerge
        )
    }
}

/// `AutoMergeRequest` subset — shared by the search query and the
/// enable-auto-merge mutation's payload.
private struct GQLAutoMerge: Decodable {
    struct Actor: Decodable { let login: String }
    let mergeMethod: String?
    let enabledBy: Actor?

    var model: MergeInfo.AutoMerge {
        MergeInfo.AutoMerge(method: MergeMethod(graphQL: mergeMethod), enabledBy: enabledBy?.login)
    }
}

/// Selection sets reused by the search query and the merge mutations, so
/// the decoded shapes can't drift apart.
private let gqlQueueEntryFields = "position state estimatedTimeToMerge"
private let gqlAutoMergeFields  = "mergeMethod enabledBy { login }"

private struct GQLSearch: Decodable {
    struct Result: Decodable { let nodes: [GQLPRNode] }
    let search: Result
}

private struct GQLEnvelope<D: Decodable>: Decodable { let data: D? }

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

    /// GraphQL responses are camelCase already — no key conversion, just dates.
    static let ghGraph: JSONDecoder = {
        let d = JSONDecoder()
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

    /// Who the token belongs to and, for classic tokens, its scopes (from the
    /// `X-OAuth-Scopes` header). Fine-grained tokens send no scope header, so
    /// `scopes` is nil for them. Used by Settings → Test connection.
    func tokenInfo() async throws -> (login: String, scopes: [String]?) {
        let (data, resp) = try await URLSession.shared.data(for: request("/user"))
        guard let http = resp as? HTTPURLResponse else { throw GitHubError(message: "No HTTP response") }
        guard (200..<300).contains(http.statusCode) else {
            throw GitHubError(message: http.statusCode == 401
                ? "401 Unauthorized — token invalid or expired"
                : "HTTP \(http.statusCode)")
        }
        let user = try JSONDecoder.gh.decode(GHUser.self, from: data)
        let header = http.value(forHTTPHeaderField: "X-OAuth-Scopes")
        let scopes = header.map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return (user.login, scopes)
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

    /// Fetch the inline review comments already posted on a PR
    /// (`GET /pulls/{n}/comments`). Paginated at 100/page; bounded to
    /// `maxPages` so a pathological thread can't stall the diff view. Best-effort
    /// from the caller's side — the diff still renders if this throws.
    func fetchPRReviewComments(org: String, repo: String, number: Int) async throws -> [PRReviewComment] {
        struct GHUserDTO: Decodable { let login: String; let avatarUrl: URL?; let type: String? }
        struct GHReviewCommentDTO: Decodable {
            let id: Int
            let user: GHUserDTO?
            let body: String
            let path: String
            let side: String?
            let line: Int?
            let originalLine: Int?
            let startLine: Int?
            let createdAt: Date
            let inReplyToId: Int?
        }
        let maxPages = 10
        var out: [PRReviewComment] = []
        var page = 1
        while page <= maxPages {
            let batch: [GHReviewCommentDTO] = try await fetch(
                "/repos/\(org)/\(repo)/pulls/\(number)/comments?per_page=100&page=\(page)",
                as: [GHReviewCommentDTO].self
            )
            out.append(contentsOf: batch.map { dto in
                PRReviewComment(
                    id: dto.id,
                    authorLogin: dto.user?.login ?? "ghost",
                    authorAvatarURL: dto.user?.avatarUrl,
                    body: dto.body,
                    path: dto.path,
                    side: dto.side.flatMap { ReviewCommentSide(rawValue: $0) } ?? .right,
                    line: dto.line ?? dto.originalLine,
                    startLine: dto.startLine,
                    createdAt: dto.createdAt,
                    inReplyToID: dto.inReplyToId,
                    isBot: dto.user?.type == "Bot"
                )
            })
            if batch.count < 100 { break }
            page += 1
        }
        return out
    }

    /// POST a pull-request review. `event = .approve` accepts an empty body;
    /// `.requestChanges` / `.comment` require one (GitHub returns 422
    /// otherwise — we let that bubble up rather than client-side validating,
    /// since the UI prevents it).
    func submitReview(
        org: String, repo: String, number: Int,
        event: ReviewEvent, body: String?,
        commitID: String? = nil,
        comments: [ReviewInlineComment] = []
    ) async throws {
        var req = request("/repos/\(org)/\(repo)/pulls/\(number)/reviews")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["event": event.rawValue]
        if let body, !body.isEmpty { payload["body"] = body }
        if let commitID, !commitID.isEmpty { payload["commit_id"] = commitID }
        if !comments.isEmpty {
            payload["comments"] = comments.map { comment in
                var item: [String: Any] = [
                    "path": comment.path,
                    "side": comment.side.rawValue,
                    "line": comment.line,
                    "body": comment.body,
                ]
                if let startLine = comment.startLine {
                    item["start_line"] = startLine
                    item["start_side"] = (comment.startSide ?? comment.side).rawValue
                }
                return item
            }
        }
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

    /// Copilot's code-review bot. Requests take the `[bot]`-suffixed login;
    /// review authors and requested reviewers report it without the suffix.
    static let copilotReviewerLogin = "copilot-pull-request-reviewer"

    /// Whether Copilot is reviewing now, and which commit it last reviewed.
    func fetchCopilotReview(org: String, repo: String, number: Int) async throws -> CopilotReviewState {
        struct Payload: Decodable {
            struct Bot: Decodable { let login: String? }
            struct Request: Decodable { let requestedReviewer: Bot? }
            struct Requests: Decodable { let nodes: [Request] }
            struct Commit: Decodable { let oid: String }
            struct Review: Decodable { let submittedAt: Date?; let commit: Commit? }
            struct Reviews: Decodable { let nodes: [Review] }
            struct PR: Decodable { let reviewRequests: Requests; let reviews: Reviews }
            struct Repo: Decodable { let pullRequest: PR? }
            let repository: Repo?
        }
        let query = """
        query($o: String!, $r: String!, $n: Int!) {
          repository(owner: $o, name: $r) {
            pullRequest(number: $n) {
              reviewRequests(first: 50) {
                nodes { requestedReviewer { ... on Bot { login } } }
              }
              reviews(last: 1, author: "\(Self.copilotReviewerLogin)[bot]") {
                nodes { submittedAt commit { oid } }
              }
            }
          }
        }
        """
        let resp: Payload = try await graphqlFetch(
            query: query, variables: ["o": org, "r": repo, "n": number]
        )
        guard let pr = resp.repository?.pullRequest else {
            throw GitHubError(message: "PR not found")
        }
        let last = pr.reviews.nodes.last
        return CopilotReviewState(
            requested: pr.reviewRequests.nodes.contains {
                $0.requestedReviewer?.login?.hasPrefix(Self.copilotReviewerLogin) == true
            },
            lastReviewAt: last?.submittedAt,
            lastReviewedCommit: last?.commit?.oid
        )
    }

    /// Ask Copilot to review (or re-review after new pushes). `union` keeps
    /// the existing requested reviewers — the default would replace them.
    /// Note GitHub accepts this even when the viewer can't use Copilot code
    /// review; the review then simply never arrives.
    func requestCopilotReview(nodeID: String) async throws {
        try await graphql(
            query: """
            mutation($id: ID!, $bots: [String!]) {
              requestReviewsByLogin(input: {pullRequestId: $id, botLogins: $bots, union: true}) { clientMutationId }
            }
            """,
            variables: ["id": nodeID, "bots": ["\(Self.copilotReviewerLogin)[bot]"]]
        )
    }

    /// The signed-in user's first name for the Home greeting, falling back
    /// to their login when the profile has no name.
    func fetchViewerFirstName() async throws -> String {
        struct Payload: Decodable {
            struct Viewer: Decodable { let login: String; let name: String? }
            let viewer: Viewer
        }
        let resp: Payload = try await graphqlFetch(query: "query { viewer { login name } }", variables: [:])
        let first = resp.viewer.name?.split(separator: " ").first.map(String.init)
        return first ?? resp.viewer.login
    }

    /// The signed-in user's contribution calendar for the last year.
    func fetchContributions() async throws -> ContributionCalendar {
        struct Payload: Decodable {
            struct Day: Decodable { let date: String; let contributionCount: Int; let weekday: Int }
            struct Week: Decodable { let contributionDays: [Day] }
            struct Calendar: Decodable { let totalContributions: Int; let weeks: [Week] }
            struct Collection: Decodable { let contributionCalendar: Calendar }
            struct Viewer: Decodable { let contributionsCollection: Collection }
            let viewer: Viewer
        }
        let query = """
        query { viewer { contributionsCollection { contributionCalendar {
          totalContributions
          weeks { contributionDays { date contributionCount weekday } }
        } } } }
        """
        let resp: Payload = try await graphqlFetch(query: query, variables: [:])
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let cal = resp.viewer.contributionsCollection.contributionCalendar
        return ContributionCalendar(
            weeks: cal.weeks.map { week in
                week.contributionDays.compactMap { d in
                    formatter.date(from: d.date).map {
                        ContributionCalendar.Day(date: $0, count: d.contributionCount, weekday: d.weekday)
                    }
                }
            },
            total: cal.totalContributions
        )
    }

    /// Every PR in the stack this PR belongs to, bottom first.
    func fetchStackEntries(org: String, repo: String, number: Int) async throws -> [StackEntry] {
        struct Payload: Decodable {
            struct EntryPR: Decodable {
                let number: Int; let title: String; let state: String
                let isDraft: Bool; let url: URL
            }
            struct Entry: Decodable { let position: Int; let pullRequest: EntryPR? }
            struct Entries: Decodable { let nodes: [Entry] }
            struct Stack: Decodable { let entries: Entries }
            struct PR: Decodable { let stack: Stack? }
            struct Repo: Decodable { let pullRequest: PR? }
            let repository: Repo?
        }
        let query = """
        query($o: String!, $r: String!, $n: Int!) {
          repository(owner: $o, name: $r) {
            pullRequest(number: $n) {
              stack {
                entries(first: 50) {
                  nodes { position pullRequest { number title state isDraft url } }
                }
              }
            }
          }
        }
        """
        let resp: Payload = try await graphqlFetch(
            query: query, variables: ["o": org, "r": repo, "n": number]
        )
        let nodes = resp.repository?.pullRequest?.stack?.entries.nodes ?? []
        return nodes.compactMap { e in
            e.pullRequest.map {
                StackEntry(position: e.position, number: $0.number, title: $0.title,
                           state: $0.state, isDraft: $0.isDraft, url: $0.url)
            }
        }
        .sorted { $0.position < $1.position }
    }

    /// Submit an async merge (`PUT …/merge-async`). Unlike the classic merge
    /// endpoint this handles stacks — every open PR below this one merges
    /// (or queues) with it, atomically. `action` is `default` (queue if the
    /// branch has one, else direct), `direct_merge`, or `merge_queue`.
    /// `method` only applies to direct merges.
    func mergeAsync(
        org: String, repo: String, number: Int,
        method: MergeMethod?, action: String, sha: String
    ) async throws -> AsyncMergeResult {
        var req = request("/repos/\(org)/\(repo)/pulls/\(number)/merge-async")
        req.httpMethod = "PUT"
        req.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["merge_action": action]
        if let method { payload["merge_method"] = method.rawValue }
        if !sha.isEmpty { payload["sha"] = sha }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try Self.decodeAsyncMerge(data: data, resp: resp, submitting: true)
    }

    /// Poll an async merge started with `mergeAsync`.
    func mergeAsyncStatus(org: String, repo: String, number: Int, uuid: String) async throws -> AsyncMergeResult {
        var req = request("/repos/\(org)/\(repo)/pulls/\(number)/merge-async/\(uuid)")
        req.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, resp) = try await URLSession.shared.data(for: req)
        return try Self.decodeAsyncMerge(data: data, resp: resp, submitting: false)
    }

    /// `{status, details{message, uuid, sha, …}}`. On submit, 409 means a
    /// merge for this PR is already pending — its body carries that
    /// request's uuid, so we just follow it.
    private static func decodeAsyncMerge(data: Data, resp: URLResponse, submitting: Bool) throws -> AsyncMergeResult {
        struct Details: Decodable { let message: String?; let uuid: String? }
        struct Body: Decodable { let status: String?; let details: Details?; let message: String? }
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubError(message: "No HTTP response")
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        let message = body?.details?.message ?? body?.message
        let ok = (200..<300).contains(http.statusCode) || (submitting && http.statusCode == 409)
        guard ok else {
            throw GitHubError(message: message ?? "Merge failed (HTTP \(http.statusCode))")
        }
        switch body?.status {
        case "merged":   return .merged
        case "enqueued": return .enqueued
        case "failed":   return .failed(message ?? "GitHub couldn't merge this PR")
        default:
            guard let uuid = body?.details?.uuid else {
                throw GitHubError(message: message ?? "Merge request accepted, but GitHub returned no status")
            }
            return .pending(uuid: uuid)
        }
    }

    /// Turn on auto-merge: GitHub merges (or, on a merge-queue branch, queues)
    /// the PR once its requirements pass. `method` is omitted for queue
    /// branches, where the queue's own setting decides. `expectedHeadOid`
    /// pins it to the commit we showed, like the direct merge's `sha`.
    func enableAutoMerge(
        nodeID: String, method: MergeMethod?, expectedHeadOid: String
    ) async throws -> MergeInfo.AutoMerge? {
        struct Payload: Decodable {
            struct PR: Decodable { let autoMergeRequest: GQLAutoMerge? }
            struct Result: Decodable { let pullRequest: PR? }
            let enablePullRequestAutoMerge: Result
        }
        var input = "pullRequestId: $id"
        var variables: [String: Any] = ["id": nodeID]
        if !expectedHeadOid.isEmpty {
            input += ", expectedHeadOid: $oid"
            variables["oid"] = expectedHeadOid
        }
        if let method {
            input += ", mergeMethod: \(method.graphQLValue)"
        }
        let args = expectedHeadOid.isEmpty ? "$id: ID!" : "$id: ID!, $oid: GitObjectID!"
        let query = """
        mutation(\(args)) {
          enablePullRequestAutoMerge(input: {\(input)}) {
            pullRequest { autoMergeRequest { \(gqlAutoMergeFields) } }
          }
        }
        """
        let resp: Payload = try await graphqlFetch(query: query, variables: variables)
        return resp.enablePullRequestAutoMerge.pullRequest?.autoMergeRequest?.model
    }

    func disableAutoMerge(nodeID: String) async throws {
        try await graphql(
            query: "mutation($id: ID!) { disablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }",
            variables: ["id": nodeID]
        )
    }

    /// Add a ready PR to its base branch's merge queue. Returns the new entry
    /// so the UI can show the position without waiting for a sync.
    func enqueue(nodeID: String, expectedHeadOid: String) async throws -> MergeInfo.QueueEntry? {
        struct Payload: Decodable {
            struct Result: Decodable { let mergeQueueEntry: GQLQueueEntry? }
            let enqueuePullRequest: Result
        }
        var variables: [String: Any] = ["id": nodeID]
        let query: String
        if expectedHeadOid.isEmpty {
            query = """
            mutation($id: ID!) {
              enqueuePullRequest(input: {pullRequestId: $id}) { mergeQueueEntry { \(gqlQueueEntryFields) } }
            }
            """
        } else {
            variables["oid"] = expectedHeadOid
            query = """
            mutation($id: ID!, $oid: GitObjectID!) {
              enqueuePullRequest(input: {pullRequestId: $id, expectedHeadOid: $oid}) { mergeQueueEntry { \(gqlQueueEntryFields) } }
            }
            """
        }
        let resp: Payload = try await graphqlFetch(query: query, variables: variables)
        return resp.enqueuePullRequest.mergeQueueEntry?.model
    }

    /// Remove a PR from the merge queue. The input's `id` is the PR's node ID.
    func dequeue(nodeID: String) async throws {
        try await graphql(
            query: "mutation($id: ID!) { dequeuePullRequest(input: {id: $id}) { clientMutationId } }",
            variables: ["id": nodeID]
        )
    }

    /// Merge a PR via `PUT /repos/{owner}/{repo}/pulls/{n}/merge`. `sha` pins
    /// the merge to the head commit we last saw, so a push that lands between
    /// fetch and merge is rejected (409) instead of silently merging newer
    /// code. GitHub returns 405 when the PR isn't mergeable and 409 on the SHA
    /// mismatch — both surfaced with a readable message.
    func mergePullRequest(
        org: String, repo: String, number: Int,
        method: MergeMethod, sha: String?
    ) async throws {
        var req = request("/repos/\(org)/\(repo)/pulls/\(number)/merge")
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var payload: [String: Any] = ["merge_method": method.rawValue]
        if let sha, !sha.isEmpty { payload["sha"] = sha }
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw GitHubError(message: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            // GitHub's body carries a useful `message` (e.g. "Pull Request is
            // not mergeable") — prefer it over the bare status code.
            struct Msg: Decodable { let message: String? }
            let detail = (try? JSONDecoder().decode(Msg.self, from: data))?.message
            switch http.statusCode {
            case 405: throw GitHubError(message: detail ?? "405 — PR is not mergeable")
            case 409: throw GitHubError(message: detail ?? "409 — head moved since last sync; refresh and retry")
            default:  throw GitHubError(message: detail ?? "Merge failed (HTTP \(http.statusCode))")
            }
        }
    }

    /// Output + annotations for one check run, fetched on demand when a
    /// failed check is expanded in the detail pane. Annotations are
    /// best-effort — the summary still shows if that call fails.
    func fetchCheckRunDetails(org: String, repo: String, runID: Int) async throws -> CheckRunDetails {
        struct Output: Decodable { let title: String?; let summary: String? }
        struct Run: Decodable { let output: Output? }
        struct GHAnnotation: Decodable {
            let path: String?
            let startLine: Int?
            let endLine: Int?
            let annotationLevel: String?
            let message: String?
            let title: String?
        }
        async let runTask: Run = fetch("/repos/\(org)/\(repo)/check-runs/\(runID)", as: Run.self)
        async let annTask: [GHAnnotation] = fetch(
            "/repos/\(org)/\(repo)/check-runs/\(runID)/annotations?per_page=50",
            as: [GHAnnotation].self
        )
        let run = try await runTask
        let annotations = (try? await annTask) ?? []
        return CheckRunDetails(
            outputTitle: run.output?.title,
            summary: run.output?.summary,
            annotations: annotations.enumerated().compactMap { idx, a in
                guard let message = a.message, !message.isEmpty else { return nil }
                return CheckAnnotation(
                    id: idx,
                    path: a.path ?? "",
                    startLine: a.startLine,
                    endLine: a.endLine,
                    level: a.annotationLevel ?? "failure",
                    message: message,
                    title: a.title
                )
            }
        )
    }

    /// Re-run everything that failed on the PR head. Checks backed by a
    /// GitHub Actions run are re-run per workflow run via `rerun-failed-jobs`
    /// (same as the web UI's "Re-run failed jobs"); anything else falls back
    /// to the generic check-run `rerequest`. Individual failures are
    /// tolerated — throws only when nothing could be re-run.
    func rerunFailedChecks(org: String, repo: String, checks: [CheckRun]) async throws {
        let failed = checks.filter { $0.rolled == .failure }
        guard !failed.isEmpty else { return }

        var actionsRunIDs: [Int] = []      // ordered, distinct
        var others: [CheckRun] = []
        for check in failed {
            if let runID = Self.actionsRunID(from: check.url) {
                if !actionsRunIDs.contains(runID) { actionsRunIDs.append(runID) }
            } else {
                others.append(check)
            }
        }

        var rerun = 0
        var firstError: Error? = nil
        for runID in actionsRunIDs {
            do {
                try await post("/repos/\(org)/\(repo)/actions/runs/\(runID)/rerun-failed-jobs")
                rerun += 1
            } catch { firstError = firstError ?? error }
        }
        for check in others {
            guard let id = check.runID else { continue }
            do {
                try await post("/repos/\(org)/\(repo)/check-runs/\(id)/rerequest")
                rerun += 1
            } catch { firstError = firstError ?? error }
        }
        if rerun == 0 {
            throw firstError ?? GitHubError(message: "No re-runnable checks found")
        }
    }

    /// Workflow-run id from an Actions check URL, e.g.
    /// `https://github.com/org/repo/actions/runs/123/job/456` → 123.
    private static func actionsRunID(from url: URL?) -> Int? {
        guard let url, url.host == "github.com" else { return nil }
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "actions"),
              i + 2 < parts.count, parts[i + 1] == "runs" else { return nil }
        return Int(parts[i + 2])
    }

    /// Empty-body POST used by the re-run endpoints. Surfaces GitHub's
    /// `message` (e.g. "This workflow is already running") over the bare code.
    private func post(_ path: String) async throws {
        var req = request(path)
        req.httpMethod = "POST"
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            struct Msg: Decodable { let message: String? }
            let detail = (try? JSONDecoder().decode(Msg.self, from: data))?.message
            throw GitHubError(message: detail ?? "HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }

    /// Minimal GraphQL POST for mutations where only success matters.
    private func graphql(query: String, variables: [String: Any]) async throws {
        _ = try await graphqlData(query: query, variables: variables)
    }

    /// GraphQL POST returning the decoded `data` payload. Used by the PR
    /// search, which moved off REST so fine-grained tokens work.
    private func graphqlFetch<T: Decodable>(query: String, variables: [String: Any]) async throws -> T {
        let data = try await graphqlData(query: query, variables: variables)
        guard let payload = try JSONDecoder.ghGraph.decode(GQLEnvelope<T>.self, from: data).data else {
            throw GitHubError(message: "GraphQL response missing data")
        }
        return payload
    }

    /// Shared GraphQL transport. GitHub returns 200 even on field-level
    /// errors, so we parse the `errors` array and throw if present.
    private func graphqlData(query: String, variables: [String: Any]) async throws -> Data {
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
        return data
    }

    func fetchPRs(scope: Scope) async throws -> [PR] {
        guard !token.isEmpty, !orgs.isEmpty else {
            throw GitHubError(message: "Token or org not configured")
        }

        // Fan out across configured orgs. Each org runs the per-bucket
        // search independently; results merged at the end.
        let allPRs: [PR] = try await withThrowingTaskGroup(of: [PR].self) { group in
            for org in orgs {
                group.addTask { try await self.fetchPRs(scope: scope, org: org) }
            }
            var out: [PR] = []
            for try await chunk in group { out.append(contentsOf: chunk) }
            return out
        }

        return allPRs.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// GraphQL search query: one call returns everything the old REST flow
    /// needed three calls per PR for (head ref/SHA, draft flag, merge state,
    /// node ID, CI contexts). `statusCheckRollup.contexts` covers both
    /// check runs and legacy commit statuses.
    private static let prSearchQuery = """
    query($q: String!) {
      search(query: $q, type: ISSUE, first: 100) {
        nodes {
          ... on PullRequest {
            id number title url isDraft headRefName headRefOid mergeStateStatus
            createdAt updatedAt reviewDecision
            isMergeQueueEnabled viewerCanEnableAutoMerge viewerCanDisableAutoMerge
            mergeQueueEntry { \(gqlQueueEntryFields) }
            autoMergeRequest { \(gqlAutoMergeFields) }
            stack { number size }
            stackEntry { position }
            repository {
              name squashMergeAllowed mergeCommitAllowed rebaseMergeAllowed
              autoMergeAllowed viewerDefaultMergeMethod
            }
            assignees(first: 1) { nodes { login } }
            commits(last: 1) {
              nodes {
                commit {
                  statusCheckRollup {
                    contexts(first: 100) {
                      nodes {
                        __typename
                        ... on CheckRun { databaseId name status conclusion detailsUrl }
                        ... on StatusContext { context state targetUrl }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }
    }
    """

    private func fetchPRs(scope: Scope, org: String) async throws -> [PR] {
        // `@me` resolves server-side, so no /user round-trip is needed.
        // `sort:updated-desc` keeps the >100-results truncation cutting the
        // stalest PRs, matching the old REST `sort=updated` behavior.
        let base = "is:pr is:open org:\(org) \(scope.rawValue):@me sort:updated-desc"

        let buckets: [(String, PRStatus)] = [
            ("review:approved",          .approved),
            ("review:changes_requested", .changes),
            ("review:required",          .review),
            ("review:none",              .open),
        ]

        // Parallel search across review-state buckets.
        let tagged: [(GQLPRNode, PRStatus)] = try await withThrowingTaskGroup(
            of: [(GQLPRNode, PRStatus)].self
        ) { group in
            for (filter, status) in buckets {
                group.addTask {
                    let resp: GQLSearch = try await graphqlFetch(
                        query: Self.prSearchQuery,
                        variables: ["q": "\(base) \(filter)"]
                    )
                    return resp.search.nodes.map { ($0, status) }
                }
            }
            var out: [(GQLPRNode, PRStatus)] = []
            for try await chunk in group { out.append(contentsOf: chunk) }
            return out
        }

        // Dedupe by URL (defensive — a PR shouldn't appear in two buckets).
        var seen = Set<URL>()
        let unique = tagged.filter { item in
            guard let url = item.0.url else { return false }
            if seen.contains(url) { return false }
            seen.insert(url)
            return true
        }

        return unique
            .compactMap { Self.mapPR($0.0, org: org, bucketStatus: $0.1) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Map one search node onto the app's PR model. Returns nil for nodes
    /// that aren't PRs (search unions decode them as empty objects).
    private static func mapPR(_ node: GQLPRNode, org: String, bucketStatus: PRStatus) -> PR? {
        guard
            let number = node.number,
            let title = node.title,
            let url = node.url,
            let repo = node.repository?.name,
            let createdAt = node.createdAt,
            let updatedAt = node.updatedAt
        else { return nil }

        let isDraft = node.isDraft ?? false
        let mergeable = node.mergeStateStatus
            .flatMap { MergeableState(rawValue: $0.lowercased()) } ?? .unknown

        let contexts = node.commits?.nodes.first?.commit.statusCheckRollup?.contexts.nodes ?? []
        let checks: [CheckRun] = contexts.compactMap { ctx -> CheckRun? in
            switch ctx.typename {
            case "CheckRun":
                guard let name = ctx.name else { return nil }
                // GraphQL enums arrive uppercase; lowercased they match the
                // REST strings the model has always stored.
                return CheckRun(
                    id: ctx.databaseId.map(String.init) ?? "check:\(name)",
                    name: name,
                    status: ctx.status?.lowercased() ?? "queued",
                    conclusion: ctx.conclusion?.lowercased(),
                    url: ctx.detailsUrl,
                    runID: ctx.databaseId
                )
            case "StatusContext":
                // Legacy commit statuses have no queued/completed lifecycle —
                // fold their single state onto the check-run fields.
                guard let name = ctx.context else { return nil }
                let state = ctx.state?.lowercased() ?? "pending"
                let completed = ["success", "failure", "error"].contains(state)
                return CheckRun(
                    id: "status:\(name)",
                    name: name,
                    status: completed ? "completed" : "in_progress",
                    conclusion: completed ? (state == "success" ? "success" : "failure") : nil,
                    url: ctx.targetUrl,
                    runID: nil
                )
            default:
                return nil
            }
        }

        return PR(
            id: "\(org)/\(repo)#\(number)",
            number: number,
            title: title,
            org: org,
            repo: repo,
            url: url,
            branch: node.headRefName ?? "",
            headSha: node.headRefOid ?? "",
            assignee: node.assignees?.nodes.first?.login,
            status: isDraft ? .open : bucketStatus,
            isDraft: isDraft,
            updatedAt: updatedAt,
            createdAt: createdAt,
            checks: checks,
            checkStatus: rollupChecks(checks),
            mergeableState: mergeable,
            nodeID: node.id,
            merge: mergeInfo(for: node),
            stack: node.stack.flatMap { s in
                node.stackEntry.map { StackInfo(number: s.number, size: s.size, position: $0.position) }
            }
        )
    }

    private static func mergeInfo(for node: GQLPRNode) -> MergeInfo {
        let r = node.repository
        // GitHub's own button order. A repo field missing from the response
        // (nil) counts as allowed so we never hide every option.
        var allowed: [MergeMethod] = []
        if r?.mergeCommitAllowed ?? true { allowed.append(.merge) }
        if r?.squashMergeAllowed ?? true { allowed.append(.squash) }
        if r?.rebaseMergeAllowed ?? true { allowed.append(.rebase) }
        return MergeInfo(
            allowedMethods: allowed,
            defaultMethod: MergeMethod(graphQL: r?.viewerDefaultMergeMethod),
            autoMergeAllowed: r?.autoMergeAllowed ?? false,
            canEnableAutoMerge: node.viewerCanEnableAutoMerge ?? false,
            canDisableAutoMerge: node.viewerCanDisableAutoMerge ?? false,
            mergeQueueEnabled: node.isMergeQueueEnabled ?? false,
            queueEntry: node.mergeQueueEntry?.model,
            autoMerge: node.autoMergeRequest?.model,
            reviewDecision: node.reviewDecision
        )
    }
}
