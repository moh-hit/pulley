import SwiftUI

// MARK: - Ranking

/// One suggestion for the popover's "Up next" footer: a PR and why it's the
/// thing to do now.
struct UpNextPick: Identifiable, Equatable {
    /// A one-click follow-through offered on the card.
    enum Action: Equatable { case none, nudge, approve }

    let pr: PR
    let reason: String
    let icon: String
    let tint: Color
    var action: Action = .none
    /// Lower is more pressing.
    fileprivate let tier: Int
    /// Older first within a tier: it has waited longest.
    fileprivate let since: Date

    var id: String { pr.id }
}

enum UpNext {
    /// What to work on next in a scope, most pressing first. Your own PRs
    /// rank by how close you are to unblocking them (feedback to address,
    /// then merges, conflicts, red CI); review requests rank by how long
    /// they've waited, healthy ones before ones the author still has to fix.
    /// Drafts, queued and auto-merging PRs never come up: there's nothing
    /// to do on them yet. On Assigned and Involved only PRs you opened are
    /// suggested.
    static func rank(_ prs: [PR], scope: Scope, nudgedAt: [String: Date] = [:]) -> [UpNextPick] {
        let candidates = prs.filter {
            !$0.isDraft && $0.merge?.queueEntry == nil && $0.merge?.autoMerge == nil
        }
        let picks: [UpNextPick]
        switch scope {
        case .author:
            picks = candidates.compactMap { authorPick($0, nudgedAt: nudgedAt[$0.id]) }
        case .reviewRequested:
            picks = candidates.compactMap(reviewPick)
        case .assignee, .involves:
            // Only your own PRs: a teammate's PR here may not need you at
            // all, and the ones that do are on the Review requests tab.
            // Unknown authorship (an older cache) counts as yours until the
            // next sync fills it in.
            picks = candidates.filter { !$0.isTeammates }.compactMap { authorPick($0, nudgedAt: nudgedAt[$0.id]) }
        }
        return picks.sorted { a, b in
            a.tier != b.tier ? a.tier < b.tier : a.since < b.since
        }
    }

    private static func authorPick(_ pr: PR, nudgedAt: Date?) -> UpNextPick? {
        let unresolved = pr.unresolvedThreads ?? 0
        let threads = "\(unresolved) unresolved thread\(unresolved == 1 ? "" : "s")"
        if pr.status == .changes {
            let detail = unresolved > 0 ? threads : "address the feedback"
            return UpNextPick(pr: pr, reason: "Changes requested — \(detail)",
                              icon: "exclamationmark.bubble", tint: .red, tier: 0, since: pr.updatedAt)
        }
        if pr.status == .approved, pr.mergeAction == .merge {
            return UpNextPick(pr: pr, reason: "Approved and green — ready to merge",
                              icon: "arrow.triangle.merge", tint: mergePurple, tier: 1, since: pr.updatedAt)
        }
        if pr.status == .approved, pr.mergeAction == .enqueue {
            return UpNextPick(pr: pr, reason: "Approved — ready for the merge queue",
                              icon: "arrow.triangle.merge", tint: mergePurple, tier: 1, since: pr.updatedAt)
        }
        if unresolved > 0 {
            return UpNextPick(pr: pr, reason: "\(threads) — reply or resolve",
                              icon: "bubble.left", tint: .orange, tier: 2, since: pr.updatedAt)
        }
        if pr.mergeableState == .dirty {
            return UpNextPick(pr: pr, reason: "Merge conflicts — update the branch",
                              icon: "exclamationmark.triangle", tint: .red, tier: 3, since: pr.updatedAt)
        }
        if pr.checkStatus == .failure {
            let failed = pr.checks.filter { $0.rolled == .failure }.count
            let detail = pr.checks.isEmpty ? "" : " — \(failed) of \(pr.checks.count) checks"
            return UpNextPick(pr: pr, reason: "CI failing\(detail)",
                              icon: "xmark.octagon", tint: .red, tier: 4, since: pr.updatedAt)
        }
        if pr.status == .approved, pr.mergeableState == .behind {
            return UpNextPick(pr: pr, reason: "Approved but behind base — update the branch",
                              icon: "arrow.down.circle", tint: .orange, tier: 5, since: pr.updatedAt)
        }
        // Reviews outstanding for a day or more, and you haven't nudged
        // anyone in the last day.
        let day: TimeInterval = 86_400
        if pr.status == .review || pr.status == .open,
           let pending = pr.pendingReviewers, !pending.isEmpty,
           let oldest = pending.compactMap(\.requestedAt).min(),
           Date().timeIntervalSince(oldest) >= day,
           nudgedAt.map({ Date().timeIntervalSince($0) >= day }) ?? true {
            return UpNextPick(pr: pr, reason: "Waiting on \(reviewerList(pending)) for \(relativeTime(oldest))",
                              icon: "hourglass", tint: .orange, action: .nudge, tier: 6, since: oldest)
        }
        return nil
    }

    /// "@sam", "@sam and @priya", "@sam and 2 others"
    static func reviewerList(_ reviewers: [PendingReviewer]) -> String {
        switch reviewers.count {
        case 0:  return "reviewers"
        case 1:  return reviewers[0].mention
        case 2:  return "\(reviewers[0].mention) and \(reviewers[1].mention)"
        default: return "\(reviewers[0].mention) and \(reviewers.count - 1) others"
        }
    }

    /// Everything on the Review requests tab is waiting on you; age is how
    /// long since the PR was opened (GitHub's search doesn't say when the
    /// review was requested).
    private static func reviewPick(_ pr: PR) -> UpNextPick? {
        let opened = "opened \(relativeTime(pr.createdAt)) ago"
        let waiting = "Waiting on your review · \(opened)"
        // The author has work to do first, so these sink below the rest.
        if pr.status == .changes {
            return UpNextPick(pr: pr, reason: "\(waiting) · changes requested",
                              icon: "eye", tint: .secondary, tier: 13, since: pr.createdAt)
        }
        if pr.checkStatus == .failure || pr.mergeableState == .dirty {
            let issue = pr.mergeableState == .dirty ? "conflicts" : "CI failing"
            return UpNextPick(pr: pr, reason: "\(waiting) · \(issue)",
                              icon: "eye", tint: .secondary, tier: 13, since: pr.createdAt)
        }
        if pr.checkStatus == .pending {
            return UpNextPick(pr: pr, reason: "\(waiting) · CI running",
                              icon: "eye", tint: .orange, tier: 12, since: pr.createdAt)
        }
        // Tiny and green: a few minutes' work, so it goes first and can be
        // approved straight from the card.
        if let size = pr.size, size.isTiny {
            return UpNextPick(pr: pr, reason: "Quick review · \(size.label) · \(opened)",
                              icon: "bolt", tint: .green, action: .approve, tier: 10, since: pr.createdAt)
        }
        return UpNextPick(pr: pr, reason: waiting, icon: "eye", tint: .orange, tier: 11, since: pr.createdAt)
    }
}

// MARK: - Footer

/// Pinned under the popover list: the single most useful thing to do next,
/// with a way to step through the rest. Clicking anywhere on it opens the
/// PR on GitHub.
struct UpNextFooter: View {
    @EnvironmentObject var store: Store
    let picks: [UpNextPick]
    /// Position in `picks`; the popover resets it when the list changes.
    @Binding var index: Int

    @State private var hovered = false

    private var current: UpNextPick? {
        picks.isEmpty ? nil : picks[min(index, picks.count - 1)]
    }

    var body: some View {
        Group {
            if let pick = current {
                HStack(spacing: 8) {
                    // The whole card except the next button opens the PR.
                    Button { PRActions.openInBrowser(pick.pr.url) } label: {
                        pickLabel(pick)
                            .padding(.leading, 14)
                            .padding(.trailing, picks.count > 1 ? 0 : 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open on GitHub")
                    .accessibilityLabel("Up next: \(pick.pr.title). \(pick.reason)")
                    .accessibilityHint("Opens the pull request on GitHub")
                    actionButton(pick)
                    if picks.count > 1 {
                        nextButton.padding(.trailing, 9)
                    } else if pick.action != .none {
                        Color.clear.frame(width: 1)
                    }
                }
                .background(card(tint: pick.tint))
            } else {
                HStack(spacing: 6) {
                    Text("Up next").eyebrow()
                    Icon("checkmark", size: 9)
                        .foregroundColor(.green)
                    Text("Nothing needs you right now.")
                        .font(Theme.ui(12))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.trailing, 12)
                .padding(.vertical, 9)
                .background(card(tint: .green))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovered = $0 }
    }

    /// A raised, faintly tinted card with an accent strip in the pick's
    /// color, so the suggestion doesn't read as another list row.
    private func card(tint: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let base: Color = tint == .secondary ? .primary : tint
        return shape
            .fill(base.opacity(hovered && current != nil ? 0.12 : 0.07))
            .overlay(alignment: .leading) {
                Rectangle().fill(base.opacity(0.85)).frame(width: 3)
            }
            .clipShape(shape)
            .overlay(shape.stroke(base.opacity(0.22), lineWidth: 0.5))
            .animation(.easeOut(duration: 0.1), value: hovered)
    }

    private func pickLabel(_ pick: UpNextPick) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text("Up next").eyebrow()
                Icon(pick.icon, size: 9)
                    .foregroundColor(pick.tint)
                Text(pick.reason)
                    .font(Theme.ui(11, .medium))
                    .foregroundColor(pick.tint == .secondary ? .secondary : pick.tint)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            HStack(spacing: 8) {
                Text(pick.pr.title)
                    .font(Theme.ui(13, .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                // Shows on hover so the footer reads as a link.
                Icon("arrow.up.right.square", size: 10)
                    .foregroundColor(.secondary)
                    .opacity(hovered ? 1 : 0)
                Spacer(minLength: 0)
                // Just the number when an action button needs the room.
                Text(pick.action == .none ? "\(pick.pr.repo) #\(String(pick.pr.number))" : "#\(String(pick.pr.number))")
                    .font(Theme.mono(11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func actionButton(_ pick: UpNextPick) -> some View {
        switch pick.action {
        case .none:
            EmptyView()
        case .nudge:
            ConfirmActionButton(
                title: "Nudge", confirmTitle: "Send nudge?", doneTitle: "Nudged", icon: "bell",
                help: "Comment on the PR mentioning \(UpNext.reviewerList(pick.pr.pendingReviewers ?? []))",
                tint: pick.tint, compact: true
            ) { try await store.nudge(pick.pr) }
            .id(pick.id)
        case .approve:
            ConfirmActionButton(
                title: "Approve", confirmTitle: "Approve?", doneTitle: "Approved", icon: "checkmark",
                help: "Approve \(pick.pr.repo) #\(pick.pr.number) without a comment",
                tint: pick.tint, compact: true
            ) { try await store.approve(pick.pr) }
            .id(pick.id)
        }
    }

    private var nextButton: some View {
        Button {
            index = (min(index, picks.count - 1) + 1) % picks.count
        } label: {
            VStack(spacing: 2) {
                Icon("arrow.right", size: 10)
                Text("\(min(index, picks.count - 1) + 1)/\(picks.count)")
                    .font(Theme.mono(10))
            }
            .foregroundColor(.secondary)
            .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Next suggestion")
        .accessibilityLabel("Next suggestion, \(min(index, picks.count - 1) + 1) of \(picks.count)")
    }
}

// MARK: - Confirm button

/// A button for actions other people see (a comment, an approval): the
/// first click asks, the second does it, then it reports how that went.
/// The ask times out after a few seconds so a stray click is harmless.
struct ConfirmActionButton: View {
    let title: String
    let confirmTitle: String
    let doneTitle: String
    let icon: String
    let help: String
    var tint: Color = .accentColor
    /// Card style: as tall as the card's next button.
    var compact = false
    let action: () async throws -> Void

    private enum Phase: Equatable { case idle, confirming, working, done, failed(String) }
    @State private var phase: Phase = .idle
    @State private var hovered = false

    var body: some View {
        Button(action: tap) {
            HStack(spacing: 5) {
                if phase == .working {
                    ProgressView().controlSize(.mini)
                } else {
                    Icon(glyph, size: 10)
                }
                Text(label).lineLimit(1)
            }
            .font(Theme.ui(11, .medium))
            .foregroundColor(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, compact ? 0 : 5)
            // One width through every label, so whatever sits beside the
            // button doesn't jump.
            .frame(minWidth: compact ? 104 : 96)
            .frame(height: compact ? 34 : nil)
            .background(RoundedRectangle(cornerRadius: compact ? 6 : 5, style: .continuous).fill(background))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(phase == .working || phase == .done)
        .onHover { hovered = $0 }
        .help(helpText)
        .accessibilityLabel(label)
        .animation(.easeOut(duration: 0.12), value: phase)
    }

    private var base: Color { tint == .secondary ? .primary : tint }

    private var label: String {
        switch phase {
        case .idle:       return title
        case .confirming: return confirmTitle
        case .working:    return title
        case .done:       return doneTitle
        case .failed:     return "Failed"
        }
    }

    private var glyph: String {
        switch phase {
        case .done:   return "checkmark"
        case .failed: return "exclamationmark.triangle"
        default:      return icon
        }
    }

    private var foreground: Color {
        switch phase {
        case .confirming: return .white
        case .failed:     return .red
        case .done:       return .green
        default:          return base
        }
    }

    private var background: Color {
        switch phase {
        case .confirming: return base.opacity(0.9)
        case .failed:     return Color.red.opacity(0.12)
        default:
            return base.opacity(hovered ? 0.22 : 0.14)
        }
    }

    private var helpText: String {
        if case .failed(let message) = phase { return message }
        return phase == .confirming ? "Click again to confirm" : help
    }

    private func tap() {
        switch phase {
        case .idle, .failed:
            phase = .confirming
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if phase == .confirming { phase = .idle }
            }
        case .confirming:
            phase = .working
            Task { @MainActor in
                do {
                    try await action()
                    phase = .done
                } catch {
                    phase = .failed(error.localizedDescription)
                }
            }
        case .working, .done:
            break
        }
    }
}
