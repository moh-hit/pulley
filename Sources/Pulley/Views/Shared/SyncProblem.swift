import SwiftUI

/// A sync failure in plain language, with the one thing the user can do
/// about it. The raw GitHub message stays available in the tooltip.
struct SyncProblem: Equatable {
    enum Fix { case settings, retry }

    let message: String
    let fix: Fix
    let raw: String

    /// Map the strings `GitHubClient` / `Store` throw (and URLSession's
    /// localized errors) onto something a person can act on.
    init(raw: String) {
        self.raw = raw
        let r = raw.lowercased()
        if r.contains("token or org not set") || r.contains("token not set") {
            message = "Add a GitHub token and organization to start syncing."
            fix = .settings
        } else if r.contains("401") || r.contains("bad credentials") || r.contains("unauthorized") {
            message = "GitHub didn't accept your token. It may have expired or been revoked."
            fix = .settings
        } else if r.contains("rate limit") {
            message = "GitHub's rate limit was hit. Pulley will catch up shortly."
            fix = .retry
        } else if r.contains("403") || r.contains("forbidden") {
            message = "Your token can't read these repositories. Check its permissions."
            fix = .settings
        } else if r.contains("404") || r.contains("not found") || r.contains("could not resolve") || r.contains("422") {
            message = "GitHub couldn't find one of your organizations. Check the names in Settings."
            fix = .settings
        } else if r.contains("offline") || r.contains("internet") || r.contains("network connection")
                    || r.contains("timed out") || r.contains("could not connect") || r.contains("hostname") {
            message = "You're offline, or GitHub isn't reachable."
            fix = .retry
        } else if r.contains("http 5") || r.contains("502") || r.contains("503") {
            message = "GitHub is having trouble right now."
            fix = .retry
        } else {
            message = "Couldn't refresh your pull requests."
            fix = .retry
        }
    }
}

/// One-line banner above the content when the last sync failed. Shared by
/// the main window and the popover so errors read the same everywhere.
struct SyncErrorBanner: View {
    let problem: SyncProblem
    let onRetry: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Icon("exclamationmark.triangle.fill", size: 11)
                .foregroundColor(.red)
            Text(problem.message)
                .accessibilityLabel("Sync failed. \(problem.message)")
                .font(Theme.ui(12))
                .foregroundColor(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if problem.fix == .settings {
                Button("Open Settings", action: onOpenSettings)
                    .buttonStyle(.borderless)
                    .font(Theme.ui(12, .medium))
            }
            Button("Retry", action: onRetry)
                .buttonStyle(.borderless)
                .font(Theme.ui(12, .medium))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.07))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
        .help(problem.raw)
        .accessibilityElement(children: .contain)
    }
}
