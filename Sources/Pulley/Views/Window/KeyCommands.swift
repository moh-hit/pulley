import SwiftUI
import AppKit

/// Keyboard commands for the main window's PR list, mirroring the popover's
/// keys. Plain keys only fire when no text field has focus and no sheet is up.
enum KeyCommand {
    case move(Int)        // ↓ j / ↑ k
    case openOnGitHub     // ↩
    case openInIDE        // ⌘. or o
    case copyBranch       // c
    case escape           // blur search, else clear selection
}

/// Invisible view that watches key-downs for its own window and reports
/// them as `KeyCommand`s. Returning `true` from `handler` swallows the event.
struct KeyCommands: NSViewRepresentable {
    let handler: (KeyCommand) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.view = view
        context.coordinator.install()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }

    @MainActor
    final class Coordinator {
        var handler: (KeyCommand) -> Bool
        weak var view: NSView?
        private var monitor: Any?

        init(handler: @escaping (KeyCommand) -> Bool) { self.handler = handler }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.view?.window,
                      event.window === window, window.attachedSheet == nil
                else { return event }
                return self.command(for: event, in: window).map { self.handler($0) ? nil : event } ?? event
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func command(for event: NSEvent, in window: NSWindow) -> KeyCommand? {
            // Arrow keys also carry .function / .numericPad, so look at the four
            // real modifier keys only.
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let chars = event.charactersIgnoringModifiers ?? ""
            let typing = window.firstResponder is NSText

            if event.keyCode == 53 { return .escape }
            if mods == .command, chars == "." { return .openInIDE }
            guard mods.isEmpty, !typing else { return nil }

            switch event.keyCode {
            case 125: return .move(1)
            case 126: return .move(-1)
            case 36, 76: return .openOnGitHub
            default: break
            }
            switch chars {
            case "j": return .move(1)
            case "k": return .move(-1)
            case "o": return .openInIDE
            case "c": return .copyBranch
            default:  return nil
            }
        }
    }
}
