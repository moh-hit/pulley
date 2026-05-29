import SwiftUI
import AppKit

// MARK: - Detail pane

struct PRDetailPane: View {
    let pr: PR
    /// Set true while a file diff is open so the window can hide the PR list
    /// and let the diff span the full width. Owned by `MainWindowView`.
    @Binding var fullScreenDiff: Bool
    @EnvironmentObject var store: Store

    @State private var descriptionText: String = ""
    @State private var loading = false
    @State private var loadError: String? = nil

    // Which top-level tab the pane is showing.
    @State private var tab: DetailTab = .summary

    // Changed-files state. Loaded on demand like the description. The Files tab
    // drills in: it shows a file tree, and selecting a leaf swaps to a
    // full-pane diff for that file (`selectedFilePath`). Directories are
    // expanded by default — we track the *collapsed* set so the empty default
    // means "all open".
    @State private var files: [PRFile] = []
    @State private var filesLoading = false
    @State private var filesError: String? = nil
    @State private var filesCapped = false
    @State private var selectedFilePath: String? = nil
    @State private var collapsedDirs: Set<String> = []
    @State private var draftComments: [String: ReviewDraftComment] = [:]
    @State private var commentAnchor: DiffCommentLocation? = nil
    @State private var activeDraftID: String? = nil
    /// Inline comments already posted on the PR, shown read-only under their
    /// diff line. Loaded with the files and refetched after a review submits.
    @State private var reviewComments: [PRReviewComment] = []
    /// Monotonic guard so a slow comment fetch (or post-submit reconcile) from a
    /// previous PR can't clobber the list after the user has moved on.
    @State private var commentsReloadToken = 0
    /// Current user's login, used to attribute optimistically-shown comments
    /// until the real fetch (with avatar) catches up.
    @State private var myLogin: String? = nil

    // Review composer state. The textarea is always visible (single-line
    // tall when empty, grows to a few lines as you type); the three action
    // buttons both pick the event type AND submit, so there's no "select
    // then send" two-step.
    @State private var reviewBody: String = ""
    @State private var inflightAction: InflightAction? = nil
    @State private var actionError: String? = nil
    /// Review composer is collapsed behind a CTA so the description leads.
    @State private var showReview: Bool = false

    private enum InflightAction: Equatable { case draft, review }

    enum DetailTab: Hashable { case summary, files }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Persistent header (title / repo / branch / status / actions) sits
            // above the tabs so it's always visible regardless of which tab is
            // active.
            VStack(alignment: .leading, spacing: 16) {
                header
                statusRow
                if pr.mergeableState == .dirty {
                    ConflictBanner()
                }
                actionRow
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 18)

            // Prominent underlined tab bar. Its full-width baseline is the
            // divider between the PR header above and the tabbed content below.
            tabBar

            // Tab content fills the remaining height.
            Group {
                switch tab {
                case .summary: summaryTab
                case .files:   filesTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(NSColor.textBackgroundColor))
        .onAppear {
            loadBody()
            loadFiles()
            loadReviewComments()
            if myLogin == nil { loadMyLogin() }
            syncFullScreen()
        }
        .onChange(of: pr.id) { _ in
            loadBody()
            loadFiles()
            loadReviewComments()
            // Reset per-PR transient state so the textarea / error from one
            // PR doesn't leak into the next selection.
            reviewBody = ""
            actionError = nil
            inflightAction = nil
            showReview = false
            draftComments = [:]
            commentAnchor = nil
            activeDraftID = nil
            tab = .summary
            selectedFilePath = nil
            collapsedDirs = []
            syncFullScreen()
        }
        .onChange(of: tab) { _ in syncFullScreen() }
        .onDisappear { fullScreenDiff = false }
    }

    /// The Files tab claims the full window (PR list hidden) so its tree +
    /// diff master-detail has room; Summary keeps the normal list layout.
    private func syncFullScreen() {
        fullScreenDiff = (tab == .files)
    }

    private var sortedDraftComments: [ReviewDraftComment] {
        draftComments.values.sorted { left, right in
            if left.path != right.path { return left.path < right.path }
            if left.line != right.line { return left.line < right.line }
            return left.side.rawValue < right.side.rawValue
        }
    }

    private var readyDraftComments: [ReviewDraftComment] {
        sortedDraftComments.filter {
            !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var inlineReviewComments: [ReviewInlineComment] {
        readyDraftComments.map {
            ReviewInlineComment(
                path: $0.path,
                side: $0.side,
                startLine: $0.startLine,
                startSide: $0.startSide,
                line: $0.line,
                body: $0.body.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    private var hasReadyInlineDrafts: Bool {
        !readyDraftComments.isEmpty
    }

    // MARK: Tabs

    private var tabBar: some View {
        ZStack(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.10))
                .frame(maxWidth: .infinity)
                .frame(height: 1)
            HStack(alignment: .bottom, spacing: 22) {
                tabItem(.summary, "Summary", count: nil)
                tabItem(.files, "Files", count: files.isEmpty ? nil : files.count)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
        }
    }

    @ViewBuilder
    private func tabItem(_ t: DetailTab, _ label: String, count: Int?) -> some View {
        let selected = tab == t
        Button { tab = t } label: {
            HStack(spacing: 6) {
                Text(label)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                if let count {
                    Text("\(count)\(t == .files && filesCapped ? "+" : "")")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundColor(selected ? .primary.opacity(0.85) : .secondary.opacity(0.7))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(selected ? 0.12 : 0.07)))
                }
            }
            .padding(.bottom, 9)
            // Underline matches the label width (not greedy), so tabs stay
            // compact and grouped at the left rather than stretching.
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? Color.accentColor : Color.clear)
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: selected)
    }

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                reviewBlock

                section("Description") {
                    bodySection
                }

                if !pr.checks.isEmpty {
                    divider
                    section("Checks · \(pr.checks.count)") {
                        checksSection
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Review is collapsed behind a CTA by default; expanding reveals the
    /// composer and Approve / Request changes / Comment actions.
    @ViewBuilder
    private var reviewBlock: some View {
        if showReview {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("REVIEW")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(1.4)
                        .foregroundColor(.secondary.opacity(0.75))
                    Spacer()
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) { showReview = false }
                    } label: {
                        Text("Hide")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(inflightAction != nil)
                }
                reviewSection
            }
            divider
        } else {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { showReview = true }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Add a review")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundColor(.accentColor)
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.3), lineWidth: 0.7)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            divider
        }
    }

    @ViewBuilder
    private var filesTab: some View {
        if filesLoading {
            centeredMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading files…").font(.system(size: 12)).foregroundColor(.secondary)
                }
            }
        } else if let err = filesError {
            centeredMessage {
                Text(err).foregroundColor(.red).font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
        } else if files.isEmpty {
            centeredMessage {
                Text("No file changes.").font(.system(size: 13)).foregroundColor(.secondary).italic()
            }
        } else {
            VStack(spacing: 0) {
                // Master-detail: the file tree stays on the left while the selected
                // file's diff fills the right, so the tree is always reachable.
                HSplitView {
                    fileTreeSidebar
                        .frame(minWidth: 240, idealWidth: 300, maxWidth: 380)

                    Group {
                        if let path = selectedFilePath, let file = files.first(where: { $0.id == path }) {
                            FileDiffScreen(
                                file: file,
                                comments: reviewComments.filter { $0.path == file.filename },
                                draftComments: $draftComments,
                                commentAnchor: $commentAnchor,
                                activeDraftID: $activeDraftID
                            )
                        } else {
                            centeredMessage {
                                VStack(spacing: 8) {
                                    Image(systemName: "sidebar.left")
                                        .font(.system(size: 26, weight: .light))
                                        .foregroundColor(.secondary.opacity(0.35))
                                    Text("Select a file to view its diff.")
                                        .font(.system(size: 13))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !draftComments.isEmpty {
                    inlineDraftSubmitBar
                }
            }
        }
    }

    private var fileTreeSidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                FileTree(
                    nodes: buildFileTree(files),
                    collapsedDirs: $collapsedDirs,
                    selectedPath: selectedFilePath,
                    onSelect: { selectedFilePath = $0.id }
                )
                if filesCapped {
                    Text("Showing first 100 files. Open on GitHub to see the rest.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(.top, 10)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func centeredMessage<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack {
            Spacer()
            content()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }

    @ViewBuilder
    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundColor(.secondary.opacity(0.75))
            content()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(pr.title)
                    .font(.system(size: 20, weight: .semibold))
                    .textSelection(.enabled)
                    .lineSpacing(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let nodeID = pr.nodeID {
                    draftToggle(nodeID: nodeID)
                }
            }

            HStack(spacing: 8) {
                Text("\(pr.org)/\(pr.repo)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("#\(pr.number)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.accentColor)
                    .fixedSize()
                if !pr.branch.isEmpty {
                    BranchPill(branch: pr.branch)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                StatusBadge(text: pr.status.label, color: statusColor(pr.status), filled: true)
                if pr.isDraft {
                    StatusBadge(text: "draft", color: .secondary, filled: false)
                }
                if pr.checkStatus != .none {
                    StatusBadge(
                        text: "CI · \(pr.checkStatus.label)",
                        color: checkColor(pr.checkStatus),
                        filled: false
                    )
                }
                if pr.mergeableState.isActionable {
                    StatusBadge(
                        text: pr.mergeableState.label,
                        color: mergeableColor(pr.mergeableState),
                        filled: false
                    )
                }
                Spacer(minLength: 8)
                diffStat
            }
            Text("Updated \(pr.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary.opacity(0.7))
                .lineLimit(1)
        }
    }

    private var totalAdditions: Int { files.reduce(0) { $0 + $1.additions } }
    private var totalDeletions: Int { files.reduce(0) { $0 + $1.deletions } }

    /// PR-wide line counts — the per-file +/- from the Files tab, rolled up.
    /// Shown once files have loaded.
    @ViewBuilder
    private var diffStat: some View {
        if !files.isEmpty {
            HStack(spacing: 8) {
                Text("\(files.count) file\(files.count == 1 ? "" : "s")")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary.opacity(0.8))
                if totalAdditions > 0 {
                    Text("+\(totalAdditions.formatted())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if totalDeletions > 0 {
                    Text("−\(totalDeletions.formatted())")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                }
            }
            .fixedSize()
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: "Open in \(Config.preferredIDE.displayName)",
                systemImage: Config.preferredIDE.fallbackSymbol,
                nsImage: Config.preferredIDE.icon,
                style: .primary
            ) {
                MainActor.assumeIsolated {
                    PRActions.checkoutAndOpen(pr: pr)
                }
            }
            .help("Create a worktree and open in \(Config.preferredIDE.displayName)")

            DetailActionButton(
                title: "Open on GitHub",
                systemImage: "arrow.up.right.square",
                style: .secondary
            ) {
                PRActions.openInBrowser(pr.url)
            }
            .help("Open PR in browser")

            if !pr.branch.isEmpty {
                DetailActionButton(
                    title: "Copy branch",
                    systemImage: "doc.on.doc",
                    style: .secondary
                ) {
                    PRActions.copyToPasteboard(pr.branch)
                }
                .help("Copy branch name")
            }

            Spacer()
        }
    }

    private var reviewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ReviewComposer(
                text: $reviewBody,
                disabled: inflightAction != nil
            )

            reviewActionButtons

            if let err = actionError {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var inlineDraftSubmitBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "text.bubble.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.accentColor)
                Text("\(readyDraftComments.count) inline draft\(readyDraftComments.count == 1 ? "" : "s") ready")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                let emptyCount = draftComments.count - readyDraftComments.count
                if emptyCount > 0 {
                    Text("\(emptyCount) empty")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                }
                Spacer(minLength: 8)
                Button {
                    draftComments = [:]
                    commentAnchor = nil
                    activeDraftID = nil
                } label: {
                    Text("Discard all")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .disabled(inflightAction != nil)
            }

            ReviewComposer(text: $reviewBody, disabled: inflightAction != nil)
            reviewActionButtons
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 0.5)
        }
    }

    private var reviewActionButtons: some View {
        HStack(spacing: 8) {
            DetailActionButton(
                title: "Approve",
                systemImage: "checkmark.seal.fill",
                style: .primary
            ) {
                submitReview(event: .approve, body: reviewBody)
            }
            .disabled(inflightAction != nil || !canSubmitReview(event: .approve))
            .help(hasReadyInlineDrafts
                  ? "Approve this PR and submit inline drafts"
                  : "Approve this PR (comment optional)")

            DetailActionButton(
                title: "Request changes",
                systemImage: "exclamationmark.bubble",
                style: .secondary
            ) {
                submitReview(event: .requestChanges, body: reviewBody)
            }
            .disabled(inflightAction != nil || !canSubmitReview(event: .requestChanges))
            .help(canSubmitReview(event: .requestChanges)
                  ? "Submit as Request changes"
                  : "Add a summary or inline comment to request changes")

            DetailActionButton(
                title: "Comment",
                systemImage: "text.bubble",
                style: .secondary
            ) {
                submitReview(event: .comment, body: reviewBody)
            }
            .disabled(inflightAction != nil || !canSubmitReview(event: .comment))
            .help(canSubmitReview(event: .comment)
                  ? "Submit as Comment"
                  : "Add a summary or inline comment to leave a review comment")

            if inflightAction == .review {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 2)
            }

            Spacer()
        }
    }

    private func canSubmitReview(event: ReviewEvent) -> Bool {
        switch event {
        case .approve:
            return true
        case .requestChanges, .comment:
            return !trimmedBody.isEmpty || hasReadyInlineDrafts
        }
    }

    private var trimmedBody: String {
        reviewBody.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Compact draft toggle pinned to the top-right of the header, opposite the
    /// title. Flips the PR between draft and ready-for-review.
    @ViewBuilder
    private func draftToggle(nodeID: String) -> some View {
        Button {
            toggleDraft(nodeID: nodeID)
        } label: {
            HStack(spacing: 5) {
                if inflightAction == .draft {
                    ProgressView().controlSize(.small)
                } else {
                    // checkmark = "make it ready"; pencil = "back to a draft".
                    Image(systemName: pr.isDraft ? "checkmark.circle" : "pencil.circle")
                        .font(.system(size: 11, weight: .medium))
                }
                Text(pr.isDraft ? "Mark ready" : "Convert to draft")
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.7)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(inflightAction != nil)
        .fixedSize()
        .help(pr.isDraft
              ? "Move this PR out of draft state"
              : "Convert this PR back to draft")
    }

    private func toggleDraft(nodeID: String) {
        guard let client = Config.makeClient() else {
            actionError = "Token not configured."
            return
        }
        inflightAction = .draft
        actionError = nil
        let targetDraft = !pr.isDraft
        let prID = pr.id
        Task {
            do {
                try await client.setDraft(nodeID: nodeID, draft: targetDraft)
                await MainActor.run {
                    // GraphQL confirmed the flip — patch local state so the
                    // label / badges update immediately. `/search/issues` is
                    // eventually-consistent for the draft flag, so the
                    // background sync alone leaves the UI stale for several
                    // seconds.
                    self.store.setLocalDraft(prID: prID, isDraft: targetDraft)
                    self.inflightAction = nil
                    self.store.sync()
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.inflightAction = nil
                }
            }
        }
    }

    private func submitReview(event: ReviewEvent, body: String?) {
        guard let client = Config.makeClient() else {
            actionError = "Token not configured."
            return
        }
        inflightAction = .review
        actionError = nil
        let org = pr.org, repo = pr.repo, number = pr.number
        let headSha = pr.headSha
        let comments = inlineReviewComments
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task {
            do {
                try await client.submitReview(
                    org: org, repo: repo, number: number,
                    event: event, body: trimmed,
                    commitID: headSha,
                    comments: comments
                )
                await MainActor.run {
                    self.reviewBody = ""
                    self.draftComments = [:]
                    self.commentAnchor = nil
                    self.activeDraftID = nil
                    self.inflightAction = nil
                    self.refreshAfterSubmittingComments(comments)
                    self.store.sync()
                }
            } catch {
                await MainActor.run {
                    self.actionError = error.localizedDescription
                    self.inflightAction = nil
                }
            }
        }
    }

    @ViewBuilder
    private var bodySection: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading description…")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
        } else if let err = loadError {
            Text(err).foregroundColor(.red).font(.system(size: 12))
        } else if descriptionText.isEmpty {
            Text("No description.")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .italic()
        } else {
            MarkdownView(text: descriptionText)
        }
    }

    private var checksSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(pr.checks) { c in
                HStack(spacing: 11) {
                    Image(systemName: checkGlyph(c.rolled))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(checkColor(c.rolled))
                        .frame(width: 16)
                    Text(c.name)
                        .font(.system(size: 13))
                    Spacer()
                    Text(c.conclusion ?? c.status)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    if let url = c.url {
                        Button {
                            PRActions.openInBrowser(url)
                        } label: {
                            Image(systemName: "arrow.up.right.square")
                                .foregroundColor(.secondary.opacity(0.65))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
        }
    }

    private func loadBody() {
        loading = true
        loadError = nil
        descriptionText = ""
        guard let client = Config.makeClient() else {
            loadError = "Token not configured."
            loading = false
            return
        }
        let org = pr.org, repo = pr.repo, number = pr.number
        Task {
            do {
                let b = try await client.fetchPRBody(org: org, repo: repo, number: number)
                await MainActor.run {
                    self.descriptionText = b
                    self.loading = false
                }
            } catch {
                await MainActor.run {
                    self.loadError = error.localizedDescription
                    self.loading = false
                }
            }
        }
    }

    private func loadFiles() {
        filesLoading = true
        filesError = nil
        files = []
        filesCapped = false
        selectedFilePath = nil
        collapsedDirs = []
        guard let client = Config.makeClient() else {
            filesError = "Token not configured."
            filesLoading = false
            return
        }
        let org = pr.org, repo = pr.repo, number = pr.number
        Task {
            do {
                let result = try await client.fetchPRFiles(org: org, repo: repo, number: number)
                await MainActor.run {
                    self.files = result.files
                    self.filesCapped = result.capped
                    self.filesLoading = false
                    // Pre-select the first file (tree order) so opening the
                    // Files tab lands on a diff, with the tree alongside it.
                    self.selectedFilePath = firstFileID(in: buildFileTree(result.files))
                }
            } catch {
                await MainActor.run {
                    self.filesError = error.localizedDescription
                    self.filesLoading = false
                }
            }
        }
    }

    /// Load the PR's already-posted inline comments. Best-effort: a failure
    /// (e.g. transient network) just leaves the diff showing drafts only, so we
    /// swallow the error rather than surfacing it over the files view.
    private func loadReviewComments() {
        commentsReloadToken += 1
        let token = commentsReloadToken
        reviewComments = []
        guard let client = Config.makeClient() else { return }
        let org = pr.org, repo = pr.repo, number = pr.number
        Task {
            let fetched = (try? await client.fetchPRReviewComments(org: org, repo: repo, number: number)) ?? []
            await MainActor.run {
                guard self.commentsReloadToken == token else { return }
                self.reviewComments = fetched
            }
        }
    }

    private func loadMyLogin() {
        guard let client = Config.makeClient() else { return }
        Task {
            let login = try? await client.currentUserLogin()
            await MainActor.run { if let login { self.myLogin = login } }
        }
    }

    /// After submitting a review, GitHub's `GET /pulls/{n}/comments` feed lags a
    /// beat behind the `POST`, so an immediate refetch misses the just-posted
    /// comments. We show them optimistically right away, then poll a few times
    /// with backoff and swap in the authoritative set (with avatars, real ids)
    /// once the server has caught up. The token guard drops the result if the
    /// user navigated to another PR meanwhile.
    private func refreshAfterSubmittingComments(_ submitted: [ReviewInlineComment]) {
        let optimistic = submitted.enumerated().map { idx, c in
            PRReviewComment(
                id: -(idx + 1),                       // negative ⇒ can't collide with real ids
                authorLogin: myLogin ?? "you",
                authorAvatarURL: nil,
                body: c.body,
                path: c.path,
                side: c.side,
                line: c.line,
                startLine: c.startLine,
                createdAt: Date(),
                inReplyToID: nil
            )
        }
        let target = reviewComments.count + optimistic.count
        reviewComments.append(contentsOf: optimistic)

        commentsReloadToken += 1
        let token = commentsReloadToken
        guard let client = Config.makeClient() else { return }
        let org = pr.org, repo = pr.repo, number = pr.number
        Task {
            let delays: [UInt64] = [500_000_000, 1_500_000_000, 3_000_000_000]
            for delay in delays {
                try? await Task.sleep(nanoseconds: delay)
                guard let fetched = try? await client.fetchPRReviewComments(org: org, repo: repo, number: number)
                else { continue }
                var stop = false
                await MainActor.run {
                    guard self.commentsReloadToken == token else { stop = true; return }
                    if fetched.count >= target {        // server caught up — adopt authoritative set
                        self.reviewComments = fetched
                        stop = true
                    }
                }
                if stop { break }
            }
        }
    }
}

/// Always-visible review composer. Starts compact (two lines tall when
/// empty) and grows with content up to ~7 lines before scrolling internally.
/// The placeholder is a single neutral string ("Leave a comment…") because
/// the action buttons next door supply the verb — the textarea itself doesn't
/// need to know whether you're approving or requesting changes.
private struct ReviewComposer: View {
    @Binding var text: String
    let disabled: Bool

    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            // The TextField+axis growing API needs macOS 13+; the deployment
            // target is already 13. Using TextField (not TextEditor) gives us
            // a native focus ring, real placeholder behavior, and graceful
            // single-line collapse when empty — none of which TextEditor does.
            TextField("", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(2...7)
                .padding(.horizontal, 11)
                .padding(.vertical, 9)
                .focused($focused)
                .disabled(disabled)

            if text.isEmpty {
                Text("Leave a comment…")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary.opacity(0.55))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .allowsHitTesting(false)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(focused ? 0.06 : 0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(
                    focused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.13),
                    lineWidth: focused ? 1.0 : 0.7
                )
        )
        .animation(.easeOut(duration: 0.12), value: focused)
    }
}

// MARK: - Changed-files tree

/// Per-file status → tint, shared by the badge, tree rows, and diff screen.
private func fileStatusTint(_ status: String) -> Color {
    switch status {
    case "added":   return .green
    case "removed": return .red
    case "renamed": return .blue
    case "copied":  return .teal
    default:        return .yellow      // modified / changed
    }
}

/// Single-letter status code, source-control style (A/M/D/R/C).
private func fileStatusLetter(_ status: String) -> String {
    switch status {
    case "added":   return "A"
    case "removed": return "D"
    case "renamed": return "R"
    case "copied":  return "C"
    default:        return "M"          // modified / changed
    }
}

/// Compact tinted letter badge for a file's change status — clearer and more
/// consistent than mixed SF Symbols (plus/minus/pencil).
private struct FileStatusBadge: View {
    let status: String
    var body: some View {
        Text(fileStatusLetter(status))
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundColor(fileStatusTint(status))
            .frame(width: 15, height: 15)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(fileStatusTint(status).opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(fileStatusTint(status).opacity(0.32), lineWidth: 0.5)
            )
    }
}

/// A node in the changed-files tree: either a directory (with children and
/// aggregated +/− totals) or a leaf file. Directory chains with a single child
/// directory are compressed into one row ("a/b/c"), GitHub-style.
struct FileTreeNode: Identifiable {
    let id: String          // full path (file path for leaves, dir path otherwise)
    let name: String        // display segment (possibly compressed "a/b")
    let file: PRFile?       // non-nil ⇒ leaf
    let children: [FileTreeNode]
    let additions: Int
    let deletions: Int
    var isDir: Bool { file == nil }
}

/// Build a directory tree from the flat file list. Directories are sorted
/// first, then files, both case-insensitively.
func buildFileTree(_ files: [PRFile]) -> [FileTreeNode] {
    let root = MutableTreeNode(name: "", path: "")
    for f in files {
        let parts = f.filename.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { continue }
        var node = root
        var acc = ""
        for (i, part) in parts.enumerated() {
            acc = acc.isEmpty ? part : acc + "/" + part
            if i == parts.count - 1 {
                let leaf = MutableTreeNode(name: part, path: f.filename)
                leaf.file = f
                node.children[part] = leaf
            } else if let existing = node.children[part] {
                node = existing
            } else {
                let dir = MutableTreeNode(name: part, path: acc)
                node.children[part] = dir
                node = dir
            }
        }
    }
    return sortTreeNodes(root.children.values.map(freezeTreeNode))
}

private final class MutableTreeNode {
    let name: String
    let path: String
    var file: PRFile?
    var children: [String: MutableTreeNode] = [:]
    init(name: String, path: String) { self.name = name; self.path = path }
}

private func freezeTreeNode(_ n: MutableTreeNode) -> FileTreeNode {
    if let file = n.file {
        return FileTreeNode(id: file.filename, name: n.name, file: file, children: [],
                            additions: file.additions, deletions: file.deletions)
    }
    let kids = sortTreeNodes(n.children.values.map(freezeTreeNode))
    // Collapse single-child directory chains: "Sources" → "Pulley" → … becomes
    // one "Sources/Pulley/…" row.
    if kids.count == 1, let only = kids.first, only.isDir {
        return FileTreeNode(id: only.id, name: "\(n.name)/\(only.name)", file: nil,
                            children: only.children,
                            additions: only.additions, deletions: only.deletions)
    }
    return FileTreeNode(
        id: n.path, name: n.name, file: nil, children: kids,
        additions: kids.reduce(0) { $0 + $1.additions },
        deletions: kids.reduce(0) { $0 + $1.deletions }
    )
}

private func sortTreeNodes(_ nodes: [FileTreeNode]) -> [FileTreeNode] {
    nodes.sorted { l, r in
        if l.isDir != r.isDir { return l.isDir }   // directories first
        return l.name.localizedCaseInsensitiveCompare(r.name) == .orderedAscending
    }
}

/// First file (`PRFile.id`) in depth-first tree order — the top-most file row
/// when the tree is fully expanded. Nil when there are no files.
func firstFileID(in nodes: [FileTreeNode]) -> String? {
    for node in nodes {
        if let f = node.file { return f.id }
        if let found = firstFileID(in: node.children) { return found }
    }
    return nil
}

/// Recursive file-tree view. Directories toggle expand/collapse; selecting a
/// file calls `onSelect`, and the row matching `selectedPath` is highlighted.
private struct FileTree: View {
    let nodes: [FileTreeNode]
    @Binding var collapsedDirs: Set<String>
    let selectedPath: String?
    let onSelect: (PRFile) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(nodes) { node in
                FileTreeRow(node: node, depth: 0, collapsedDirs: $collapsedDirs,
                            selectedPath: selectedPath, onSelect: onSelect)
            }
        }
    }
}

private struct FileTreeRow: View {
    let node: FileTreeNode
    let depth: Int
    @Binding var collapsedDirs: Set<String>
    let selectedPath: String?
    let onSelect: (PRFile) -> Void
    @State private var hovered = false

    private var isExpanded: Bool { !collapsedDirs.contains(node.id) }
    private var isSelected: Bool { !node.isDir && node.id == selectedPath }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                if node.isDir {
                    if isExpanded { collapsedDirs.insert(node.id) }
                    else          { collapsedDirs.remove(node.id) }
                } else if let f = node.file {
                    onSelect(f)
                }
            } label: {
                rowLabel
            }
            .buttonStyle(.plain)
            .onHover { hovered = $0 }

            if node.isDir && isExpanded {
                ForEach(node.children) { child in
                    FileTreeRow(node: child, depth: depth + 1,
                                collapsedDirs: $collapsedDirs,
                                selectedPath: selectedPath, onSelect: onSelect)
                }
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: 6) {
            Spacer().frame(width: CGFloat(depth) * 14)
            if node.isDir {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 10)
                Image(systemName: "folder.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary.opacity(0.7))
            } else {
                Spacer().frame(width: 10)
                FileStatusBadge(status: node.file?.status ?? "")
            }
            Text(node.name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .monospaced))
                .foregroundColor(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if node.additions > 0 {
                Text("+\(node.additions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.green.opacity(node.isDir ? 0.6 : 1))
            }
            if node.deletions > 0 {
                Text("−\(node.deletions)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.red.opacity(node.isDir ? 0.6 : 1))
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(rowBackground)
        )
        .contentShape(Rectangle())
    }

    private var rowBackground: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if hovered    { return Color.primary.opacity(0.06) }
        return .clear
    }
}

/// Diff for the file selected in the tree, shown in the master-detail's detail
/// pane. The patch is parsed here so the tree stays cheap.
private struct FileDiffScreen: View {
    let file: PRFile
    let comments: [PRReviewComment]
    @Binding var draftComments: [String: ReviewDraftComment]
    @Binding var commentAnchor: DiffCommentLocation?
    @Binding var activeDraftID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                FileStatusBadge(status: file.status)
                pathText
                Spacer(minLength: 8)
                if file.additions > 0 {
                    Text("+\(file.additions)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.green)
                }
                if file.deletions > 0 {
                    Text("−\(file.deletions)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(.red)
                }
                if let url = file.blobUrl {
                    Button { PRActions.openInBrowser(url) } label: {
                        Image(systemName: "arrow.up.right.square")
                            .foregroundColor(.secondary.opacity(0.65))
                    }
                    .buttonStyle(.borderless)
                    .help("Open this file on GitHub")
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)

            // GeometryReader gives the diff its available width so rows can
            // stretch to fill the pane (uniform full-width tint), and only
            // scroll horizontally when a line is wider than the pane. The diff
            // view owns both scroll axes (see DiffPatchView).
            GeometryReader { geo in
                if let patch = file.patch {
                    DiffPatchView(
                        path: file.filename,
                        hunks: parsePatch(patch),
                        availableWidth: geo.size.width,
                        comments: comments,
                        draftComments: $draftComments,
                        commentAnchor: $commentAnchor,
                        activeDraftID: $activeDraftID
                    )
                } else {
                    Text(file.status == "renamed" && file.changes == 0
                         ? "File renamed without changes."
                         : "No inline diff available (binary or too large).")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .italic()
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private var pathText: some View {
        if file.status == "renamed", let old = file.previousFilename {
            HStack(spacing: 5) {
                Text(old).foregroundColor(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Text(file.filename)
            }
            .font(.system(size: 12, design: .monospaced))
            .lineLimit(1)
            .truncationMode(.middle)
        } else {
            Text(file.filename)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Renders a file's parsed unified diff: each hunk's `@@ … @@` header followed
/// by its lines. A single two-axis `ScrollView` + `LazyVStack` keeps large
/// files smooth — only on-screen rows are realized, and there's no nested
/// vertical/horizontal scroll fighting over gestures.
private struct DiffPatchView: View {
    let path: String
    let hunks: [DiffHunk]
    /// Width of the diff pane, from the enclosing GeometryReader.
    let availableWidth: CGFloat
    /// Already-posted comments for this file, rendered read-only under their line.
    let comments: [PRReviewComment]
    @Binding var draftComments: [String: ReviewDraftComment]
    @Binding var commentAnchor: DiffCommentLocation?
    @Binding var activeDraftID: String?

    /// Coordinate space the row metrics and the gutter drag both resolve against,
    /// so a cursor y-position maps to the same line the metrics were measured in.
    static let coordSpace = "diffContent"

    /// Vertical extent of every commentable line, kept fresh from row previews so
    /// `lineAt(_:side:)` can resolve the line under the dragging cursor.
    @State private var lineMetrics: [DiffLineMetric] = []
    /// Live highlight while a gutter drag is in flight; nil when idle.
    @State private var dragSelection: DragRangeSelection? = nil

    /// Width wide enough to hold the longest line so every row's tint spans the
    /// same width (uniform background) and the horizontal scroller reveals the
    /// rest. SF Mono at 12pt advances ≈7.5pt/char; over-estimating slightly is
    /// harmless (a little trailing slack) and avoids ragged tint edges.
    private var estimatedWidth: CGFloat {
        let longestLine = hunks.flatMap { $0.lines }.map { $0.text.count + 1 }.max() ?? 0
        let longestHeader = hunks.map { $0.header.count }.max() ?? 0
        let chars = max(longestLine, longestHeader)
        return gutterColumnsWidth + 6 + CGFloat(chars) * 7.5 + 24
    }

    /// Fill the pane when the code is narrower than it; grow past it (enabling
    /// the horizontal scroll) when a line is longer.
    private var contentWidth: CGFloat { max(estimatedWidth, availableWidth) }

    var body: some View {
        // Group posted comments by endpoint once per render, not per row.
        let byEndpoint = commentsByEndpoint
        ScrollView([.vertical, .horizontal], showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(hunks) { hunk in
                    Text(hunk.header)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .frame(width: contentWidth, alignment: .leading)
                        .background(Color.accentColor.opacity(0.08))
                    ForEach(hunk.lines) { line in
                        DiffLineRow(
                            path: path,
                            line: line,
                            width: contentWidth,
                            comments: endpointKey(for: line).flatMap { byEndpoint[$0] } ?? [],
                            draftComments: $draftComments,
                            commentAnchor: $commentAnchor,
                            activeDraftID: $activeDraftID,
                            dragSelection: dragSelection,
                            lineAt: { y, side in lineAt(y, side: side) },
                            setDragSelection: { dragSelection = $0 },
                            commitRange: { p, s, lo, hi in finalizeRange(path: p, side: s, low: lo, high: hi) }
                        )
                    }
                }
            }
            .padding(.bottom, 24)
            .coordinateSpace(name: Self.coordSpace)
            .onPreferenceChange(DiffLineMetricsKey.self) { lineMetrics = $0 }
        }
    }

    /// Posted comments grouped by their anchored endpoint key ("SIDE#line"),
    /// each thread sorted oldest-first. Comments GitHub couldn't map into the
    /// current diff (nil `line`) are dropped.
    private var commentsByEndpoint: [String: [PRReviewComment]] {
        let grouped = Dictionary(grouping: comments.filter { $0.line != nil }) {
            "\($0.side.rawValue)#\($0.line!)"
        }
        return grouped.mapValues { $0.sorted { $0.createdAt < $1.createdAt } }
    }

    /// Endpoint key a row's comments live under — additions/context anchor to the
    /// RIGHT (new) line, deletions to the LEFT (old) line, matching how comments
    /// are posted. Mirrors `DiffLineRow.commentLocation`.
    private func endpointKey(for line: DiffLine) -> String? {
        switch line.kind {
        case .addition: return line.newLine.map { "RIGHT#\($0)" }
        case .deletion: return line.oldLine.map { "LEFT#\($0)" }
        case .context:  return line.newLine.map { "RIGHT#\($0)" }
        }
    }

    /// Resolve the line under cursor y-position `y`, restricted to `side` (GitHub
    /// only allows a multi-line comment to span a single side of the diff). Falls
    /// back to the nearest same-side line so dragging past the ends still clamps.
    private func lineAt(_ y: CGFloat, side: ReviewCommentSide) -> Int? {
        let sided = lineMetrics.filter { $0.side == side }
        if sided.isEmpty { return nil }
        if let hit = sided.first(where: { y >= $0.minY && y <= $0.maxY }) { return hit.line }
        return sided.min(by: { distance($0, y) < distance($1, y) })?.line
    }

    private func distance(_ m: DiffLineMetric, _ y: CGFloat) -> CGFloat {
        if y < m.minY { return m.minY - y }
        if y > m.maxY { return y - m.maxY }
        return 0
    }

    /// Commit a gutter-drag selection to a draft. A single line opens a normal
    /// single-line draft; a span produces a range draft (carrying any body from a
    /// draft that already sat on either endpoint), then opens it for editing.
    private func finalizeRange(path: String, side: ReviewCommentSide, low: Int, high: Int) {
        if low == high {
            let id = ReviewDraftComment.id(path: path, side: side, line: low)
            if draftComments[id] == nil {
                draftComments[id] = ReviewDraftComment(path: path, side: side, line: low)
            }
            commentAnchor = DiffCommentLocation(path: path, side: side, line: low)
            activeDraftID = id
            return
        }

        let lowSingleID = ReviewDraftComment.id(path: path, side: side, line: low)
        let highSingleID = ReviewDraftComment.id(path: path, side: side, line: high)
        let carriedBody = activeDraftID.flatMap { draftComments[$0]?.body }
            ?? draftComments[lowSingleID]?.body
            ?? draftComments[highSingleID]?.body
            ?? ""
        draftComments[lowSingleID] = nil
        draftComments[highSingleID] = nil

        let id = ReviewDraftComment.id(path: path, side: side, line: high, startLine: low, startSide: side)
        draftComments[id] = ReviewDraftComment(
            path: path,
            side: side,
            line: high,
            startLine: low,
            startSide: side,
            body: carriedBody
        )
        commentAnchor = DiffCommentLocation(path: path, side: side, line: high)
        activeDraftID = id
    }
}

/// Combined width of the two line-number gutters (`gutter` frame + trailing pad).
private let gutterColumnsWidth: CGFloat = (38 + 4) * 2

private struct DiffCommentLocation: Hashable {
    let path: String
    let side: ReviewCommentSide
    let line: Int
}

/// A range of lines highlighted live while the user drags across the gutter,
/// before the drag ends and a range draft is committed.
private struct DragRangeSelection: Equatable {
    let path: String
    let side: ReviewCommentSide
    let low: Int
    let high: Int
}

/// Vertical extent (in the diff content's coordinate space) of one commentable
/// line. Published by each row via a preference so the drag handler can map a
/// cursor y-position back to the line under it.
private struct DiffLineMetric: Equatable {
    let side: ReviewCommentSide
    let line: Int
    let minY: CGFloat
    let maxY: CGFloat
}

private struct DiffLineMetricsKey: PreferenceKey {
    static var defaultValue: [DiffLineMetric] = []
    static func reduce(value: inout [DiffLineMetric], nextValue: () -> [DiffLineMetric]) {
        value.append(contentsOf: nextValue())
    }
}

/// A single diff line: old/new line-number gutters, then the marker + content,
/// tinted green for additions and red for deletions.
private struct DiffLineRow: View {
    let path: String
    let line: DiffLine
    let width: CGFloat
    /// Already-posted comments anchored at this line (oldest-first), if any.
    let comments: [PRReviewComment]
    @Binding var draftComments: [String: ReviewDraftComment]
    @Binding var commentAnchor: DiffCommentLocation?
    @Binding var activeDraftID: String?
    let dragSelection: DragRangeSelection?
    /// Resolve the line under a cursor y (in the diff content space), same side.
    let lineAt: (CGFloat, ReviewCommentSide) -> Int?
    /// Update the live drag highlight (nil clears it).
    let setDragSelection: (DragRangeSelection?) -> Void
    /// Commit a multi-line range (path, side, low, high) as a draft.
    let commitRange: (String, ReviewCommentSide, Int, Int) -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    gutter(line.oldLine)
                    gutter(line.newLine)

                    Text(marker + line.text)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.primary)
                        .padding(.leading, 6)
                        .lineLimit(1)

                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
                .gesture(rangeDragGesture)
                .help(isCommentable ? "Click to comment · drag to select a range" : "")

                commentAffordance
            }
            .padding(.vertical, 1)
            .frame(width: width, alignment: .leading)
            .background(rowBackground)
            .background(metricReporter)
            .onHover { hovered = $0 }

            if !comments.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(comments) { comment in
                        PostedCommentRow(comment: comment, isReply: comment.inReplyToID != nil)
                    }
                }
                .frame(width: width, alignment: .leading)
            }

            if let id = endpointDraftID, let draft = draftComments[id] {
                InlineDraftCommentEditor(
                    text: draftBodyBinding(id: id),
                    location: draftLocationLabel(draft),
                    onDelete: {
                        draftComments[id] = nil
                        if activeDraftID == id { activeDraftID = nil }
                    }
                )
                .frame(width: width, alignment: .leading)
            }
        }
    }

    private func gutter(_ n: Int?) -> some View {
        Text(n.map(String.init) ?? "")
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary.opacity(0.6))
            .frame(width: 38, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var commentAffordance: some View {
        Button(action: handleLineTap) {
            Image(systemName: hasReadyDraft ? "text.bubble.fill" : "plus.bubble")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(hasDraft ? .accentColor : .secondary.opacity(0.75))
                .frame(width: 22, height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
        .help(hasDraft ? "Edit draft comment" : "Add draft comment")
        .opacity(isCommentable && (hovered || hasDraft) ? 1 : 0)
        .allowsHitTesting(isCommentable && (hovered || hasDraft))
        .frame(width: 28, alignment: .trailing)
        .padding(.trailing, 6)
    }

    private var marker: String {
        switch line.kind {
        case .addition: return "+"
        case .deletion: return "-"
        case .context:  return " "
        }
    }

    /// Press anywhere on the line and drag to select a range; release to commit.
    /// `minimumDistance: 0` means the gesture owns every press on the row, so it
    /// no longer races a separate tap recognizer (the old source of misfires) —
    /// release decides: same line ⇒ single-line click, different line ⇒ range.
    /// Coordinates resolve in the shared content space so `value.location.y`
    /// maps back to the line under the cursor.
    private var rangeDragGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(DiffPatchView.coordSpace))
            .onChanged { value in
                guard let anchor = commentLocation else { return }
                let current = lineAt(value.location.y, anchor.side) ?? anchor.line
                if current == anchor.line {
                    setDragSelection(nil)
                } else {
                    setDragSelection(DragRangeSelection(
                        path: anchor.path, side: anchor.side,
                        low: min(anchor.line, current), high: max(anchor.line, current)
                    ))
                }
            }
            .onEnded { value in
                guard let anchor = commentLocation else { return }
                setDragSelection(nil)
                let current = lineAt(value.location.y, anchor.side) ?? anchor.line
                if current == anchor.line {
                    handleLineTap()
                } else {
                    commitRange(anchor.path, anchor.side, min(anchor.line, current), max(anchor.line, current))
                }
            }
    }

    /// Publishes this line's vertical extent so the drag handler can map a cursor
    /// y back to a line. Only commentable lines contribute (others can't anchor a
    /// range), measured in the same coordinate space the drag reads.
    private var metricReporter: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: DiffLineMetricsKey.self,
                value: commentLocation.map {
                    let frame = geo.frame(in: .named(DiffPatchView.coordSpace))
                    return [DiffLineMetric(side: $0.side, line: $0.line, minY: frame.minY, maxY: frame.maxY)]
                } ?? []
            )
        }
    }

    private var isDragSelected: Bool {
        guard let selection = dragSelection, let location = commentLocation else { return false }
        return selection.path == location.path
            && selection.side == location.side
            && (selection.low...selection.high).contains(location.line)
    }

    private var rowBackground: Color {
        if isDragSelected { return Color.accentColor.opacity(0.22) }
        if isActiveLine { return Color.accentColor.opacity(0.18) }
        if isDraftLine { return Color.accentColor.opacity(0.10) }
        if hovered { return Color.accentColor.opacity(0.07) }
        switch line.kind {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        case .context:  return .clear
        }
    }

    private var commentLocation: DiffCommentLocation? {
        switch line.kind {
        case .addition:
            return line.newLine.map { DiffCommentLocation(path: path, side: .right, line: $0) }
        case .deletion:
            return line.oldLine.map { DiffCommentLocation(path: path, side: .left, line: $0) }
        case .context:
            return line.newLine.map { DiffCommentLocation(path: path, side: .right, line: $0) }
        }
    }

    private var isCommentable: Bool {
        commentLocation != nil
    }

    private var endpointDraftID: String? {
        guard let location = commentLocation else { return nil }
        return draftComments.values.first {
            $0.path == location.path && $0.side == location.side && $0.line == location.line
        }?.id
    }

    private var hasDraft: Bool {
        endpointDraftID.flatMap { draftComments[$0] } != nil
    }

    private var hasReadyDraft: Bool {
        guard let id = endpointDraftID, let draft = draftComments[id] else { return false }
        return !draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isDraftLine: Bool {
        guard let location = commentLocation else { return false }
        return draftComments.values.contains {
            $0.contains(path: location.path, side: location.side, line: location.line)
        }
    }

    private var isActiveLine: Bool {
        guard let location = commentLocation,
              let activeDraftID,
              let draft = draftComments[activeDraftID] else { return false }
        return draft.contains(path: location.path, side: location.side, line: location.line)
    }

    private func draftLocationLabel(_ draft: ReviewDraftComment) -> String {
        "\(draft.locationLabel) (\(draft.side.label))"
    }

    private func handleLineTap() {
        guard let location = commentLocation else { return }
        if isShiftClick, let anchor = commentAnchor,
           anchor.path == location.path, anchor.side == location.side {
            createRangeDraft(from: anchor, to: location)
        } else {
            if let existingID = endpointDraftID {
                commentAnchor = location
                activeDraftID = existingID
                return
            }
            let id = ReviewDraftComment.id(path: path, side: location.side, line: location.line)
            if draftComments[id] == nil {
                draftComments[id] = ReviewDraftComment(
                    path: path,
                    side: location.side,
                    line: location.line
                )
            }
            commentAnchor = location
            activeDraftID = id
        }
    }

    private var isShiftClick: Bool {
        NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.shift)
    }

    private func createRangeDraft(from anchor: DiffCommentLocation, to location: DiffCommentLocation) {
        let startLine = min(anchor.line, location.line)
        let endLine = max(anchor.line, location.line)
        if startLine == endLine {
            let id = ReviewDraftComment.id(path: location.path, side: location.side, line: location.line)
            if draftComments[id] == nil {
                draftComments[id] = ReviewDraftComment(
                    path: location.path,
                    side: location.side,
                    line: location.line
                )
            }
            activeDraftID = id
            return
        }

        let singleAnchorID = ReviewDraftComment.id(path: anchor.path, side: anchor.side, line: anchor.line)
        let singleTargetID = ReviewDraftComment.id(path: location.path, side: location.side, line: location.line)
        let carriedBody = activeDraftID.flatMap { draftComments[$0]?.body }
            ?? draftComments[singleAnchorID]?.body
            ?? draftComments[singleTargetID]?.body
            ?? ""

        if let activeDraftID { draftComments[activeDraftID] = nil }
        draftComments[singleAnchorID] = nil
        draftComments[singleTargetID] = nil

        let id = ReviewDraftComment.id(
            path: location.path,
            side: location.side,
            line: endLine,
            startLine: startLine,
            startSide: anchor.side
        )
        draftComments[id] = ReviewDraftComment(
            path: location.path,
            side: location.side,
            line: endLine,
            startLine: startLine,
            startSide: anchor.side,
            body: carriedBody
        )
        activeDraftID = id
    }

    private func draftBodyBinding(id: String) -> Binding<String> {
        Binding(
            get: { draftComments[id]?.body ?? "" },
            set: { newValue in
                guard var draft = draftComments[id] else { return }
                draft.body = newValue
                draftComments[id] = draft
            }
        )
    }
}

private struct InlineDraftCommentEditor: View {
    @Binding var text: String
    let location: String
    let onDelete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.bubble")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.accentColor)
                .frame(width: 18)
                .padding(.top, 10)

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text("Draft comment")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(location)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Discard draft comment")
                }

                TextField("Leave an inline comment…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(2...6)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .focused($focused)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(focused ? 0.06 : 0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(
                                focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.12),
                                lineWidth: focused ? 1.0 : 0.7
                            )
                    )
            }
        }
        .padding(.leading, gutterColumnsWidth + 10)
        .padding(.trailing, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.055))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.55))
                .frame(width: 3)
                .padding(.leading, gutterColumnsWidth + 2)
        }
        .onAppear { focused = true }
    }
}

/// One already-posted inline comment, rendered read-only beneath its diff line.
/// Aligned under the code (past the gutters) like the draft editor, but with a
/// neutral card and grey rail so it reads as existing discussion rather than an
/// editable draft. Replies indent slightly under their parent.
private struct PostedCommentRow: View {
    let comment: PRReviewComment
    let isReply: Bool

    private var indent: CGFloat { isReply ? 22 : 0 }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(comment.authorLogin)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundColor(.primary)
                    Text(relativeTime(comment.createdAt))
                        .font(.system(size: 10.5))
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                MarkdownView(text: comment.body, bodyDesign: .default, bodySize: 13)
            }
        }
        .padding(.vertical, 9)
        .padding(.leading, gutterColumnsWidth + 12 + indent)
        .padding(.trailing, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 3)
                .padding(.leading, gutterColumnsWidth + 2 + indent)
        }
    }

    private var avatar: some View {
        AsyncImage(url: comment.authorAvatarURL) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Color.secondary.opacity(0.15)
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
        .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5))
        .padding(.top, 1)
    }
}

/// Prominent red banner shown above the action row when GitHub reports the
/// PR's `mergeable_state == dirty`. The status row already carries a small
/// "conflicts" badge; this just makes the state un-missable on the surface
/// where the user is about to act on the PR.
private struct ConflictBanner: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.red)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("Merge conflicts with the base branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Rebase or merge the base branch locally before this PR can be merged.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.red.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.35), lineWidth: 0.7)
        )
    }
}

struct EmptyDetail: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(.secondary.opacity(0.35))
            Text("Select a PR")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(.secondary)
            Text("Click or use ↑ ↓ to preview.")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
