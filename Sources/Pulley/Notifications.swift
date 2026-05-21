import Foundation
@preconcurrency import UserNotifications
import AppKit

/// Compares each sync's PR list against a persistent snapshot and posts a
/// macOS notification when something interesting changes:
///   - new PR appears in the user's scope
///   - status flips to `.approved` or `.changes`
///   - CI flips to `.failure` or `.success`
///
/// Tapping a notification opens the PR in the browser.
@MainActor
final class NotificationsManager: NSObject {

    static let shared = NotificationsManager()

    // v2: added mergeableState tracking — v1 snapshots are dropped on first load.
    private let snapshotKey       = "notifications.snapshot.v2"
    private let permissionAskedKey = "notifications.permissionAsked"
    private var authorized = false

    private struct Snapshot: Codable {
        var status:         [String: String]   // PR.id -> PRStatus.rawValue
        var checkStatus:    [String: String]   // PR.id -> CheckStatus.rawValue
        var mergeableState: [String: String]   // PR.id -> MergeableState.rawValue
    }

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    /// Request authorization lazily — on the first sync that produces results,
    /// not at app launch (which would prompt even users who haven't set up the
    /// app yet).
    func requestAuthorizationIfNeeded() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                Task { @MainActor in self.authorized = true }
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    Task { @MainActor in self.authorized = granted }
                }
            default:
                Task { @MainActor in self.authorized = false }
            }
        }
    }

    /// Call once per successful sync. First call only seeds the snapshot
    /// (no notifications) so we don't spam the user on app launch.
    func reconcile(_ prs: [PR]) {
        let newSnap = Snapshot(
            status:         Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0.status.rawValue) }),
            checkStatus:    Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0.checkStatus.rawValue) }),
            mergeableState: Dictionary(uniqueKeysWithValues: prs.map { ($0.id, $0.mergeableState.rawValue) })
        )

        guard let oldSnap = loadSnapshot() else {
            saveSnapshot(newSnap)
            return
        }

        // Notifications gated on authorization — we still update the snapshot
        // either way so a future grant doesn't trigger a backlog.
        if authorized {
            diffAndPost(old: oldSnap, new: newSnap, prs: prs)
        }
        saveSnapshot(newSnap)
    }

    /// Wipe state — handy when the user signs out or rotates token/org.
    func resetSnapshot() {
        UserDefaults.standard.removeObject(forKey: snapshotKey)
    }

    // MARK: - Internals

    private func diffAndPost(old: Snapshot, new: Snapshot, prs: [PR]) {
        for pr in prs {
            let oldStatus      = old.status[pr.id]
            let oldCheckStatus = old.checkStatus[pr.id]
            let newStatus      = pr.status.rawValue
            let newCheckStatus = pr.checkStatus.rawValue

            // 1) New PR landed in the user's scope.
            if oldStatus == nil {
                post(
                    title: "New PR · \(pr.repo)",
                    body:  pr.title,
                    pr: pr
                )
                continue
            }

            // 2) Review state transition worth flagging.
            if oldStatus != newStatus {
                switch pr.status {
                case .approved:
                    post(title: "Approved · \(pr.repo)", body: pr.title, pr: pr)
                case .changes:
                    post(title: "Changes requested · \(pr.repo)", body: pr.title, pr: pr)
                default:
                    break   // open/review transitions are too noisy
                }
            }

            // 3) CI flip.
            if oldCheckStatus != newCheckStatus {
                if pr.checkStatus == .failure {
                    post(title: "CI failing · \(pr.repo)", body: pr.title, pr: pr)
                } else if pr.checkStatus == .success, oldCheckStatus == CheckStatus.failure.rawValue
                                                      || oldCheckStatus == CheckStatus.pending.rawValue {
                    post(title: "CI green · \(pr.repo)", body: pr.title, pr: pr)
                }
            }

            // 4) Mergeable flipped to conflict — author must rebase/resolve.
            //    Only fire on entry; skip steady-state `dirty` and skip
            //    transitions involving `.unknown` (GitHub computes mergeability
            //    async; first sync after a push often returns unknown).
            let oldMergeable = old.mergeableState[pr.id]
            let newMergeable = new.mergeableState[pr.id]
            if oldMergeable != newMergeable,
               oldMergeable != nil,
               oldMergeable != MergeableState.unknown.rawValue,
               newMergeable != MergeableState.unknown.rawValue {
                if pr.mergeableState == .dirty {
                    post(title: "Conflicts · \(pr.repo)", body: pr.title, pr: pr)
                }
            }
        }
    }

    private func post(title: String, body: String, pr: PR) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        content.sound = .default
        // Stash the PR URL in userInfo so tap handler can open it.
        content.userInfo = ["url": pr.url.absoluteString]

        let request = UNNotificationRequest(
            identifier: "pr-\(pr.id)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func loadSnapshot() -> Snapshot? {
        guard let data = UserDefaults.standard.data(forKey: snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    private func saveSnapshot(_ s: Snapshot) {
        if let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: snapshotKey)
        }
    }
}

extension NotificationsManager: UNUserNotificationCenterDelegate {

    /// Show banner + sound even when Pulley is frontmost — otherwise menu-bar
    /// users would never see notifications since the app is always "active".
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Tap → open the PR in the browser.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let s = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: s) {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}
