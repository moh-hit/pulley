import SwiftUI
import AppKit

// MARK: - Inbox

/// Notifications inbox pane. Reuses the same row chrome as the PR list so
/// the two surfaces feel like one app. Rows are flat (no detail pane); a
/// click opens the thread in the browser and silently marks it read.
struct InboxPane: View {
    let threads: [InboxThread]
    let query: String
    let onOpen: (InboxThread) -> Void
    let onMarkRead: (String) -> Void

    private var filtered: [InboxThread] {
        guard !query.isEmpty else { return threads }
        let q = query.lowercased()
        return threads.filter {
            ($0.title + " " + $0.repo + " " + $0.org + " " + $0.reasonLabel)
                .lowercased().contains(q)
        }
    }

    var body: some View {
        Group {
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Theme.panel)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Icon("tray", size: 32)
                .foregroundColor(.secondary.opacity(0.45))
            Text(threads.isEmpty ? "Inbox zero" : "Nothing matches")
                .font(Theme.ui(14, .medium))
                .foregroundColor(.secondary)
            Text(threads.isEmpty
                 ? "No unread notifications. Sync to refresh."
                 : "Try a different search.")
                .font(Theme.ui(11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, t in
                    InboxRow(
                        thread: t,
                        onOpen:     { onOpen(t) },
                        onMarkRead: { onMarkRead(t.id) }
                    )
                    if idx < filtered.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 18)
                    }
                }
                Color.clear.frame(height: 4)
            }
        }
    }
}

private struct InboxRow: View {
    let thread: InboxThread
    let onOpen: () -> Void
    let onMarkRead: () -> Void
    @State private var hovered = false

    private var typeGlyph: String {
        switch thread.type {
        case "PullRequest": return "arrow.triangle.pull"
        case "Issue":       return "circle.dashed"
        case "Discussion":  return "bubble.left"
        case "Release":     return "tag"
        case "Commit":      return "scribble"
        default:            return "bell"
        }
    }

    private var typeTint: Color {
        .secondary
    }

    private var reasonTint: Color {
        // Only security alerts are a problem; every other reason is context.
        thread.reason == "security_alert" ? .red : .secondary
    }

    var body: some View {
        HStack(spacing: 0) {
            // Unread indicator bar — mirrors the PR row status bar.
            Rectangle()
                .fill(thread.unread ? typeTint : Color.clear)
                .frame(width: 3)
                .opacity(thread.unread ? 0.85 : 0)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Icon(typeGlyph, size: 11)
                        .foregroundColor(typeTint)
                        .frame(width: 14)

                    Text(thread.title)
                        .font(Theme.ui(14, thread.unread ? .semibold : .regular))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                        .help(thread.title)

                    if hovered {
                        Button(action: onMarkRead) {
                            Icon("envelope.open", size: 11)
                                .foregroundColor(.secondary)
                                .frame(width: 22, height: 20)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Color.primary.opacity(0.07))
                                )
                        }
                        .buttonStyle(.plain)
                        .help("Mark as read")
                    }

                    Text(relativeTime(thread.updatedAt))
                        .font(Theme.mono(11))
                        .foregroundColor(.secondary.opacity(0.85))
                        .frame(width: 44, alignment: .trailing)
                        .help("Updated \(thread.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                }

                HStack(spacing: 8) {
                    reasonChip
                    repoLabel
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 11)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onOpen() }
    }

    private var rowBackground: Color {
        hovered ? Color.primary.opacity(0.04) : .clear
    }

    private var reasonChip: some View {
        Text(thread.reasonLabel.lowercased())
            .font(Theme.mono(10, .semibold))
            .foregroundColor(reasonTint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(reasonTint.opacity(0.13)))
            .fixedSize()
    }

    private var repoLabel: some View {
        HStack(spacing: 4) {
            (Text(thread.org + "/").foregroundColor(.secondary.opacity(0.6))
             + Text(thread.repo).foregroundColor(.secondary))
                .font(Theme.mono(11, .regular))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help("\(thread.org)/\(thread.repo)")
    }
}
