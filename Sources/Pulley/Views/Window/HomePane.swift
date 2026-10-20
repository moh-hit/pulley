import SwiftUI
import AppKit

/// Landing page of the main window: a greeting with what needs you, three
/// cards that jump into the matching PR filter, a few totals, and recently
/// updated PRs grouped by day. Everything is derived from the synced PR list
/// — no extra GitHub calls.
struct HomePane: View {
    @EnvironmentObject var store: Store
    /// Navigate to a section, optionally selecting a PR there.
    let onOpen: (MainSection, String?) -> Void
    let onOpenSettings: () -> Void

    private var prs: [PR] { store.prs }
    private func count(_ status: PRStatus) -> Int { prs.filter { $0.status == status }.count }
    private var failingCI: Int { prs.filter { $0.checkStatus == .failure }.count }
    /// Approved PRs that can merge (or join the queue) right now.
    private var readyToMerge: Int {
        prs.filter {
            $0.status == .approved && ($0.mergeAction == .merge || $0.mergeAction == .enqueue)
        }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                greeting
                if prs.isEmpty {
                    emptyState
                } else {
                    if let contributions = store.contributions {
                        // Cards and feed on the left, the contribution graph in
                        // the right column; stacked when the window is narrow.
                        ViewThatFits(in: .horizontal) {
                            HStack(alignment: .top, spacing: 28) {
                                mainColumn.frame(minWidth: 520)
                                ContributionChart(calendar: contributions).frame(width: 320)
                            }
                            VStack(alignment: .leading, spacing: 28) {
                                ContributionChart(calendar: contributions)
                                mainColumn
                            }
                        }
                    } else {
                        mainColumn
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 36)
            .padding(.bottom, 40)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var mainColumn: some View {
        VStack(alignment: .leading, spacing: 28) {
            cards
            activity
        }
    }

    // MARK: Greeting

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(greetingText)
                .font(Theme.display(30))
            Text(summaryLine)
                .font(Theme.ui(13))
                .foregroundColor(.secondary)
        }
    }

    private var greetingText: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        guard let name = store.viewerName, !name.isEmpty else { return part }
        return "\(part), \(name)"
    }

    private var summaryLine: String {
        guard !prs.isEmpty else {
            return store.lastSync == nil ? "Connect GitHub to see your pull requests." : "No open pull requests right now."
        }
        var parts: [String] = []
        let changes = count(.changes)
        if changes > 0 { parts.append("\(changes) waiting on changes") }
        if readyToMerge > 0 { parts.append("\(readyToMerge) ready to merge") }
        if failingCI > 0 { parts.append("\(failingCI) with failing CI") }
        return parts.isEmpty ? "Nothing urgent — everything's moving." : parts.joined(separator: " · ") + "."
    }

    // MARK: Cards

    private var cards: some View {
        HStack(spacing: 12) {
            HomeCard(
                value: count(.changes), title: "Changes requested",
                caption: "Sent back for changes", tint: count(.changes) > 0 ? .red : nil
            ) { onOpen(.prs(.status(.changes)), nil) }
            HomeCard(
                value: count(.review), title: "In review",
                caption: oldestInReview.map { "Oldest opened \($0) ago" } ?? "Nothing waiting"
            ) { onOpen(.prs(.status(.review)), nil) }
            HomeCard(
                value: count(.approved), title: "Approved",
                caption: readyToMerge > 0 ? "\(readyToMerge) ready to merge" : "None ready to merge"
            ) { onOpen(.prs(.status(.approved)), nil) }
            HomeCard(
                value: failingCI, title: "CI failing",
                caption: failingCI > 0 ? "Checks to look at" : "All checks passing",
                tint: failingCI > 0 ? .red : nil
            ) { onOpen(.prs(.failingCI), nil) }
        }
    }

    private var oldestInReview: String? {
        prs.filter { $0.status == .review }.map(\.createdAt).min().map(relativeTime)
    }



    // MARK: Activity

    /// Most recently updated PRs, bucketed by calendar day.
    private var activityDays: [(day: Date, prs: [PR])] {
        let recent = prs.sorted { $0.updatedAt > $1.updatedAt }.prefix(15)
        let cal = Calendar.current
        let grouped = Dictionary(grouping: recent) { cal.startOfDay(for: $0.updatedAt) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0] ?? []) }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Recently updated")
                .font(Theme.display(20))
            ForEach(activityDays, id: \.day) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(dayLabel(day.day).uppercased()).eyebrow()
                    VStack(spacing: 0) {
                        ForEach(Array(day.prs.enumerated()), id: \.element.id) { idx, pr in
                            ActivityRow(pr: pr) { onOpen(.prs(.all), pr.id) }
                            if idx < day.prs.count - 1 {
                                Rectangle().fill(Theme.hairline).frame(height: 1)
                            }
                        }
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
                }
            }
        }
    }

    private func dayLabel(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return "Today" }
        if cal.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(store.lastSync == nil
                 ? "Add a GitHub token and your organizations to get started."
                 : "When pull requests open in your organizations, they'll show up here.")
                .font(Theme.ui(13))
                .foregroundColor(.secondary)
            if store.lastSync == nil {
                Button("Open settings", action: onOpenSettings)
                    .controlSize(.large)
            }
        }
    }
}

/// Clickable summary tile: big serif number, title, one-line caption.
private struct HomeCard: View {
    let value: Int
    let title: String
    let caption: String
    var tint: Color? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(value)")
                    .font(Theme.display(34))
                    .foregroundColor(tint ?? .primary)
                Text(title)
                    .font(Theme.ui(13, .medium))
                    .foregroundColor(.primary)
                Text(caption)
                    .font(Theme.ui(12))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(hovered ? Theme.selection : Theme.chrome.opacity(0.6))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help("Show \(title.lowercased())")
    }
}

/// One recently-updated PR: time, title, repo and number, status.
private struct ActivityRow: View {
    let pr: PR
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Text(pr.updatedAt.formatted(date: .omitted, time: .shortened))
                    .font(Theme.ui(12).monospacedDigit())
                    .foregroundColor(.secondary)
                    .frame(width: 64, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text(pr.title)
                        .font(Theme.ui(13))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(pr.repo) #\(String(pr.number))")
                        .font(Theme.mono(11))
                        .foregroundColor(.secondary)
                }
                Spacer(minLength: 8)
                if let attention = RowAttention(pr: pr) {
                    AttentionChip(attention: attention)
                } else {
                    Text(pr.status.label)
                        .font(Theme.ui(12))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
