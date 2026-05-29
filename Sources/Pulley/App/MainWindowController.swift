import AppKit
import SwiftUI
import Combine

/// Lazy-allocated main window. The app normally runs as a menu-bar
/// `.accessory`; while this window is showing we flip the activation policy
/// to `.regular` so it behaves like a real app — dock icon, app menu,
/// keyboard focus, Cmd-Tab. On close we drop back to `.accessory`.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private let store: Store
    private var cancellables: Set<AnyCancellable> = []
    private weak var syncItem: NSToolbarItem?

    init(store: Store) {
        self.store = store

        // Open maximized to the screen's visible area by default; users can
        // resize down afterwards. Fall back to a sensible fixed size if no
        // screen is reported.
        let defaultFrame = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let window = NSWindow(
            contentRect: defaultFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Pulley"
        window.minSize = NSSize(width: 900, height: 560)
        window.setFrame(defaultFrame, display: true)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = false

        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: MainWindowView().environmentObject(store)
        )

        // Native toolbar carries sync + settings; the in-content HeaderBar
        // owns filters, search, group picker, and the sync-time readout.
        let toolbar = NSToolbar(identifier: "PulleyMainToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        store.$syncing
            .receive(on: RunLoop.main)
            .sink { [weak self] syncing in
                self?.updateSyncItem(syncing: syncing)
            }
            .store(in: &cancellables)

        store.$lastSync
            .receive(on: RunLoop.main)
            .sink { [weak self] last in
                self?.syncItem?.toolTip = relativeSyncLabel(last)
            }
            .store(in: &cancellables)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.setActivationPolicy(.regular)
        // Open at full visible-screen width by default. The window persists
        // across closes (isReleasedWhenClosed = false), so re-apply on each
        // open rather than only at construction.
        if let screen = window?.screen ?? NSScreen.main {
            window?.setFrame(screen.visibleFrame, display: true)
        }
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

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .pulleySync, .pulleySettings]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, .space, .pulleySync, .pulleySettings]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier id: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch id {
        case .pulleySync:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Sync"
            item.paletteLabel = "Sync"
            item.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Sync")
            item.target = self
            item.action = #selector(toolbarSync)
            item.toolTip = relativeSyncLabel(store.lastSync)
            item.isBordered = true
            syncItem = item
            return item
        case .pulleySettings:
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = "Settings"
            item.paletteLabel = "Settings"
            item.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
            item.target = self
            item.action = #selector(toolbarOpenSettings)
            item.toolTip = "Settings"
            item.isBordered = true
            return item
        default:
            return nil
        }
    }

    @objc private func toolbarSync() {
        store.sync()
    }

    @objc private func toolbarOpenSettings() {
        NotificationCenter.default.post(name: .pulleyMainOpenSettings, object: nil)
    }

    private func updateSyncItem(syncing: Bool) {
        guard let item = syncItem else { return }
        item.isEnabled = !syncing
        let name = syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"
        item.image = NSImage(systemSymbolName: name, accessibilityDescription: syncing ? "Syncing" : "Sync")
    }
}

extension NSToolbarItem.Identifier {
    static let pulleySync     = NSToolbarItem.Identifier("PulleySync")
    static let pulleySettings = NSToolbarItem.Identifier("PulleySettings")
}

extension Notification.Name {
    /// Sent by the main window's toolbar gear so `MainWindowView` can present
    /// its settings sheet. Distinct from `.pulleyOpenSettings` (popover-only).
    static let pulleyMainOpenSettings = Notification.Name("PulleyMainOpenSettings")
}
