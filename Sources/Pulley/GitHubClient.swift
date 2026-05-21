import Foundation

struct GitHubError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
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

    /// Fetch the markdown body for a single PR. Used by the main-window detail
    /// pane on demand — kept off the list fetch so the popover stays fast.
    func fetchPRBody(org: String, repo: String, number: Int) async throws -> String {
        struct Body: Decodable { let body: String? }
        let b: Body = try await fetch("/repos/\(org)/\(repo)/pulls/\(number)", as: Body.self)
        return b.body ?? ""
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
                        mergeableState: mergeable
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
