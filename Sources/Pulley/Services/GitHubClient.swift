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
    struct Repo: Decodable { let name: String }
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
}

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
        struct GHUserDTO: Decodable { let login: String; let avatarUrl: URL? }
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
                    inReplyToID: dto.inReplyToId
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
            createdAt updatedAt
            repository { name }
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
            nodeID: node.id
        )
    }
}
