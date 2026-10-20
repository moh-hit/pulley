import SwiftUI
import AppKit

/// An icon from the bundled Phosphor set (Resources/Icons, MIT — see
/// Phosphor-LICENSE.txt), addressed by the SF Symbol name it replaces so
/// call sites read like `Image(systemName:)`. A `.fill` suffix picks
/// Phosphor's fill weight; otherwise sizes under 16pt use bold, which holds up next to medium-weight text.
/// Anything unmapped, or an SVG that fails to load (NSImage only renders
/// SVG on newer macOS), falls back to the SF Symbol itself.
struct Icon: View {
    let name: String
    let size: CGFloat

    init(_ name: String, size: CGFloat = 13) {
        self.name = name
        self.size = size
    }

    var body: some View {
        if let image = PhosphorIcons.image(for: name, size: size) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size * 1.2, height: size * 1.2)
                .accessibilityHidden(true)
        } else {
            Image(systemName: name)
                .font(.system(size: size))
        }
    }
}

enum PhosphorIcons {
    /// SF Symbol name (without `.fill`) → Phosphor icon name.
    static let map: [String: String] = [
        "arrow.clockwise": "arrow-clockwise",
        "arrow.down.circle": "arrow-circle-down",
        "arrow.right": "arrow-right",
        "arrow.right.square": "arrow-square-right",
        "arrow.triangle.2.circlepath": "arrows-clockwise",
        "arrow.triangle.branch": "git-branch",
        "arrow.triangle.merge": "git-merge",
        "arrow.triangle.pull": "git-pull-request",
        "arrow.up.forward.square": "arrow-square-out",
        "arrow.up.right.square": "arrow-square-out",
        "bell": "bell",
        "bolt": "lightning",
        "bookmark": "bookmark-simple",
        "bubble.left": "chat",
        "building.2": "buildings",
        "calendar": "calendar-blank",
        "checkmark": "check",
        "checkmark.circle": "check-circle",
        "checkmark.seal": "seal-check",
        "checkmark.square": "check-square",
        "chevron.down": "caret-down",
        "chevron.left.forwardslash.chevron.right": "code",
        "chevron.right": "caret-right",
        "chevron.up": "caret-up",
        "circle": "circle",
        "circle.dashed": "circle-dashed",
        "circle.grid.2x2": "squares-four",
        "circle.hexagongrid": "circles-four",
        "clock": "clock",
        "clock.arrow.circlepath": "clock-counter-clockwise",
        "command": "command",
        "cursorarrow.rays": "cursor-click",
        "doc.on.doc": "copy",
        "ellipsis.circle": "dots-three-circle",
        "envelope": "envelope-simple",
        "envelope.open": "envelope-simple-open",
        "exclamationmark.bubble": "chat-circle-dots",
        "exclamationmark.circle": "warning-circle",
        "exclamationmark.triangle": "warning",
        "eye": "eye",
        "eyes": "eyes",
        "folder": "folder",
        "gear": "gear",
        "gearshape": "gear-six",
        "hammer": "hammer",
        "hourglass": "hourglass",
        "house": "house",
        "info.circle": "info",
        "key": "key",
        "line.3.horizontal": "list",
        "link": "link",
        "list.number": "list-numbers",
        "lock": "lock",
        "lock.shield": "shield-check",
        "macwindow": "app-window",
        "magnifyingglass": "magnifying-glass",
        "minus.circle": "minus-circle",
        "minus.square": "minus-square",
        "pencil": "pencil-simple",
        "pencil.circle": "pencil-circle",
        "person.crop.circle": "user-circle",
        "plus": "plus",
        "plus.bubble": "chat-circle-text",
        "plus.square": "plus-square",
        "power": "power",
        "shield": "shield",
        "sidebar.left": "sidebar",
        "sparkles": "sparkle",
        "square": "square",
        "square.and.pencil": "note-pencil",
        "square.stack.3d.up": "stack",
        "star": "star",
        "tag": "tag",
        "text.bubble": "chat-text",
        "trash": "trash",
        "tray": "tray",
        "tray.full": "squares-four",
        "xmark": "x",
        "xmark.circle": "x-circle",
        "xmark.octagon": "x-circle",
    ]

    private static var cache: [String: NSImage] = [:]

    static func image(for sfName: String, size: CGFloat) -> NSImage? {
        let isFill = sfName.hasSuffix(".fill")
        let base = isFill ? String(sfName.dropLast(5)) : sfName
        guard let ph = map[base] else { return nil }
        // Bold below 16pt, where thinner strokes wash out next to Geist's
        // medium text; regular only for large glyphs.
        let file = isFill ? "\(ph)-fill" : (size >= 16 ? ph : "\(ph)-bold")
        let key = "\(file)@\(size)"
        if let cached = cache[key] { return cached }
        guard let url = Bundle.pulleyResources.url(forResource: file, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        // Give the image its real point size: some hosts (Menu labels) ignore
        // the SwiftUI frame and would draw the SVG at its 256pt viewBox.
        image.size = NSSize(width: size * 1.2, height: size * 1.2)
        image.isTemplate = true
        cache[key] = image
        return image
    }
}
