import AppKit
import SwiftUI

/// Lazy-allocated main window. The app normally runs as a menu-bar
/// `.accessory`; while this window is showing we flip the activation policy
/// to `.regular` so it behaves like a real app — dock icon, app menu,
/// keyboard focus, Cmd-Tab. On close we drop back to `.accessory`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "PulleyMainWindow"
    private let store: Store

    init(store: Store) {
        self.store = store

        // Open maximized to the screen's visible area by default; users can
        // resize down afterwards. Fall back to a sensible fixed size if no
        // screen is reported.
        let defaultFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulley"
        // Collapsed rail 76 + list 340 + detail 480 + padding fits in 920.
        window.minSize = NSSize(width: 920, height: 600)
        // First launch fills the screen; after that the window keeps whatever
        // size and position the user gave it (AppKit saves it on every move).
        window.setFrame(defaultFrame, display: true)
        window.setFrameUsingName(Self.frameName)
        window.setFrameAutosaveName(Self.frameName)
        window.isReleasedWhenClosed = false
        // Content runs under a transparent title bar so the sidebar's warm
        // chrome reaches the top edge, with the traffic lights over it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainWindowView().environmentObject(store)
        )
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        // Drop back to menu-bar-only on close. Defer one runloop tick so
        // AppKit finishes the close transition before we hide the dock icon.
        DispatchQueue.main.async {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
