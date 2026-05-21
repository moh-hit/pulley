import AppKit
import Foundation

enum PRActions {

    static func copyToPasteboard(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    static func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Create (or refresh) a git worktree for the PR branch so the user's main
    /// checkout stays untouched, then open the worktree in the preferred IDE.
    ///
    /// Worktree layout: `<base>/<repo>--<sanitized-branch>` (sibling to main repo).
    /// If the branch is already checked out in any worktree (here or elsewhere),
    /// that existing worktree is reused — git refuses to check the same branch
    /// out twice.
    @MainActor
    static func checkoutAndOpen(pr: PR, completion: @MainActor @escaping () -> Void = {}) {
        let base = Config.expandedBaseDir
        // Try flat <base>/<repo> first; fall back to org-scoped <base>/<org>/<repo>
        // for users who organize multi-org workspaces in per-org subfolders.
        let flat   = "\(base)/\(pr.repo)"
        let nested = "\(base)/\(pr.org)/\(pr.repo)"
        let mainRepo: String
        if FileManager.default.fileExists(atPath: flat) {
            mainRepo = flat
        } else if FileManager.default.fileExists(atPath: nested) {
            mainRepo = nested
        } else {
            showAlert(
                title: "Repo not found",
                message: "Pulley couldn't find \(pr.org)/\(pr.repo) at either:\n  \(flat)\n  \(nested)\n\nUpdate the workspace base dir in Settings, or clone the repo there first."
            )
            completion()
            return
        }

        guard !pr.branch.isEmpty else {
            openInIDE(mainRepo)
            completion()
            return
        }

        let slug = sanitizeBranchSlug(pr.branch)
        // Place the worktree as a sibling of the actual main checkout — important
        // when the repo lives at <base>/<org>/<repo> rather than at <base>/<repo>.
        let parent = (mainRepo as NSString).deletingLastPathComponent
        let defaultPath = "\(parent)/\(pr.repo)--\(slug)"
        let branch = pr.branch

        Task.detached {
            // 1. Ask git where (if anywhere) this branch is already checked out.
            //    Authoritative — covers worktrees outside <base> and the main repo itself.
            let listed = runShell("cd \(shellQuote(mainRepo)) && git worktree list --porcelain")
            let existing = worktreePath(forBranch: branch, in: listed.output)

            // 2. If git points to a path that no longer exists, prune so the add can proceed.
            if let p = existing, !FileManager.default.fileExists(atPath: p) {
                _ = runShell("cd \(shellQuote(mainRepo)) && git worktree prune")
            }

            let liveExisting: String? = existing.flatMap {
                FileManager.default.fileExists(atPath: $0) ? $0 : nil
            }

            let targetPath: String
            let cmd: String
            let isExisting: Bool

            if let p = liveExisting {
                targetPath = p
                isExisting = true
                cmd = "cd \(shellQuote(p)) && git fetch origin \(shellQuote(branch))"
            } else {
                targetPath = defaultPath
                isExisting = false
                // `worktree.guessRemote=true` lets git auto-track origin/<branch>
                // when no local branch exists yet.
                cmd = "cd \(shellQuote(mainRepo)) && " +
                      "git fetch origin \(shellQuote(branch)) && " +
                      "git -c worktree.guessRemote=true worktree add \(shellQuote(defaultPath)) \(shellQuote(branch))"
            }

            let result = runShell(cmd)
            await MainActor.run {
                defer { completion() }
                if result.exitCode != 0 {
                    showAlert(
                        title: isExisting ? "Couldn't refresh worktree" : "Couldn't create worktree",
                        message: "git exited \(result.exitCode).\n\n\(result.output.prefix(800))"
                    )
                    return
                }
                openInIDE(targetPath)
            }
        }
    }

    /// Parse `git worktree list --porcelain` output and return the worktree path
    /// that has `branch` checked out, if any. Output format is repeating blocks:
    ///
    ///     worktree /abs/path
    ///     HEAD <sha>
    ///     branch refs/heads/<name>
    ///     <blank line>
    ///
    /// Detached worktrees omit the `branch` line entirely.
    private static func worktreePath(forBranch branch: String, in porcelain: String) -> String? {
        let target = "refs/heads/\(branch)"
        var currentPath: String?
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("worktree ") {
                currentPath = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch ") {
                if String(line.dropFirst("branch ".count)) == target { return currentPath }
            } else if line.isEmpty {
                currentPath = nil
            }
        }
        return nil
    }

    /// Replace characters that don't play nicely in directory names with `-`.
    private static func sanitizeBranchSlug(_ branch: String) -> String {
        let allowed: Set<Character> = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(branch.map { allowed.contains($0) ? $0 : "-" })
    }

    @MainActor
    static func openInIDE(_ path: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-a", Config.preferredIDE.appName, path]
        do {
            try task.run()
        } catch {
            showAlert(
                title: "Couldn't open \(Config.preferredIDE.displayName)",
                message: "\(error.localizedDescription)\n\nIs \(Config.preferredIDE.appName).app installed?"
            )
        }
    }

    // MARK: - Internals

    private struct ShellResult {
        let exitCode: Int32
        let output: String
    }

    /// Runs the command through a login zsh shell so the user's PATH (Homebrew git, etc.) is loaded.
    private static func runShell(_ cmd: String) -> ShellResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-l", "-c", cmd]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError  = pipe

        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return ShellResult(
                exitCode: task.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return ShellResult(exitCode: -1, output: "\(error)")
        }
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @MainActor
    private static func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
