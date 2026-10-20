import SwiftUI
import CoreText

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

/// GitHub's merge-button purple — merge actions and merge-flow status.
let mergePurple = Color(red: 0.52, green: 0.30, blue: 0.86)

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

// MARK: - Main window theme

/// Main-window surfaces: a warm neutral "chrome" behind the sidebar, with
/// content on a raised panel. Adaptive so dark mode keeps the same shape.
enum Theme {
    static let chrome = adaptive(
        light: NSColor(srgbRed: 0.953, green: 0.949, blue: 0.937, alpha: 1),
        dark: NSColor(srgbRed: 0.106, green: 0.102, blue: 0.098, alpha: 1)
    )
    static let panel = adaptive(
        light: .white,
        dark: NSColor(srgbRed: 0.153, green: 0.149, blue: 0.145, alpha: 1)
    )
    static let hairline = Color.primary.opacity(0.08)
    static let selection = Color.primary.opacity(0.07)
    static let hover = Color.primary.opacity(0.04)

    /// Instrument Serif — greetings, section titles and big numbers.
    /// Display only: it has a single weight, so `weight` is ignored.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BundledFonts.font("InstrumentSerif-Regular", size: size, fallback: .system(size: size, design: .serif))
    }

    /// Geist — all interface text.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BundledFonts.font("Geist-\(BundledFonts.instance(weight))", size: size, fallback: .system(size: size, weight: weight))
    }

    /// Geist Mono — branches, PR numbers, SHAs, timestamps and diffs.
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        BundledFonts.font("GeistMono-\(BundledFonts.instance(weight))", size: size, fallback: .system(size: size, weight: weight, design: .monospaced))
    }

    /// GitHub's contribution greens, 0 (none) … 4 (most), light and dark.
    static func contribution(_ level: Int) -> Color {
        let light: [NSColor] = [
            NSColor(srgbRed: 0.922, green: 0.929, blue: 0.941, alpha: 1),   // #ebedf0
            NSColor(srgbRed: 0.608, green: 0.914, blue: 0.659, alpha: 1),   // #9be9a8
            NSColor(srgbRed: 0.251, green: 0.769, blue: 0.388, alpha: 1),   // #40c463
            NSColor(srgbRed: 0.188, green: 0.631, blue: 0.306, alpha: 1),   // #30a14e
            NSColor(srgbRed: 0.129, green: 0.431, blue: 0.224, alpha: 1),   // #216e39
        ]
        let dark: [NSColor] = [
            NSColor(srgbRed: 0.231, green: 0.227, blue: 0.220, alpha: 1),
            NSColor(srgbRed: 0.055, green: 0.267, blue: 0.161, alpha: 1),   // #0e4429
            NSColor(srgbRed: 0.000, green: 0.427, blue: 0.196, alpha: 1),   // #006d32
            NSColor(srgbRed: 0.149, green: 0.651, blue: 0.255, alpha: 1),   // #26a641
            NSColor(srgbRed: 0.224, green: 0.827, blue: 0.325, alpha: 1),   // #39d353
        ]
        let i = max(0, min(4, level))
        return adaptive(light: light[i], dark: dark[i])
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// Fonts shipped in the resource bundle (Resources/Fonts, SIL OFL — see the
/// *-OFL.txt files there): Geist, Geist Mono and Instrument Serif. They're
/// registered for this process at launch; if that fails, every `Theme` font
/// falls back to the matching system font rather than to Helvetica.
enum BundledFonts {
    private(set) static var registered = false

    static func register() {
        let urls = ["Geist-Variable", "GeistMono-Variable", "InstrumentSerif-Regular", "InstrumentSerif-Italic"]
            .compactMap { Bundle.pulleyResources.url(forResource: $0, withExtension: "ttf") }
        guard !urls.isEmpty else { return }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        registered = NSFont(name: "Geist-Regular", size: 12) != nil
    }

    static func font(_ postScriptName: String, size: CGFloat, fallback: Font) -> Font {
        registered ? .custom(postScriptName, fixedSize: size) : fallback
    }

    /// Named instance of the variable fonts for a SwiftUI weight.
    static func instance(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "ExtraLight"
        case .thin:       return "Thin"
        case .light:      return "Light"
        case .medium:     return "Medium"
        case .semibold:   return "SemiBold"
        case .bold:       return "Bold"
        case .heavy:      return "ExtraBold"
        case .black:      return "Black"
        default:          return "Regular"
        }
    }
}
