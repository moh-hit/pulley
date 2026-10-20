import Foundation

/// Deterministic fixtures for exercising the menu-bar UI without reading the
/// Keychain, touching the cache, or calling GitHub. Compiled out of release
/// builds; enable in a debug build with `PULLEY_MOCK_DATA=1`.
enum MockData {
    #if DEBUG
    static let isEnabled = ProcessInfo.processInfo.environment["PULLEY_MOCK_DATA"] == "1"

    private struct Spec {
        let number: Int
        let title: String
        let org: String
        let repo: String
        let branch: String
        let status: PRStatus
        let ageMinutes: Int
        let checkStatus: CheckStatus
        let mergeableState: MergeableState
        let isDraft: Bool
        let checkCount: Int

        init(
            _ number: Int,
            _ title: String,
            org: String = "acme",
            repo: String,
            branch: String,
            status: PRStatus,
            ageMinutes: Int,
            checks: CheckStatus = .success,
            mergeable: MergeableState = .clean,
            draft: Bool = false,
            checkCount: Int = 3
        ) {
            self.number = number
            self.title = title
            self.org = org
            self.repo = repo
            self.branch = branch
            self.status = status
            self.ageMinutes = ageMinutes
            self.checkStatus = checks
            self.mergeableState = mergeable
            self.isDraft = draft
            self.checkCount = checkCount
        }
    }

    private static let specs: [Spec] = [
        Spec(482, "Fix race in webhook retry queue", repo: "api", branch: "fix/webhook-retry-race", status: .changes, ageMinutes: 13, checks: .failure, mergeable: .dirty, checkCount: 4),
        Spec(1288, "Prevent duplicate invoice reconciliation", repo: "payments", branch: "fix/idempotent-reconcile", status: .changes, ageMinutes: 31, checks: .pending, mergeable: .behind),
        Spec(913, "Address review feedback in session handoff", repo: "web", branch: "fix/session-handoff", status: .changes, ageMinutes: 64, checks: .success, mergeable: .blocked),
        Spec(77, "Correct Terraform role permissions", org: "northstar", repo: "infra", branch: "fix/ci-role-policy", status: .changes, ageMinutes: 150, checks: .failure, mergeable: .unstable, checkCount: 5),

        Spec(1207, "Ship new pricing page hero", repo: "web", branch: "feat/pricing-hero", status: .approved, ageMinutes: 46),
        Spec(334, "Add offline banner to mobile checkout", repo: "mobile", branch: "feat/offline-checkout-banner", status: .approved, ageMinutes: 82, checkCount: 4),
        Spec(64, "Rotate staging deployment credentials", org: "northstar", repo: "infra", branch: "chore/rotate-staging-credentials", status: .approved, ageMinutes: 205),
        Spec(556, "Use semantic tokens in account settings", repo: "design-system", branch: "refactor/account-tokens", status: .approved, ageMinutes: 390, checks: .neutral, checkCount: 2),

        Spec(1211, "Refactor checkout reducer to remove duplicated state transitions", repo: "web", branch: "refactor/checkout-reducer", status: .review, ageMinutes: 60, checks: .failure, mergeable: .unstable, checkCount: 6),
        Spec(501, "Add rate-limit telemetry for GitHub sync", repo: "api", branch: "feat/rate-limit-telemetry", status: .review, ageMinutes: 105, checks: .pending),
        Spec(342, "Support passkeys during sign in", repo: "mobile", branch: "feat/passkey-signin", status: .review, ageMinutes: 240, checks: .success, checkCount: 5),
        Spec(91, "Migrate edge cache rules", org: "northstar", repo: "web", branch: "chore/edge-cache-rules", status: .review, ageMinutes: 460, checks: .pending, mergeable: .behind),
        Spec(571, "Document focus states for compound controls", repo: "design-system", branch: "docs/compound-focus", status: .review, ageMinutes: 780, checks: .none, checkCount: 0),

        Spec(73, "Bump terraform-aws-eks to 20.x", repo: "infra", branch: "chore/eks-20", status: .open, ageMinutes: 180, checks: .success, mergeable: .behind),
        Spec(318, "iOS 18 splash screen artwork", repo: "mobile", branch: "feat/ios18-splash", status: .open, ageMinutes: 260, checks: .none, draft: true, checkCount: 0),
        Spec(1294, "Prototype regional tax calculation", repo: "payments", branch: "spike/regional-tax", status: .open, ageMinutes: 610, checks: .pending, draft: true),
        Spec(112, "Add repository health summary", org: "northstar", repo: "web", branch: "feat/repository-health", status: .open, ageMinutes: 1040, checks: .success),
        Spec(590, "Remove deprecated spacing aliases", repo: "design-system", branch: "chore/remove-spacing-aliases", status: .open, ageMinutes: 1560, checks: .neutral, checkCount: 2),
    ]

    static var prs: [PR] {
        let now = Date()
        return specs.map { spec in
            let url = URL(string: "https://example.com/\(spec.org)/\(spec.repo)/pull/\(spec.number)")!
            return PR(
                id: "mock:\(spec.org)/\(spec.repo)#\(spec.number)",
                number: spec.number,
                title: spec.title,
                org: spec.org,
                repo: spec.repo,
                url: url,
                branch: spec.branch,
                headSha: String(format: "%040x", spec.number),
                assignee: spec.status == .review ? "mohit" : nil,
                status: spec.status,
                isDraft: spec.isDraft,
                updatedAt: now.addingTimeInterval(TimeInterval(-60 * spec.ageMinutes)),
                createdAt: now.addingTimeInterval(TimeInterval(-60 * spec.ageMinutes - 172_800)),
                checks: checks(for: spec, url: url),
                checkStatus: spec.checkStatus,
                mergeableState: spec.mergeableState,
                nodeID: nil
            )
        }
    }

    private static func checks(for spec: Spec, url: URL) -> [CheckRun] {
        guard spec.checkCount > 0, spec.checkStatus != .none else { return [] }
        let names = ["Unit tests", "Typecheck", "Lint", "Build", "Integration tests", "Preview deployment"]
        return (0..<spec.checkCount).map { index in
            let isLeadCheck = index == 0
            let status = spec.checkStatus == .pending && isLeadCheck ? "in_progress" : "completed"
            let conclusion: String?
            if status != "completed" {
                conclusion = nil
            } else if spec.checkStatus == .failure && isLeadCheck {
                conclusion = "failure"
            } else if spec.checkStatus == .neutral {
                conclusion = "neutral"
            } else {
                conclusion = "success"
            }
            return CheckRun(
                id: "mock-check:\(spec.number):\(index)",
                name: names[index % names.count],
                status: status,
                conclusion: conclusion,
                url: url,
                runID: nil
            )
        }
    }
    #else
    static let isEnabled = false
    static var prs: [PR] { [] }
    #endif
}
