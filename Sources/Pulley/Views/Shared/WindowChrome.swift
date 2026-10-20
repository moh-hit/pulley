import SwiftUI
import AppKit

// MARK: - Detail-pane chrome

struct StatusBadge: View {
    let text: String
    let color: Color
    let filled: Bool

    var body: some View {
        Text(text)
            .font(Theme.mono(10, .semibold))
            .foregroundColor(filled ? .white : color)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(filled ? color : color.opacity(0.15))
            )
            .overlay(
                Capsule().stroke(
                    filled ? Color.clear : color.opacity(0.35),
                    lineWidth: 0.5
                )
            )
            .fixedSize()
    }
}

struct BranchPill: View {
    let branch: String

    var body: some View {
        HStack(spacing: 5) {
            Icon("arrow.triangle.branch", size: 10)
            Text(branch)
                .font(Theme.mono(11, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.06)))
        .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .frame(maxWidth: 240, alignment: .leading)
        .help(branch)
    }
}

struct DetailActionButton: View {
    enum Style { case primary, secondary, merge }

    let title: String
    let systemImage: String
    let nsImage: NSImage?
    let style: Style
    let action: () -> Void

    @State private var hovering = false
    @State private var pressing = false

    init(
        title: String,
        systemImage: String,
        nsImage: NSImage? = nil,
        style: Style,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.nsImage = nsImage
        self.style = style
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let img = nsImage {
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 15, height: 15)
                } else {
                    Icon(systemImage, size: 11)
                }
                Text(title)
                    .font(Theme.ui(12, .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, nsImage != nil ? 5 : 7)
            .foregroundColor(textColor)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(strokeColor, lineWidth: borderWidth)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering = $0 }
        .scaleEffect(pressing ? 0.97 : 1.0)
        .animation(.easeOut(duration: 0.08), value: pressing)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressing = true }
                .onEnded { _ in pressing = false }
        )
    }

    private var fillColor: Color {
        switch style {
        case .primary:
            return hovering ? Color.accentColor.opacity(0.88) : Color.accentColor
        case .secondary:
            return hovering ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03)
        case .merge:
            return hovering ? mergePurple.opacity(0.88) : mergePurple
        }
    }

    private var strokeColor: Color {
        switch style {
        case .primary, .merge: return Color.clear
        case .secondary:       return Color.primary.opacity(hovering ? 0.22 : 0.15)
        }
    }

    private var borderWidth: CGFloat {
        style == .secondary ? 0.7 : 0
    }

    private var textColor: Color {
        style == .secondary ? .primary : .white
    }
}

/// List-row chip for a PR that's in the merge queue or has auto-merge on.
/// Renders nothing otherwise, so callers can drop it in unconditionally.
struct MergeFlowChip: View {
    let pr: PR

    var body: some View {
        if let entry = pr.merge?.queueEntry {
            chip(
                icon: "list.number",
                text: entry.position <= 1 ? "queued · next" : "queued · #\(entry.position)",
                tint: entry.state == "UNMERGEABLE" ? .red : mergePurple,
                help: "In the merge queue — \(entry.summary)"
            )
        } else if let auto = pr.merge?.autoMerge {
            chip(
                icon: "clock.arrow.circlepath",
                text: "auto-merge",
                tint: mergePurple,
                help: "Auto-merge on" + (auto.method.map { " (\($0.shortLabel))" } ?? "")
                    + " — merges once requirements pass"
            )
        }
    }

    private func chip(icon: String, text: String, tint: Color, help: String) -> some View {
        HStack(spacing: 3) {
            Icon(icon, size: 9)
            Text(text)
                .font(Theme.mono(10, .medium))
                .lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.10)))
        .fixedSize()
        .help(help)
    }
}

/// List-row chip for a PR in a native GitHub stack: "stack 2/3".
struct StackChip: View {
    let pr: PR

    var body: some View {
        if let stack = pr.stack {
            HStack(spacing: 3) {
                Icon("square.stack.3d.up", size: 9)
                Text("\(stack.position)/\(stack.size)")
                    .font(Theme.mono(10, .medium))
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .fixedSize()
            .help("Stack #\(stack.number) — PR \(stack.position) of \(stack.size)")
        }
    }
}
