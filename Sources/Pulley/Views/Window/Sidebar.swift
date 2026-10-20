import SwiftUI
import AppKit

/// Top-level places in the main window, picked from the sidebar.
enum MainSection: Hashable {
    case home
    case prs(SidebarFilter)
    case inbox
}

/// Left rail: Home, the PR filters with live counts, Inbox, and — when PRs
/// span several orgs — one entry per org. Sync status and Settings sit at
/// the bottom. The window's traffic lights float over its top edge.
struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var section: MainSection
    let onOpenSettings: () -> Void

    @State private var nowTick = Date()
    /// Icon-only rail, decided by the window (user choice or too narrow).
    let collapsed: Bool
    /// False when the window is too narrow for the full sidebar.
    let canToggle: Bool
    let onToggle: () -> Void

    private static let statuses: [PRStatus] = [.changes, .review, .approved, .open]

    private var orgs: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: store.prs, by: \.org)
        return grouped.keys.sorted().map { ($0, grouped[$0]?.count ?? 0) }
    }

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            if collapsed {
                toggleButton
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            } else {
                HStack(spacing: 0) {
                    brand
                    Spacer(minLength: 4)
                    toggleButton
                }
                .padding(.top, 8)
                .padding(.bottom, 12)
            }

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            SidebarItem(
                title: "Home", icon: "house",
                isSelected: section == .home, collapsed: collapsed, shortcut: "1"
            ) { section = .home }

            groupLabel("Pull requests")

            SidebarItem(
                title: SidebarFilter.all.label, icon: "tray.full",
                count: store.prs.count,
                isSelected: section == .prs(.all), collapsed: collapsed, shortcut: "2"
            ) { section = .prs(.all) }

            ForEach(Array(Self.statuses.enumerated()), id: \.element) { idx, status in
                let filter = SidebarFilter.status(status)
                let count = store.prs.filter { $0.status == status }.count
                SidebarItem(
                    title: filter.label, icon: filter.systemImage,
                    count: count,
                    countTint: status == .changes && count > 0 ? .red : nil,
                    isSelected: section == .prs(filter),
                    collapsed: collapsed,
                    shortcut: KeyEquivalent(Character("\(idx + 3)"))
                ) { section = .prs(filter) }
            }

            SidebarItem(
                title: "Inbox", icon: "bell",
                count: store.unreadInboxCount,
                isSelected: section == .inbox, collapsed: collapsed, shortcut: "7"
            ) { section = .inbox }

            if orgs.count > 1 {
                groupLabel("Organizations")
                ForEach(orgs, id: \.name) { org in
                    SidebarItem(
                        title: org.name, icon: "building.2",
                        count: org.count,
                        isSelected: section == .prs(.org(org.name)),
                        collapsed: collapsed
                    ) { section = .prs(.org(org.name)) }
                }
            }
                }
            }

            Spacer(minLength: 8)

            syncRow
            SidebarItem(title: "Settings", icon: "gearshape", isSelected: false, collapsed: collapsed, action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, collapsed ? 8 : 10)
        .padding(.bottom, 12)
        // The collapsed rail must clear the traffic lights (~70pt), or they
        // overlap the content panel's rounded corner.
        .frame(width: collapsed ? 76 : 214)
        .clipped()
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { nowTick = $0 }
    }

    private var brand: some View {
        HStack(spacing: 7) {
            if let url = Bundle.pulleyResources.url(forResource: "MenuBarIcon", withExtension: "svg"),
               let mark = NSImage(contentsOf: url) {
                Image(nsImage: templated(mark))
                    .resizable()
                    .aspectRatio(84.0 / 96.0, contentMode: .fit)
                    .frame(height: 17)
            }
            Text("Pulley")
                .font(Theme.display(20))
        }
        .padding(.horizontal, 8)
    }

    private func templated(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        return image
    }

    private var toggleButton: some View {
        Button(action: onToggle) {
            Icon("sidebar.left", size: 15)
                .foregroundColor(.secondary)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .disabled(!canToggle)
        .help(!canToggle
              ? "Widen the window to show the sidebar"
              : (collapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)"))
        .accessibilityLabel(collapsed ? "Show sidebar" : "Hide sidebar")
    }

    @ViewBuilder
    private func groupLabel(_ text: String) -> some View {
        if collapsed {
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 24, height: 1)
                .padding(.vertical, 10)
        } else {
            Text(text)
                .font(Theme.ui(11, .medium))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 14)
                .padding(.bottom, 4)
        }
    }


    /// "Synced 2m ago" — click to sync now.
    private var syncRow: some View {
        Button {
            store.sync()
        } label: {
            HStack(spacing: 8) {
                Icon(store.lastError != nil && !store.syncing
                        ? "exclamationmark.triangle.fill"
                        : (store.syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise"),
                     size: 12)
                    .frame(width: 18)
                if !collapsed {
                    Text(syncLabel)
                        .font(Theme.ui(12))
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(store.lastError != nil && !store.syncing ? .red : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.syncing)
        .accessibilityLabel(syncLabel)
        .keyboardShortcut("r", modifiers: .command)
        .help(store.lastError.map { SyncProblem(raw: $0).raw } ?? (collapsed ? "\(syncLabel) — sync now (⌘R)" : "Sync now (⌘R)"))
    }

    private var syncLabel: String {
        if store.syncing { return "Syncing…" }
        if store.lastError != nil { return "Couldn't sync · Retry" }
        return relativeSyncLabel(store.lastSync, now: nowTick).capitalizedFirst
    }
}

/// One sidebar row: icon, title, optional count. Selected rows get a soft
/// neutral pill rather than the system accent, matching the calm chrome.
struct SidebarItem: View {
    let title: String
    let icon: String
    var count: Int? = nil
    var countTint: Color? = nil
    let isSelected: Bool
    /// Icon-only rail: the title moves into the tooltip and a tinted count
    /// becomes a dot on the icon.
    var collapsed: Bool = false
    var shortcut: KeyEquivalent? = nil
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            if collapsed {
                railLabel
            } else {
                fullLabel
            }
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .modifier(OptionalShortcut(key: shortcut))
        .help(collapsed ? title + (count.map { $0 > 0 ? " · \($0)" : "" } ?? "") : "")
        .accessibilityLabel(title)
        .accessibilityValue(count.map { $0 > 0 ? "\($0)" : "" } ?? "")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var railLabel: some View {
        Icon(icon, size: 15)
            .foregroundColor(isSelected ? .primary : .secondary)
            .frame(width: 40, height: 32)
            .overlay(alignment: .topTrailing) {
                if let count, count > 0, let countTint {
                    Circle()
                        .fill(countTint)
                        .frame(width: 6, height: 6)
                        .padding(.top, 6)
                        .padding(.trailing, 7)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Theme.selection : (hovered ? Theme.hover : .clear))
            )
            .contentShape(Rectangle())
    }

    private var fullLabel: some View {
        HStack(spacing: 8) {
            Icon(icon, size: 13)
                .frame(width: 18)
                .foregroundColor(isSelected ? .primary : .secondary)
            Text(title)
                .font(Theme.ui(13, isSelected ? .medium : .regular))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let count, count > 0 {
                Text("\(count)")
                    .font(Theme.ui(11, .medium).monospacedDigit())
                    .foregroundColor(countTint ?? .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isSelected ? Theme.selection : (hovered ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
    }
}

private struct OptionalShortcut: ViewModifier {
    let key: KeyEquivalent?
    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

extension String {
    /// "synced 2m ago" → "Synced 2m ago".
    var capitalizedFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
