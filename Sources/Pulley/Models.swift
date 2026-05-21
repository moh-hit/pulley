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
    /// nil if the IDE isn't installed; callers should fall back to text.
    var icon: NSImage? {
        installedURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
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
}
