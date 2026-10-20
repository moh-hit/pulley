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
    /// Collapsed to an icon-only rail. Remembered across launches.
    @AppStorage("ui.sidebarCollapsed") private var collapsed = false

    private static let statuses: [PRStatus] = [.changes, .review, .approved, .open]

    private var orgs: [(name: String, count: Int)] {
        let grouped = Dictionary(grouping: store.prs, by: \.org)
        return grouped.keys.sorted().map { ($0, grouped[$0]?.count ?? 0) }
    }

    var body: some View {
        VStack(alignment: collapsed ? .center : .leading, spacing: 2) {
            if collapsed {
                // Below the traffic lights, which take the rail's top edge.
                toggleButton
                    .padding(.top, 38)
                    .padding(.bottom, 12)
            } else {
                HStack {
                    Spacer().frame(width: 68)   // traffic lights
                    toggleButton
                    Spacer()
                }
                .frame(height: 28)
                brand
                    .padding(.top, 10)
                    .padding(.bottom, 14)
            }

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
                countTint: store.unreadInboxCount > 0 ? .accentColor : nil,
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

            Spacer(minLength: 16)

            syncRow
            SidebarItem(title: "Settings", icon: "gearshape", isSelected: false, collapsed: collapsed, action: onOpenSettings)
                .keyboardShortcut(",", modifiers: .command)
        }
        .padding(.horizontal, collapsed ? 8 : 10)
        .padding(.bottom, 12)
        .frame(width: collapsed ? 64 : 214)
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

    private var toggleButton: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { collapsed.toggle() }
        } label: {
            Icon("sidebar.left", size: 15)
                .foregroundColor(.secondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("s", modifiers: [.command, .control])
        .help(collapsed ? "Show sidebar (⌃⌘S)" : "Hide sidebar (⌃⌘S)")
        .accessibilityLabel(collapsed ? "Show sidebar" : "Hide sidebar")
    }

    /// "Synced 2m ago" — click to sync now.
    private var syncRow: some View {
        Button {
            store.sync()
        } label: {
            HStack(spacing: 8) {
                Icon(store.syncing ? "arrow.triangle.2.circlepath" : "arrow.clockwise", size: 12)
                    .frame(width: 18)
                if !collapsed {
                    Text(syncLabel)
                        .font(Theme.ui(12))
                    Spacer(minLength: 0)
                }
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(store.syncing)
        .keyboardShortcut("r", modifiers: .command)
        .help(collapsed ? "\(syncLabel) — sync now (⌘R)" : "Sync now (⌘R)")
    }

    private var syncLabel: String {
        store.syncing ? "Syncing…" : relativeSyncLabel(store.lastSync, now: nowTick).capitalizedFirst
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
