import AppKit
import SwiftUI
import Combine

extension Notification.Name {
    /// Posted while a modal (e.g. NSOpenPanel) is up so the popover-dismissal
    /// monitor doesn't close the popover out from under it.
    static let pulleyPauseDismissal  = Notification.Name("PulleyPauseDismissal")
    static let pulleyResumeDismissal = Notification.Name("PulleyResumeDismissal")

    // Keyboard navigation. The local NSEvent monitor in AppDelegate fans these
    // out; ContentView holds the actual selection state and acts on them.
    /// userInfo: ["delta": Int]  — +1 next, -1 previous
    static let pulleyMoveSelection         = Notification.Name("PulleyMoveSelection")
    static let pulleyOpenSelectedInBrowser = Notification.Name("PulleyOpenSelectedInBrowser")
    static let pulleyCheckoutSelected      = Notification.Name("PulleyCheckoutSelected")
    static let pulleyCopySelectedBranch    = Notification.Name("PulleyCopySelectedBranch")
    static let pulleyToggleSelectedExpand  = Notification.Name("PulleyToggleSelectedExpand")
    static let pulleyFocusSearch           = Notification.Name("PulleyFocusSearch")
    static let pulleyOpenSettings          = Notification.Name("PulleyOpenSettings")
    /// Posted from popover to ask the AppDelegate to open the main window.
    static let pulleyOpenMainWindow        = Notification.Name("PulleyOpenMainWindow")

    /// Posted by Settings when the global hotkey was edited.
    static let pulleyHotkeyChanged   = Notification.Name("PulleyHotkeyChanged")
    /// Posted while a hotkey is being recorded — pauses the popover's local key
    /// monitor so it doesn't intercept the user's keystrokes.
    static let pulleyKeyMonitorPause  = Notification.Name("PulleyKeyMonitorPause")
    static let pulleyKeyMonitorResume = Notification.Name("PulleyKeyMonitorResume")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var store: Store!
    private var cancellables: Set<AnyCancellable> = []
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var mainWindow: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installEditMenu()

        store = Store()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            // `arrow.triangle.branch` reads as the VCS branching glyph GitHub
            // and most git UIs use for PRs. Falls through to similar shapes on
            // older systems that don't ship the newest set.
            let candidates = ["arrow.triangle.branch",
                              "arrow.branch",
                              "arrow.triangle.pull"]
            if let sym = candidates.lazy
                .compactMap({ NSImage(systemSymbolName: $0, accessibilityDescription: "Pulley") })
                .first {
                let cfg = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
                button.image = (sym.withSymbolConfiguration(cfg) ?? sym)
                button.image?.isTemplate = true
            } else {
                button.title = "PR"
            }
            button.imagePosition = .imageLeft
            button.imageHugsTitle = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        // .applicationDefined (not .transient) — .transient auto-closes when
        // any other window in our process (e.g. NSOpenPanel) takes focus, which
        // strands the SwiftUI sheet state and leaves the popover unresponsive
        // on its next open. Dismissal is handled manually via the click monitor.
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentSize = NSSize(width: 460, height: 520)
        let host = NSHostingController(rootView: ContentView().environmentObject(store))
        popover.contentViewController = host

        store.$prs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        // Global hotkey — fire toggle from anywhere. Re-registered when the
        // user changes the binding in Settings.
        HotkeyManager.shared.onPress = { [weak self] in
            self?.togglePopover(nil)
        }
        HotkeyManager.shared.register(Config.hotkey)

        // Settings posts this after editing the hotkey field so we re-bind.
        NotificationCenter.default.addObserver(
            forName: .pulleyHotkeyChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                HotkeyManager.shared.register(Config.hotkey)
            }
        }

        // While the user is recording a new hotkey in Settings we suspend the
        // popover's own key monitor so it doesn't swallow their keystrokes.
        NotificationCenter.default.addObserver(
            forName: .pulleyKeyMonitorPause, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopKeyMonitor() }
        }
        NotificationCenter.default.addObserver(
            forName: .pulleyKeyMonitorResume, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.startKeyMonitor()
            }
        }

        NotificationCenter.default.addObserver(
            forName: .pulleyOpenMainWindow, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openMainWindow() }
        }

        NotificationCenter.default.addObserver(
            forName: .pulleyPauseDismissal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopOutsideClickMonitor() }
        }

        NotificationCenter.default.addObserver(
            forName: .pulleyResumeDismissal, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.popover.isShown else { return }
                self.startOutsideClickMonitor()
            }
        }

        updateBadge()

        // Intentionally NOT calling store.sync() at launch — that would read
        // the Keychain and prompt before the user has interacted with the app.
        // Sync runs on first popover open (via syncIfStale) and on the 30-min
        // background timer.
    }

    private func updateBadge() {
        guard let button = statusItem.button else { return }
        let n = store.openCount
        let title = n > 0 ? " \(n)" : ""
        // Always use an attributed title so the count can flip red when
        // something needs attention (changes-requested or failing CI).
        let color: NSColor = store.needsAttention ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: color,
            .font:            NSFont.menuBarFont(ofSize: 0),
        ])

        // Red color + bare digit are invisible to VoiceOver. Provide a
        // semantic label so screen readers announce what the badge means.
        let summary: String
        switch (n, store.needsAttention) {
        case (0, _):     summary = "Pulley — no open pull requests"
        case (1, true):  summary = "Pulley — 1 open pull request, needs attention"
        case (1, false): summary = "Pulley — 1 open pull request"
        case (_, true):  summary = "Pulley — \(n) open pull requests, needs attention"
        case (_, false): summary = "Pulley — \(n) open pull requests"
        }
        button.setAccessibilityLabel(summary)
        button.toolTip = summary
    }

    /// `.accessory` apps don't get a main menu by default, so Cmd+V (and friends)
    /// have no responder and silently do nothing. Install a full menu (App,
    /// File, Edit, View, Window) so standard shortcuts — ⌘W, ⌘M, ⌃⌘F, copy /
    /// paste, etc. — all work when the main window is showing.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Pulley")
        appMenu.addItem(NSMenuItem(title: "About Pulley",
                                   action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Settings…",
                                   action: #selector(openSettingsFromMenu),
                                   keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        let hideItem = NSMenuItem(title: "Hide Pulley",
                                  action: #selector(NSApplication.hide(_:)),
                                  keyEquivalent: "h")
        appMenu.addItem(hideItem)
        let hideOthers = NSMenuItem(title: "Hide Others",
                                    action: #selector(NSApplication.hideOtherApplications(_:)),
                                    keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(NSMenuItem(title: "Show All",
                                   action: #selector(NSApplication.unhideAllApplications(_:)),
                                   keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit Pulley",
                                   action: #selector(NSApplication.terminate(_:)),
                                   keyEquivalent: "q"))
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        // File
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(title: "Open Main Window",
                                    action: #selector(openMainWindowFromMenu),
                                    keyEquivalent: "o"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Sync Now",
                                    action: #selector(syncFromMenu),
                                    keyEquivalent: "r"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(title: "Close Window",
                                    action: #selector(NSWindow.performClose(_:)),
                                    keyEquivalent: "w"))
        fileItem.submenu = fileMenu
        mainMenu.addItem(fileItem)

        // Edit
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo",         action: Selector(("undo:")),                keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo",               action: Selector(("redo:")),                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut",          action: #selector(NSText.cut(_:)),          keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy",         action: #selector(NSText.copy(_:)),         keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste",        action: #selector(NSText.paste(_:)),        keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All",   action: #selector(NSText.selectAll(_:)),    keyEquivalent: "a"))
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        // View
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let toggleSidebar = NSMenuItem(title: "Toggle Sidebar",
                                       action: #selector(NSSplitViewController.toggleSidebar(_:)),
                                       keyEquivalent: "s")
        toggleSidebar.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(toggleSidebar)
        viewMenu.addItem(NSMenuItem.separator())
        let fullScreen = NSMenuItem(title: "Enter Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)),
                                    keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        viewMenu.addItem(fullScreen)
        viewItem.submenu = viewMenu
        mainMenu.addItem(viewItem)

        // Window
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(title: "Minimize",
                                      action: #selector(NSWindow.performMiniaturize(_:)),
                                      keyEquivalent: "m"))
        windowMenu.addItem(NSMenuItem(title: "Zoom",
                                      action: #selector(NSWindow.performZoom(_:)),
                                      keyEquivalent: ""))
        windowMenu.addItem(NSMenuItem.separator())
        windowMenu.addItem(NSMenuItem(title: "Bring All to Front",
                                      action: #selector(NSApplication.arrangeInFront(_:)),
                                      keyEquivalent: ""))
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    @objc private func openMainWindowFromMenu() {
        NotificationCenter.default.post(name: .pulleyOpenMainWindow, object: nil)
    }

    @objc private func syncFromMenu() {
        store.sync()
    }

    @objc private func openSettingsFromMenu() {
        NotificationCenter.default.post(name: .pulleyOpenSettings, object: nil)
    }

    @objc func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            closePopover()
            return
        }
        popover.show(relativeTo: button.bounds,
                     of: button,
                     preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        startOutsideClickMonitor()
        startKeyMonitor()
        // Don't refetch every popover open — only if the cached data is >10min old.
        // The refresh button (and the 30-min background timer) cover the rest.
        store.syncIfStale(maxAge: 600)
    }

    private func closePopover() {
        popover.performClose(nil)
        stopOutsideClickMonitor()
        stopKeyMonitor()
    }

    /// Lazy-allocate the main window the first time it's opened, then reuse
    /// the same controller — closing the window just hides it.
    private func openMainWindow() {
        if mainWindow == nil {
            mainWindow = MainWindowController(store: store)
        }
        closePopover()
        mainWindow?.show()
    }

    /// Watches mouse clicks outside this app's windows and dismisses the
    /// popover. NSPopover's `.transient` behavior covers in-app clicks but
    /// silently ignores clicks in other apps' windows on some macOS versions —
    /// this fills that gap.
    private func startOutsideClickMonitor() {
        stopOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func stopOutsideClickMonitor() {
        if let m = outsideClickMonitor {
            NSEvent.removeMonitor(m)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Keyboard navigation

    /// Routes key events to ContentView via notifications while the popover is
    /// showing. Consumes the events it handles so SwiftUI text fields keep
    /// behaving normally for everything else.
    private func startKeyMonitor() {
        stopKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func stopKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Returns true if the event was handled (and should be swallowed).
    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        guard popover.isShown else { return false }

        let mods  = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers ?? ""
        let win   = popover.contentViewController?.view.window
        // A text field has focus → only handle Cmd-based shortcuts; pass plain
        // letters/arrows through so the user can type / paste normally.
        let typingActive = (win?.firstResponder is NSText)

        // Esc — blur the search field first if it has focus, otherwise close
        // the popover. Two-step so the user can escape typing without losing
        // the whole popover state.
        if event.keyCode == 53 {
            if typingActive, let win {
                win.makeFirstResponder(nil)
                return true
            }
            closePopover()
            return true
        }

        // Cmd-shortcuts work regardless of focus.
        if mods == .command {
            switch chars {
            case "r":
                store.sync()
                return true
            case ",":
                NotificationCenter.default.post(name: .pulleyOpenSettings, object: nil)
                return true
            case ".":
                NotificationCenter.default.post(name: .pulleyCheckoutSelected, object: nil)
                return true
            case "w":
                closePopover()
                return true
            case "o":
                NotificationCenter.default.post(name: .pulleyOpenMainWindow, object: nil)
                return true
            default:
                break
            }
        }

        if typingActive { return false }

        // Arrow / Return / Space.
        switch event.keyCode {
        case 125: // ↓
            NotificationCenter.default.post(name: .pulleyMoveSelection, object: nil,
                                            userInfo: ["delta": 1])
            return true
        case 126: // ↑
            NotificationCenter.default.post(name: .pulleyMoveSelection, object: nil,
                                            userInfo: ["delta": -1])
            return true
        case 36, 76: // Return / keypad Enter
            NotificationCenter.default.post(name: .pulleyOpenSelectedInBrowser, object: nil)
            return true
        case 49: // Space
            NotificationCenter.default.post(name: .pulleyToggleSelectedExpand, object: nil)
            return true
        default:
            break
        }

        // Letter shortcuts (only when not typing).
        switch chars {
        case "j":
            NotificationCenter.default.post(name: .pulleyMoveSelection, object: nil,
                                            userInfo: ["delta": 1])
            return true
        case "k":
            NotificationCenter.default.post(name: .pulleyMoveSelection, object: nil,
                                            userInfo: ["delta": -1])
            return true
        case "c":
            NotificationCenter.default.post(name: .pulleyCopySelectedBranch, object: nil)
            return true
        case "o":
            NotificationCenter.default.post(name: .pulleyCheckoutSelected, object: nil)
            return true
        case "/":
            NotificationCenter.default.post(name: .pulleyFocusSearch, object: nil)
            return true
        default:
            return false
        }
    }
}
