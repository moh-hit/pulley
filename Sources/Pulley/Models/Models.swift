import Foundation
import AppKit

enum PRStatus: String, Codable, CaseIterable, Hashable {
    case open, review, changes, approved

    var label: String {
        switch self {
        case .open:     return "Open"
        case .review:   return "In review"
        case .changes:  return "Changes req."
        case .approved: return "Approved"
        }
    }
}

enum GroupBy: String, Codable, CaseIterable, Identifiable, Hashable {
    case status, repo, org

    var id: String { rawValue }
}

enum IDE: String, Codable, CaseIterable, Identifiable, Hashable {
    case vscode
    case cursor
    case zed

    var id: String { rawValue }

    /// macOS .app bundle name, suitable for `open -a "<name>"`.
    var appName: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed:    return "Zed"
        }
    }

    var displayName: String {
        switch self {
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .zed:    return "Zed"
        }
    }

    /// Bundle identifiers tried in order when locating the installed app.
    /// Cursor in particular has shipped under multiple IDs over its lifetime,
    /// hence the list.
    var bundleIdentifiers: [String] {
        switch self {
        case .vscode: return ["com.microsoft.VSCode"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.anysphere.cursor"]
        case .zed:    return ["dev.zed.Zed", "dev.zed.Zed-Preview"]
        }
    }

    /// Locates the installed app — first by bundle id (location-independent),
    /// then by the common /Applications and ~/Applications paths.
    var installedURL: URL? {
        for id in bundleIdentifiers {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return url
            }
        }
        let paths = [
            "/Applications/\(appName).app",
            ("~/Applications/\(appName).app" as NSString).expandingTildeInPath,
        ]
        for p in paths where FileManager.default.fileExists(atPath: p) {
            return URL(fileURLWithPath: p)
        }
        return nil
    }

    /// Real macOS app icon, sourced from the installed `.app` bundle. Returns
    /// nil if the IDE isn't installed; callers should fall back to `fallbackSymbol`.
    var icon: NSImage? {
        installedURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// SF Symbol shown when the IDE isn't installed, so each tile keeps a
    /// recognizable identity instead of all collapsing to one generic glyph.
    var fallbackSymbol: String {
        switch self {
        case .vscode: return "chevron.left.forwardslash.chevron.right"
        case .cursor: return "cursorarrow.rays"
        case .zed:    return "bolt.fill"
        }
    }
}

enum Scope: String, Codable, CaseIterable, Identifiable, Hashable {
    case author
    case involves
    case reviewRequested = "review-requested"
    case assignee

    var id: String { rawValue }

    var label: String {
        switch self {
        case .author:          return "Authored by me"
        case .involves:        return "Involves me"
        case .reviewRequested: return "Review requested"
        case .assignee:        return "Assigned to me"
        }
    }
}

/// Raw GitHub `mergeable_state` values, plus `.unknown` for missing.
/// Reference: https://docs.github.com/en/graphql/reference/enums#mergestatestatus
enum MergeableState: String, Codable, Hashable {
    case clean              // mergeable, CI ok, no blockers
    case unstable           // mergeable, but CI failing/pending
    case behind             // base branch moved ahead
    case dirty              // merge conflicts
    case blocked            // required reviews / branch protection
    case hasHooks = "has_hooks"
    case draft
    case unknown

    var label: String {
        switch self {
        case .clean:    return "ready"
        case .unstable: return "checks failing"
        case .behind:   return "behind base"
        case .dirty:    return "conflicts"
        case .blocked:  return "blocked"
        case .hasHooks: return "hooks"
        case .draft:    return "draft"
        case .unknown:  return "unknown"
        }
    }

    /// True when the badge should be surfaced in the row.
    /// `clean` / `unknown` / `draft` / `hasHooks` stay hidden — only flag
    /// states the author can act on.
    var isActionable: Bool {
        switch self {
        case .dirty, .behind, .blocked, .unstable: return true
        default: return false
        }
    }
}

enum CheckStatus: String, Codable, Hashable {
    case none, pending, success, failure, neutral

    var label: String {
        switch self {
        case .none:    return "no checks"
        case .pending: return "running"
        case .success: return "passing"
        case .failure: return "failing"
        case .neutral: return "neutral"
        }
    }
}

struct CheckRun: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    /// raw GitHub `status` (queued | in_progress | completed)
    let status: String
    /// raw GitHub `conclusion` for completed runs (success | failure | …)
    let conclusion: String?
    let url: URL?

    /// Roll one check's raw fields into our coarser CheckStatus.
    var rolled: CheckStatus {
        if status != "completed" { return .pending }
        switch conclusion {
        case "success":                              return .success
        case "failure", "timed_out", "action_required",
             "cancelled", "stale", "startup_failure": return .failure
        case "neutral", "skipped":                   return .neutral
        default:                                     return .neutral
        }
    }

    /// Compact label aligned with GitHub's wording: the conclusion for
    /// completed runs, otherwise the (de-underscored) raw status.
    var stateLabel: String {
        if status != "completed" {
            return status.replacingOccurrences(of: "_", with: " ")
        }
        return conclusion ?? "completed"
    }
}

/// A single GitHub notification thread (`/notifications`). Wraps the fields
/// we actually render — the API also returns a `last_read_at` and a few
/// other bookkeeping bits that we don't need.
struct InboxThread: Identifiable, Hashable, Codable {
    let id: String              // thread id, used for mark-as-read
    let title: String
    /// Subject type, e.g. "PullRequest" / "Issue" / "Discussion" / "Release".
    let type: String
    /// Why GitHub flagged this thread for you, e.g. "mention" /
    /// "review_requested" / "author" / "comment" / "team_mention".
    let reason: String
    let org: String
    let repo: String
    let updatedAt: Date
    /// `unread=false` rows arrive when the user opted to keep read items in
    /// the list; today we only fetch unread, but we keep the field so future
    /// "show read" toggles don't need a model change.
    let unread: Bool
    /// HTML URL — derived from the API subject URL by the client. May be nil
    /// when the subject has no URL (rare).
    let url: URL?

    /// Human-friendly reason label for the row chip.
    var reasonLabel: String {
        switch reason {
        case "mention":         return "mention"
        case "team_mention":    return "team mention"
        case "review_requested": return "review requested"
        case "author":          return "author"
        case "assign":          return "assigned"
        case "comment":         return "comment"
        case "state_change":    return "state change"
        case "subscribed":      return "subscribed"
        case "ci_activity":     return "CI"
        case "security_alert":  return "security"
        default:                return reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

struct PR: Identifiable, Hashable, Codable {
    let id: String          // "org/repo#number"
    let number: Int
    let title: String
    let org: String
    let repo: String
    let url: URL
    let branch: String
    let headSha: String
    let assignee: String?
    let status: PRStatus
    let isDraft: Bool
    let updatedAt: Date
    let createdAt: Date
    let checks: [CheckRun]
    let checkStatus: CheckStatus
    let mergeableState: MergeableState
    /// GraphQL node ID (`PR_kwDO…`). Needed for the GraphQL mutations that
    /// flip draft / ready-for-review. Optional so cached blobs from before
    /// this field existed decode cleanly with `nil`; next sync fills it in.
    let nodeID: String?

    /// Copy with a flipped draft flag. PR's fields are immutable, so the
    /// optimistic draft toggles in `Store` would otherwise re-list every
    /// field by hand — this keeps that in one place that the compiler checks
    /// whenever a field is added.
    func with(isDraft: Bool) -> PR {
        PR(
            id: id,
            number: number,
            title: title,
            org: org,
            repo: repo,
            url: url,
            branch: branch,
            headSha: headSha,
            assignee: assignee,
            status: status,
            isDraft: isDraft,
            updatedAt: updatedAt,
            createdAt: createdAt,
            checks: checks,
            checkStatus: checkStatus,
            mergeableState: mergeableState,
            nodeID: nodeID
        )
    }
}

/// Review event passed to `POST /repos/.../pulls/N/reviews`. Raw values are
/// the literal strings GitHub expects.
enum ReviewEvent: String, Sendable {
    case approve         = "APPROVE"
    case requestChanges  = "REQUEST_CHANGES"
    case comment         = "COMMENT"
}

/// Side of the pull-request diff a review comment attaches to. GitHub expects
/// these exact uppercase raw values in the review `comments` payload.
enum ReviewCommentSide: String, Codable, Hashable, Sendable {
    case left  = "LEFT"
    case right = "RIGHT"

    var label: String {
        switch self {
        case .left:  return "old"
        case .right: return "new"
        }
    }
}

/// Local, unsent inline review comment draft. Drafts are kept in memory by the
/// detail pane and converted to `ReviewInlineComment` when the review submits.
struct ReviewDraftComment: Identifiable, Hashable {
    let id: String
    let path: String
    let side: ReviewCommentSide
    let startLine: Int?
    let startSide: ReviewCommentSide?
    let line: Int
    var body: String

    init(
        path: String,
        side: ReviewCommentSide,
        line: Int,
        startLine: Int? = nil,
        startSide: ReviewCommentSide? = nil,
        body: String = ""
    ) {
        self.path = path
        self.side = side
        self.line = line
        self.startLine = startLine == line ? nil : startLine
        self.startSide = startLine == line ? nil : startSide
        self.body = body
        self.id = Self.id(path: path, side: side, line: line, startLine: startLine, startSide: startSide)
    }

    static func id(
        path: String,
        side: ReviewCommentSide,
        line: Int,
        startLine: Int? = nil,
        startSide: ReviewCommentSide? = nil
    ) -> String {
        let start = startLine.map { "\(startSide?.rawValue ?? side.rawValue)#\($0)" } ?? "single"
        return "\(path)#\(start)#\(side.rawValue)#\(line)"
    }

    var locationLabel: String {
        if let startLine, startLine != line {
            return "\(path):\(startLine)-\(line)"
        }
        return "\(path):\(line)"
    }

    func contains(path candidatePath: String, side candidateSide: ReviewCommentSide, line candidateLine: Int) -> Bool {
        guard path == candidatePath, side == candidateSide else { return false }
        let lower = min(startLine ?? line, line)
        let upper = max(startLine ?? line, line)
        return (lower...upper).contains(candidateLine)
    }
}

/// API-ready inline review comment. Separated from `ReviewDraftComment` so the
/// client can receive only trimmed, non-empty bodies.
struct ReviewInlineComment: Hashable, Sendable {
    let path: String
    let side: ReviewCommentSide
    let startLine: Int?
    let startSide: ReviewCommentSide?
    let line: Int
    let body: String
}

/// An inline review comment already posted to the PR, fetched from
/// `GET /pulls/{n}/comments` and rendered read-only under its diff line so a
/// reviewer sees existing discussion alongside their own drafts. `line` is the
/// (end) line the comment anchors to on its `side`; nil when GitHub no longer
/// maps it into the current diff (outdated), in which case it's skipped.
struct PRReviewComment: Identifiable, Hashable, Sendable {
    let id: Int
    let authorLogin: String
    let authorAvatarURL: URL?
    let body: String
    let path: String
    let side: ReviewCommentSide
    let line: Int?
    let startLine: Int?
    let createdAt: Date
    /// Set when this comment is a reply to another (threaded under its parent).
    let inReplyToID: Int?
}

// MARK: - Changed files / diffs

/// One entry from `GET /repos/{org}/{repo}/pulls/{number}/files`. Decoded via
/// `JSONDecoder.gh` (convertFromSnakeCase), so JSON `blob_url` /
/// `previous_filename` map to these camelCase properties automatically — do
/// NOT add CodingKeys, that would fight the strategy. `patch`, `blobUrl`, and
/// `previousFilename` are optional because GitHub omits them per row (no patch
/// for binary / too-large files; previousFilename only on renames).
struct PRFile: Codable, Hashable, Identifiable {
    let sha: String
    let filename: String
    /// added | modified | removed | renamed | copied | changed | unchanged
    let status: String
    let additions: Int
    let deletions: Int
    let changes: Int
    let blobUrl: URL?
    let patch: String?
    let previousFilename: String?

    /// Keyed on path, which is unique within a PR. Blob `sha` can repeat across
    /// renamed/copied pairs, so it's unsuitable for `ForEach` identity.
    var id: String { filename }

    var statusGlyph: String {
        switch status {
        case "added":   return "plus.square.fill"
        case "removed": return "minus.square.fill"
        case "renamed": return "arrow.right.square.fill"
        default:        return "pencil"     // modified / copied / changed
        }
    }
}

/// A single rendered line of a unified diff, with reconstructed old/new line
/// numbers for the gutter. One side is `nil` for added/removed lines.
struct DiffLine: Identifiable, Hashable {
    enum Kind { case context, addition, deletion }
    let id: Int
    let kind: Kind
    let oldLine: Int?
    let newLine: Int?
    /// Content with the leading +/-/space marker stripped.
    let text: String
}

/// A contiguous `@@ … @@` block of a unified diff.
struct DiffHunk: Identifiable, Hashable {
    let id: Int
    let header: String      // raw "@@ -a,b +c,d @@ section" line
    let lines: [DiffLine]
}

/// Parse a unified-diff `patch` (as returned by the PR files endpoint) into
/// hunks with reconstructed line numbers. The files endpoint strips the
/// `diff --git` / `---` / `+++` file headers, so the patch starts directly at
/// a `@@` hunk header. Counters advance per the line's own side: additions
/// move the new counter, deletions the old, context both.
func parsePatch(_ patch: String) -> [DiffHunk] {
    var hunks: [DiffHunk] = []
    var hunkID = 0
    var lineID = 0
    var header: String? = nil
    var lines: [DiffLine] = []
    var oldNo = 0, newNo = 0

    func flush() {
        if let h = header {
            hunks.append(DiffHunk(id: hunkID, header: h, lines: lines))
            hunkID += 1
        }
        header = nil
        lines = []
    }

    for raw in patch.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
        if raw.hasPrefix("@@") {
            flush()
            if let (os, ns) = parseHunkRanges(raw) { oldNo = os; newNo = ns }
            header = raw
            continue
        }
        guard header != nil else { continue }   // ignore anything before first @@
        let marker = raw.first
        let text = raw.isEmpty ? "" : String(raw.dropFirst())
        switch marker {
        case "+":
            lines.append(DiffLine(id: lineID, kind: .addition, oldLine: nil, newLine: newNo, text: text))
            newNo += 1
        case "-":
            lines.append(DiffLine(id: lineID, kind: .deletion, oldLine: oldNo, newLine: nil, text: text))
            oldNo += 1
        case "\\":
            continue                              // "\ No newline at end of file"
        default:                                  // " " context, or empty line
            lines.append(DiffLine(id: lineID, kind: .context, oldLine: oldNo, newLine: newNo, text: text))
            oldNo += 1; newNo += 1
        }
        lineID += 1
    }
    flush()
    return hunks
}

/// Extract `oldStart` / `newStart` from a `@@ -a,b +c,d @@ …` header. Counts
/// are optional in the format (`@@ -1 +1 @@`), so we take the part before any
/// comma.
private func parseHunkRanges(_ header: String) -> (Int, Int)? {
    let parts = header.split(separator: "@", omittingEmptySubsequences: true)
    guard let ranges = parts.first?.trimmingCharacters(in: .whitespaces) else { return nil }
    let tokens = ranges.split(separator: " ")
    guard tokens.count >= 2 else { return nil }
    func start(_ tok: Substring) -> Int? {
        let body = tok.dropFirst()              // drop leading - / +
        let num = body.split(separator: ",").first.map(String.init) ?? String(body)
        return Int(num)
    }
    guard let o = start(tokens[0]), let n = start(tokens[1]) else { return nil }
    return (o, n)
}
