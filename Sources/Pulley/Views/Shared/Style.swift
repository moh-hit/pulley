import SwiftUI

// Shared presentation layer: the single source of truth for how model states
// map to colors, glyphs, and human-friendly time strings. Both the popover
// (ContentView) and the main window (MainWindow) read from here so the two
// surfaces stay visually consistent and these mappings live in one place.

// MARK: - PR status

func statusColor(_ s: PRStatus) -> Color {
    switch s {
    case .changes:  return .red
    case .approved: return .green
    case .review:   return .orange
    case .open:     return .blue
    }
}

// MARK: - CI checks

func checkColor(_ s: CheckStatus) -> Color {
    switch s {
    case .success:        return .green
    case .failure:        return .red
    case .pending:        return .orange
    case .neutral, .none: return .secondary
    }
}

func checkGlyph(_ s: CheckStatus) -> String {
    switch s {
    case .success: return "checkmark.circle.fill"
    case .failure: return "xmark.octagon.fill"
    case .pending: return "clock.fill"
    case .neutral: return "minus.circle.fill"
    case .none:    return "circle"
    }
}

// MARK: - Mergeable state

func mergeableColor(_ s: MergeableState) -> Color {
    switch s {
    case .dirty, .blocked: return .red
    case .behind:          return .orange
    case .unstable:        return .yellow
    default:               return .secondary
    }
}

func mergeableGlyph(_ s: MergeableState) -> String {
    switch s {
    case .dirty:    return "exclamationmark.triangle.fill"
    case .behind:   return "arrow.down.circle.fill"
    case .blocked:  return "lock.fill"
    case .unstable: return "exclamationmark.circle.fill"
    default:        return "circle"
    }
}

// MARK: - Repo / org color

/// Stable per-repo (or per-org) color derived from a djb2 hash of the name, so
/// each repo keeps a recognizable tint without a hand-maintained palette.
func colorForRepo(_ repo: String) -> Color {
    var h: UInt64 = 5381
    for byte in repo.utf8 { h = (h &* 33) &+ UInt64(byte) }
    let hue = Double(h % 360) / 360.0
    return Color(hue: hue, saturation: 0.55, brightness: 0.85)
}

// MARK: - Relative time

/// Compact "now / 5m / 3h / 2d / 4mo / 1y" stamp for row timestamps.
func relativeTime(_ date: Date) -> String {
    let s = Int(Date().timeIntervalSince(date))
    if s < 60      { return "now" }
    if s < 3600    { return "\(s / 60)m" }
    if s < 86400   { return "\(s / 3600)h" }
    let d = s / 86400
    if d < 30      { return "\(d)d" }
    if d < 365     { return "\(d / 30)mo" }
    return "\(d / 365)y"
}
