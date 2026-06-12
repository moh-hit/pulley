# Changelog

All notable changes to Pulley are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
loosely tracks [SemVer](https://semver.org/spec/v2.0.0.html) — patches
for bugs, minor bumps for new features, major bumps for breaking changes
to settings shape or filesystem layout.

## [Unreleased]

### Added
- **CI failure details inline.** Failed checks in the detail pane's Checks
  section now expand in place to show the check's own output — title,
  markdown summary, and per-file annotations (`path:line` + message) — so
  diagnosing a red build no longer means a trip to the browser. A
  **Re-run failed checks** button re-runs only what failed: GitHub Actions
  checks per workflow run via `rerun-failed-jobs` (same as the web UI),
  anything else via the generic check-run re-request.
- **Fine-grained token support.** The PR sync moved off the classic-only
  `/search/issues` REST endpoint to a GraphQL search, so fine-grained PATs
  now work (see README for the permissions to grant). The inbox still
  requires a classic token and is skipped gracefully without one.
- **Merge from Pulley.** The PR detail pane now shows a purple **Merge**
  button once GitHub reports the PR is cleanly mergeable (not a draft,
  `clean` mergeable state, CI not failing or pending). Clicking opens a
  confirmation offering Squash / Merge commit / Rebase — defaulting to your
  last-used method — so a merge is always one deliberate choice. The merge
  is pinned to the PR head SHA, so a push landing between sync and merge is
  rejected rather than silently merging newer code.
- **Right-click "peek" menu** on the menu-bar icon: a quick list of your
  actionable PRs (needs-attention first), each opening in the browser on
  click, plus Open Pulley / Refresh / Settings / Quit — without opening the
  full popover. Left-click still toggles the popover.

### Changed
- Each sync now costs four GraphQL searches per org instead of four REST
  searches **plus two REST calls per PR** (detail + check runs) — noticeably
  faster on busy scopes, and far gentler on the rate limit. CI status now
  also includes legacy commit statuses (e.g. external CI reporting via the
  status API), which the old check-runs-only fetch missed.
- New Pulley logomark for both the app icon and the menu-bar icon. The
  menu-bar glyph ships as a vector template so it stays crisp at any backing
  scale and tints correctly in light and dark.

## [1.6.1] - 2026-06-03

### Fixed
- Drag-and-drop install from the DMG silently bouncing back on macOS
  Tahoe. The installer image was built with `-fs HFS+`, and Finder on
  recent macOS rejects drags from an HFS+ DMG onto an APFS
  `/Applications` without surfacing an error. Switched both the
  calibration and final `hdiutil create` calls to `-fs APFS`.

## [1.6.0] - 2026-05-29

### Added
- **Inline review comment drafts** in the Files tab: click a diff line to open
  a local draft editor, edit or discard drafts inline, and submit them with the
  existing Approve / Request changes / Comment review actions. Draft comments
  attach to GitHub using the PR head SHA plus modern `line` / `side` locations.
- **Multi-line range comments**: drag across the diff to select a span of lines
  and comment on the whole range (shift-click to extend a range also works). The
  selection highlights live as you drag and commits to a single ranged draft.
- **Existing comments shown inline**: already-posted review comments are fetched
  (`GET /pulls/{n}/comments`, paginated) and rendered read-only beneath their
  diff line — author avatar, relative time, and Markdown body — so prior
  discussion sits alongside your drafts, with replies indented under their
  parent. Comments you submit appear immediately and reconcile with GitHub's
  feed a moment later, covering its brief read-after-write lag.
- Diff review interactions tint the hovered line and highlight the active draft
  line/range.

## [1.5.0] - 2026-05-29

### Added
- **Files changed tab + inline diff viewer**: the detail pane is now
  split into **Summary** and **Files** tabs (prominent underlined tab
  bar). The Files tab is a master-detail view — a collapsible file
  **tree** on the left (directories sorted first with aggregated
  +/− totals, single-child directory chains compressed, and `A`/`M`/`D`/
  `R`/`C` status badges) and the selected file's **unified diff** on the
  right. Diffs render with full-width add/remove line tinting and old/new
  line-number gutters, parsed from `GET /pulls/{n}/files` (loaded on
  demand, single page of up to 100 files). The first file opens
  automatically; the diff view claims the full window (PR list hidden)
  for room.
- **PR diffstat in the Summary**: total file count and `+additions` /
  `−deletions` for the whole PR, rolled up from the per-file counts.

### Changed
- **Detail pane redesign**: a persistent PR header (title, metadata,
  actions) sits above the tabs. The draft / ready-for-review toggle moved
  up beside the title with clearer checkmark (mark ready) / pencil
  (convert to draft) icons. The review composer is collapsed behind an
  "Add a review" CTA so the description leads.
- The main window now opens at full screen width by default.
- Source reorganized into `App` / `Models` / `Services` / `Views`
  folders (no behavior change).

### Fixed
- **Inbox mark-as-read now persists.** Read threads are tracked locally
  (keyed by their `updatedAt`) and filtered out of GitHub's cached,
  eventually-consistent `/notifications` feed, so a thread you read no
  longer reappears on the next sync — even when the `PATCH` is delayed or
  the token lacks the `notifications` scope. A thread that gets genuinely
  newer activity still resurfaces; stale read-markers are pruned after 30
  days.

## [1.4.0] - 2026-05-29

### Added
- **Inbox** view: a second top-level surface in the main window that
  shows your unread GitHub notifications. The inbox fetch runs in
  parallel with the PR fetch on every sync and is best-effort — a token
  without the `notifications` scope quietly skips the call. Rows show
  subject type, reason, and repo; click opens the thread in the browser
  and silently marks it read via `PATCH /notifications/threads/{id}`.
  Header gets a purple "Inbox" tab with an unread-count chip.
- **Worktree sweeper**: when Pulley creates a worktree via "Open in IDE"
  it now tracks the path locally. After each sync, any tracked worktree
  whose upstream PR has been merged or closed is removed via
  `git worktree remove` (no `--force`, so dirty worktrees survive and are
  reconsidered next sync). Stranded `<repo>--<slug>` siblings no longer
  accumulate.
- **Quick review actions** in the detail pane: an always-visible reply
  box plus Approve / Request changes / Comment buttons that double as
  submit. Approve fires on click (body optional); the other two stay
  disabled until you type something. After a successful submission the
  store re-syncs so the row badge picks up the new state. Errors
  (e.g. self-approval 422s) render inline.
- **Draft / ready-for-review toggle** as a quiet text link under the
  review buttons. Backed by the GraphQL `convertPullRequestToDraft` /
  `markPullRequestReadyForReview` mutations. An optimistic local
  override keeps the label flipped through the post-mutation sync so
  the eventually-consistent `/search/issues` index can't snap it back.
- **Conflict banner** in the detail pane when GitHub reports the branch
  as `dirty` (merge conflicts with base). The existing small badge
  stays; the banner makes the state un-missable on the surface where
  the user is about to act.

### Fixed
- "Toggle Sidebar" menu item now uses `#selector(NSSplitViewController.toggleSidebar(_:))` instead of a loose `Selector("toggleSidebar:")`, clearing the compiler warning that had been riding along since 1.2.0.

## [1.3.1] - 2026-05-28

### Fixed
- Build failure on the CI toolchain (Xcode 15.4 / Swift 5.10 strict
  actor isolation): the per-row "Open in IDE" action called the
  `@MainActor`-isolated `PRActions.checkoutAndOpen` from a nonisolated
  Button closure. Wrapped in `MainActor.assumeIsolated` to match the
  pattern already used by the detail pane.

## [1.3.0] - 2026-05-28

### Changed
- Main window redesigned: sidebar removed in favor of a single
  horizontal **HeaderBar** with uniform status tabs (All / Changes /
  Review / Approved / Open), an inline search field, a "synced X ago"
  readout, the PR count, and the group picker. When more than one org
  is configured, org tabs render on a second row.
- Body simplified to a two-pane `HSplitView` (list | detail) with the
  detail pane sized larger by default; list pane has a max width so
  detail dominates as the window grows.
- PR list grouping refreshed: group headers carry a status- or
  repo-colored accent dot, a tighter monospaced label, and a small
  count chip; clean breathing room between groups.

### Added
- Native `NSToolbar` carries the sync and settings affordances as
  standard bordered toolbar items. The sync icon swaps to a spinner
  glyph (and disables) while a sync is in flight; tooltip stays current
  via Combine subscriptions to `store.$syncing` / `store.$lastSync`.
- PR rows surface CI actions inline: the checks chip is now a toggle
  that expands a per-check list (name + per-check status glyph + state
  label + open-in-browser affordance) directly beneath the row.
- Full app menu bar (App, File, Edit, View, Window) installed so
  ⌘W / ⌘M / ⌘O / ⌘R / ⌘, / standard text-editing shortcuts and
  Hide / Show All / Full Screen all work while the main window is up.

### Fixed
- PR rows no longer bleed past the list pane's leading edge on narrow
  splits — title gains a flexible frame with leading priority, repo /
  branch labels truncate gracefully, and the row clips to its bounds.
  Switched `LazyVStack` to leading alignment so over-wide rows extend
  rightward (clipped) instead of being centered and bleeding both sides.

## [1.2.0] - 2026-05-22

### Added
- CI release pipeline now signs the `.app` and DMG with the project's
  Developer ID Application certificate, submits the DMG to Apple's
  notary service, and staples the ticket. Downloaded DMGs pass
  Gatekeeper on macOS Sequoia without manual `xattr` workarounds.
- `CHANGELOG.md` introduced; release workflow extracts the matching
  version section as the GitHub Release body.
- `build.sh` / `release.sh` honor `PULLEY_SIGN_IDENTITY` and
  `PULLEY_NOTARY_PROFILE` env vars; absent, they fall back to ad-hoc
  signing so contributor builds still work without a developer cert.

## [1.1.0] - 2026-05-21

### Added
- Main app window (⌘O from the popover) with a three-pane
  `NavigationSplitView`: sidebar filters, PR list, detail pane.
- Detail pane redesign: accent status stripe, larger title, branch
  pill, real IDE app icon on the primary action button, description
  and checks rendered as rounded cards.
- Markdown view: serif body font, block-level renderer for headings,
  lists, blockquotes, fenced code with language label, horizontal
  rules; GFM task lists (`- [ ]` / `- [x]`); inline code background
  highlight; accent-colored links.
- HTML preprocess for PR descriptions: strips comments; converts
  `<strong>` / `<em>` / `<code>` / `<br>` / `<a>` / `<details>` /
  `<summary>` / `<img>` to markdown; drops structural tags.
- GitHub-style emoji shortcodes (`:rocket:` → 🚀, ~150 codes).
- List pane grouping: Flat / Status / Repo / Org with dynamic icon
  and uppercase section headers with count chips.
- Sidebar footer with refresh, live "synced Nm ago" timestamp, and
  settings gear. Drops the lone toolbar refresh button.
- Settings opens as a sheet from the main window (⌘,) in addition to
  the existing popover access.
- Uninstalled IDEs are hidden from the Settings IDE picker (except
  the currently-saved selection).
- IDE-specific fallback SF Symbols when an IDE isn't installed.

### Changed
- Default workspace base directory changed from `~/code` to `./`.
- Main window default size bumped to 1600×1000 (min 1200×720).

### Fixed
- `Store.startTimer` no longer captures `weak self` across the
  `@MainActor` Task boundary — fixes a CI build failure under strict
  Swift concurrency.

## [1.0.1] - 2026-05-21

### Added
- Initial public release. Menu-bar PR tracker with live GitHub
  search, status grouping, multi-org support, and worktree-based
  IDE checkout (VS Code / Cursor / Zed).
- Tag-push release pipeline (`.github/workflows/release.yml`) that
  builds an ad-hoc-signed DMG.

[Unreleased]: https://github.com/moh-hit/pulley/compare/v1.6.0...HEAD
[1.6.0]: https://github.com/moh-hit/pulley/compare/v1.5.0...v1.6.0
[1.5.0]: https://github.com/moh-hit/pulley/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/moh-hit/pulley/compare/v1.3.1...v1.4.0
[1.3.1]: https://github.com/moh-hit/pulley/compare/v1.3.0...v1.3.1
[1.3.0]: https://github.com/moh-hit/pulley/compare/v1.2.0...v1.3.0
[1.2.0]: https://github.com/moh-hit/pulley/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/moh-hit/pulley/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/moh-hit/pulley/releases/tag/v1.0.1
