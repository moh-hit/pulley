# Changelog

All notable changes to Pulley are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the project
loosely tracks [SemVer](https://semver.org/spec/v2.0.0.html) — patches
for bugs, minor bumps for new features, major bumps for breaking changes
to settings shape or filesystem layout.

## [Unreleased]

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

[Unreleased]: https://github.com/moh-hit/pulley/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/moh-hit/pulley/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/moh-hit/pulley/compare/v1.0.1...v1.1.0
[1.0.1]: https://github.com/moh-hit/pulley/releases/tag/v1.0.1
