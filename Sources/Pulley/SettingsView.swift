import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var store: Store
    let onClose: () -> Void

    // Intentionally NOT initialized from `Config.token` — reading the keychain
    // here would trigger the macOS prompt every time settings is opened. The
    // field starts empty; if a token is already saved (Config.hasToken), we
    // show a "saved" hint and only write a new value if the user types one.
    @State private var token: String = ""
    @State private var tokenCleared: Bool = false
    @State private var orgs: [String] = {
        let saved = Config.orgs
        return saved.isEmpty ? [""] : saved
    }()
    @State private var scope: Scope  = Config.scope
    @State private var preferredIDE: IDE = Config.preferredIDE
    @State private var baseDir: String   = Config.workspaceBaseDir
    @State private var launchAtLogin: Bool = Config.launchAtLogin
    @State private var hotkey: Hotkey = Config.hotkey

    var body: some View {
        VStack(spacing: 0) {
            // Top bar
            HStack(spacing: 10) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.accentColor)
                Text("Settings")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: { onClose() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    section(title: "GITHUB", icon: "lock.shield") {
                        field(label: "Personal access token", required: true) {
                            HStack(spacing: 6) {
                                SecureField(
                                    Config.hasToken && !tokenCleared
                                        ? "•••••••••• (saved — leave blank to keep)"
                                        : "ghp_...",
                                    text: $token
                                )
                                .textFieldStyle(.roundedBorder)
                                Button("Paste") {
                                    if let s = NSPasteboard.general.string(forType: .string) {
                                        token = s.trimmingCharacters(in: .whitespacesAndNewlines)
                                        tokenCleared = false
                                    }
                                }
                                .controlSize(.small)
                                if !token.isEmpty {
                                    Button("Clear field") { token = "" }
                                        .controlSize(.small)
                                } else if Config.hasToken && !tokenCleared {
                                    Button("Remove saved") { tokenCleared = true }
                                        .controlSize(.small)
                                }
                            }
                            caption(
                                tokenCleared
                                    ? "Saved token will be removed on Save."
                                    : "Scopes: repo, read:org · stored in macOS Keychain"
                            )
                        }

                        field(label: "Organizations", required: true) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(orgs.indices, id: \.self) { i in
                                    HStack(spacing: 6) {
                                        TextField("github-org-name", text: $orgs[i])
                                            .textFieldStyle(.roundedBorder)
                                        Button {
                                            orgs.remove(at: i)
                                            if orgs.isEmpty { orgs = [""] }
                                        } label: {
                                            Image(systemName: "minus.circle")
                                                .foregroundColor(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .disabled(orgs.count == 1)
                                        .help("Remove")
                                    }
                                }
                                Button {
                                    orgs.append("")
                                } label: {
                                    Label("Add organization", systemImage: "plus")
                                        .font(.system(size: 11))
                                }
                                .buttonStyle(.plain)
                                .foregroundColor(.accentColor)
                            }
                            caption("PRs are aggregated across all configured orgs.")
                        }

                        field(label: "Default scope") {
                            Picker("", selection: $scope) {
                                ForEach(Scope.allCases) { s in
                                    Text(s.label).tag(s)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                    }

                    section(title: "CHECKOUT IN IDE", icon: "chevron.left.forwardslash.chevron.right") {
                        field(label: "Preferred IDE") {
                            HStack(spacing: 8) {
                                ForEach(IDE.allCases) { ide in
                                    IDETile(ide: ide, selected: preferredIDE == ide) {
                                        preferredIDE = ide
                                    }
                                }
                            }
                        }

                        field(label: "Workspace base dir") {
                            HStack(spacing: 6) {
                                TextField("~/code", text: $baseDir)
                                    .textFieldStyle(.roundedBorder)
                                Button("Choose…") {
                                    if let url = chooseDirectory() {
                                        baseDir = shortenPath(url.path)
                                    }
                                }
                                .controlSize(.small)
                            }
                            caption("Pulley looks for each repo at <base>/<repo>. For PR checkouts it creates a git worktree at <base>/<repo>--<branch-slug> — your main checkout stays untouched.")
                        }
                    }

                    section(title: "GENERAL", icon: "macwindow") {
                        Toggle("Launch at login", isOn: $launchAtLogin)
                        caption("App auto-syncs every 30 minutes while running. Use the ⟳ button in the header for an immediate refresh.")
                    }

                    section(title: "GLOBAL HOTKEY", icon: "command") {
                        field(label: "Summon Pulley from anywhere") {
                            HStack(spacing: 6) {
                                HotkeyRecorder(hotkey: $hotkey)
                                Spacer()
                                Button("Default") { hotkey = .defaultHotkey }
                                    .controlSize(.small)
                                Button("Clear") { hotkey = .none }
                                    .controlSize(.small)
                                    .disabled(!hotkey.isSet)
                            }
                            caption("Click the field, then press a key combo (with at least one modifier). Esc cancels.")
                        }
                    }
                }
                .padding(18)
            }

            Divider()
            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save", action: save)
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasUsableToken || !hasAnyOrg)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Save

    private var hasAnyOrg: Bool {
        orgs.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    /// Save is allowed if the user typed a new token, OR a token is already
    /// saved and they haven't asked to remove it.
    private var hasUsableToken: Bool {
        if !token.isEmpty { return true }
        return Config.hasToken && !tokenCleared
    }

    private func save() {
        // Touch the keychain only when there's actually something to write or
        // delete — otherwise leave it untouched (no prompt).
        var tokenChanged = false
        if !token.isEmpty {
            Config.token = token
            tokenChanged = true
        } else if tokenCleared {
            Config.token = ""        // clears keychain + flips hasToken to false
            tokenChanged = true
        }

        let orgsChanged = orgs.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                              .filter { !$0.isEmpty } != Config.orgs
        Config.orgs             = orgs
        Config.scope            = scope
        Config.preferredIDE     = preferredIDE
        Config.workspaceBaseDir = baseDir
        Config.launchAtLogin    = launchAtLogin

        if hotkey != Config.hotkey {
            Config.hotkey = hotkey
            NotificationCenter.default.post(name: .pulleyHotkeyChanged, object: nil)
        }

        onClose()
        if tokenChanged || orgsChanged || store.prs.isEmpty {
            store.sync()
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func section<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.8)
            }
            .foregroundColor(.accentColor)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func field<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.primary)
                if required {
                    Text("*").foregroundColor(.red).font(.system(size: 11))
                }
            }
            content()
        }
    }

    private func caption(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 10))
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Directory picker

    private func chooseDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: Config.expandedBaseDir)

        // Suspend the popover's outside-click dismissal while the panel is up —
        // a click on another app's window during the modal would otherwise
        // close the popover and strand this sheet.
        NotificationCenter.default.post(name: .pulleyPauseDismissal, object: nil)
        defer { NotificationCenter.default.post(name: .pulleyResumeDismissal, object: nil) }

        // Make the panel actually appear on top — popover is the key window.
        NSApp.activate(ignoringOtherApps: true)
        panel.level = .modalPanel

        if panel.runModal() == .OK { return panel.url }
        return nil
    }

    private func shortenPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

// MARK: - Hotkey recorder

/// Click-to-record field for a global hotkey. While recording, a local
/// NSEvent monitor captures the next key + modifier combo; Esc cancels.
/// We post `.pulleyKeyMonitorPause` so the popover's own key monitor doesn't
/// swallow the keystrokes before we see them.
private struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any? = nil

    var body: some View {
        Button(action: toggle) {
            Text(recording ? "Press combo…" : hotkey.display)
                .font(.system(size: 12, weight: recording ? .semibold : .regular, design: .monospaced))
                .foregroundColor(recording ? .accentColor : .primary)
                .frame(minWidth: 110, alignment: .center)
                .padding(.vertical, 5)
                .padding(.horizontal, 12)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(recording
                              ? Color.accentColor.opacity(0.18)
                              : Color.primary.opacity(0.06))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(recording ? Color.accentColor : Color.primary.opacity(0.12),
                                lineWidth: recording ? 1.0 : 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(recording ? "Press a key combo, or Esc to cancel" : "Click to change")
        .onDisappear { stop() }
    }

    private func toggle() {
        if recording { stop() } else { start() }
    }

    private func start() {
        recording = true
        NotificationCenter.default.post(name: .pulleyKeyMonitorPause, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // Esc cancels.
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            // Require at least one modifier so we don't bind plain letters.
            guard !mods.isEmpty else { return nil }
            hotkey = Hotkey(modifiers: carbonModifiers(mods),
                            keyCode:   UInt32(event.keyCode))
            stop()
            return nil
        }
    }

    private func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if recording {
            NotificationCenter.default.post(name: .pulleyKeyMonitorResume, object: nil)
        }
        recording = false
    }
}

// MARK: - IDE tile

/// Icon-led IDE picker tile. Uses the real `.app` icon when the IDE is
/// installed, falls back to a system glyph when it isn't.
private struct IDETile: View {
    let ide: IDE
    let selected: Bool
    let onTap: () -> Void

    private var installed: Bool { ide.installedURL != nil }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Group {
                    if let icon = ide.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .interpolation(.high)
                    } else {
                        Image(systemName: "questionmark.app.dashed")
                            .resizable()
                            .foregroundColor(.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                Text(ide.displayName)
                    .font(.system(size: 11, weight: selected ? .semibold : .regular))
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(
                        selected ? Color.accentColor : Color.primary.opacity(0.1),
                        lineWidth: selected ? 1.2 : 0.5
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(installed ? 1.0 : 0.55)
        .help(installed ? ide.displayName : "\(ide.displayName) not installed")
    }
}
